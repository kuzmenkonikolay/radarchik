import Dispatch
import Foundation
import RadarchikCore

/// `Radarchik --guard-status` — «Защита» одним взглядом в терминале, как
/// `guard status` у старого guard (SPEC §3б): ключи, процессы, настройки
/// Claude Code и хуки. Журнал — в памяти: ничего не пишет и в чёлку не говорит.
/// Командных строк и содержимого настроек не печатает — только что и сколько.
enum GuardStatusCommand {
    static func run() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await report()
            done.signal()
        }
        done.wait()
        return 0
    }

    private static func report() async {
        guard let worker = try? GuardWorker(databasePath: ":memory:") else {
            print(L("Не вышло открыть журнал в памяти", "Couldn’t open an in-memory journal"))
            return
        }
        let now = Date()
        let (keys, _) = await worker.keys(now: now)
        print(L("Радарчик — защита", "Radarchik — guard"))
        print("  " + GuardPhrase.keys(keys.categories, now: now, unlocksToday: keys.unlocksToday))
        switch keys.source {
        case .helper:
            let version = await GuardHelperClient.version()
            print(version.map { L("  Ключи держит root-часть Радарчика (версия \($0))", "  Keys are held by Radarchik’s root part (version \($0))") }
                ?? L("  Root-часть стоит, но не отвечает", "  The root part is installed but not responding"))
        case .legacyGuard:
            print(L("  Ключи держит старый guard (~/work/guard)", "  Keys are held by the old guard (~/work/guard)"))
        case .builtIn:
            print(L("  Список встроенный: нет ни root-части, ни старого guard", "  Built-in list: no root part and no old guard"))
        }
        for status in keys.categories {
            let inGit = status.files.count - status.guarded.count
            var line = "  " + status.category.title.padding(toLength: 18, withPad: " ", startingAt: 0)
            line += status.isOpen
                ? L("открыто \(status.openFiles.count) из \(status.guarded.count)", "\(status.openFiles.count) of \(status.guarded.count) open")
                : L("закрыто: \(status.guarded.count)", "locked: \(status.guarded.count)")
            if inGit > 0 { line += L(", в git: \(inGit)", ", in git: \(inGit)") }
            print(line)
            // Что открыто — путями: это и есть то, что надо закрыть.
            for file in status.openFiles {
                print("      " + ShellRedactor.shortenHome(file.path, home: NSHomeDirectory()))
            }
        }

        // Процессы: первый проход видит всех, кто работает сейчас.
        _ = await worker.watchProcesses(now: now)
        let processes = await worker.recent(now: now).filter { $0.kind == .process }
        let critical = processes.filter { $0.level == .critical }.count
        print(processes.isEmpty
            ? L("  Процессы: ничего подозрительного", "  Processes: nothing suspicious")
            : L("  Процессы: опасных \(critical), стоит глянуть \(processes.count - critical)",
                "  Processes: \(critical) dangerous, \(processes.count - critical) worth a look"))

        let (findings, _) = await worker.audit(now: now)
        if findings.isEmpty {
            print(L("  Claude Code: в настройках ничего опасного", "  Claude Code: nothing dangerous in the settings"))
        } else {
            print(L("  Claude Code:", "  Claude Code:"))
            for finding in findings.sorted(by: { $0.level > $1.level }) {
                print("    \(finding.level == .critical ? "✗" : "!") " + GuardPhrase.audit(finding, home: NSHomeDirectory()))
            }
        }

        print(await worker.hooksConnected()
            ? L("  Git-хуки: подключены", "  Git hooks: on")
            : L("  Git-хуки: не подключены — ", "  Git hooks: off — ") + GitHooks.connectCommand)
    }
}
