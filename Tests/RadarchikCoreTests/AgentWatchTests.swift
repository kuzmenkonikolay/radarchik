import Foundation
import Testing
@testable import RadarchikCore

/// Слежка за SSH-ключом (SPEC §3б, 2026-10-20). Терминал ходит к ssh-agent через
/// Радарчика, и тот видит каждую просьбу «подпиши»: кто попросил и что подписать.
/// Из терминала — просто запись в журнал; скрипт, приложение или фоновый процесс —
/// тревога с красными глазами, пока не скажешь «Всегда».
@Suite("Защита: слежка за SSH-ключом")
struct AgentWatchTests {
    /// Одноразовый ключ, сделанный ради теста (`ssh-keygen -t ed25519`), и его отпечаток из `ssh-keygen -l`.
    static let keyLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG65Y58RdXjI/955WkvvF/HBgdz5uJ8OYrlHvhAmDGJ5 test@radarchik"
    static let fingerprint = "SHA256:A8/eZEn3ReJqVZVMsXDjrjur/hiF7ofGXrQ/ajc/9tQ"

    // MARK: - Протокол ssh-agent

    @Test func framing() {
        #expect(SSHAgentProtocol.bodyLength(Data([0, 0, 0, 5])) == 5)
        // Пустое сообщение и больше 256 КБ — так и сам ssh-agent не принимает.
        #expect(SSHAgentProtocol.bodyLength(Data([0, 0, 0, 0])) == nil)
        #expect(SSHAgentProtocol.bodyLength(Data([0, 0x10, 0, 1])) == nil)
        #expect(SSHAgentProtocol.bodyLength(Data([0, 0])) == nil)
        #expect(SSHAgentProtocol.frame(Data([11])) == Data([0, 0, 0, 1, 11]))
    }

    @Test func signRequestIsParsed() throws {
        let blob = try #require(SSHPublicKey.blob(fromLine: Self.keyLine))
        let payload = Data("payload".utf8)
        let body = Data([SSHAgentProtocol.Kind.signRequest]) + SSHWire.string(blob) + SSHWire.string(payload) + SSHWire.uint32(4)
        let request = try #require(SSHAgentProtocol.signRequest(body))
        #expect(request.keyBlob == blob)
        #expect(request.data == payload)
        #expect(request.flags == 4)
        // Обрезанное и чужое — nil, без падения.
        #expect(SSHAgentProtocol.signRequest(body.prefix(body.count - 3)) == nil)
        #expect(SSHAgentProtocol.signRequest(Data([SSHAgentProtocol.Kind.requestIdentities])) == nil)
        #expect(SSHAgentProtocol.signRequest(Data()) == nil)
    }

    /// OpenSSH 8.9+ перед входом говорит агенту, к какому серверу подключается.
    @Test func sessionBindNamesTheServerKey() {
        let hostKey = Data("host-key".utf8)
        let body = Data([SSHAgentProtocol.Kind.extensionRequest]) + SSHWire.string("session-bind@openssh.com") + SSHWire.string(hostKey)
            + SSHWire.string(Data(repeating: 1, count: 32)) + SSHWire.string(Data("signature".utf8)) + SSHWire.bool(false)
        #expect(SSHAgentProtocol.sessionBindHostKey(body) == hostKey)
        #expect(SSHAgentProtocol.sessionBindHostKey(Data([SSHAgentProtocol.Kind.extensionRequest]) + SSHWire.string("query")) == nil)
    }

    // MARK: - Что просят подписать

    @Test func loginSaysWhichUser() throws {
        let blob = try #require(SSHPublicKey.blob(fromLine: Self.keyLine))
        // Так выглядит то, что ssh просит подписать при входе (RFC 4252, §7).
        let login = SSHWire.string(Data(repeating: 7, count: 32)) + Data([50]) + SSHWire.string("root") + SSHWire.string("ssh-connection")
            + SSHWire.string("publickey") + SSHWire.bool(true) + SSHWire.string("ssh-ed25519") + SSHWire.string(blob)
        #expect(SSHSignPurpose(signedData: login) == .login(user: "root"))
        // OpenSSH 8.9+: вход с привязкой к серверу — тот же вход.
        let bound = SSHWire.string(Data(repeating: 7, count: 32)) + Data([50]) + SSHWire.string("git") + SSHWire.string("ssh-connection")
            + SSHWire.string("publickey-hostbound-v00@openssh.com") + SSHWire.bool(true) + SSHWire.string("ssh-ed25519") + SSHWire.string(blob)
            + SSHWire.string(Data("host-key".utf8))
        #expect(SSHSignPurpose(signedData: bound) == .login(user: "git"))
    }

    @Test func gitSignatureSaysItsNamespace() {
        // `ssh-keygen -Y sign -n git` — так git подписывает коммиты и теги.
        let commit = Data("SSHSIG".utf8) + SSHWire.string("git") + SSHWire.string("") + SSHWire.string("sha512") + SSHWire.string(Data(repeating: 9, count: 64))
        #expect(SSHSignPurpose(signedData: commit) == .signature(namespace: "git"))
        #expect(SSHSignPurpose(signedData: Data("garbage".utf8)) == .other)
        #expect(SSHSignPurpose(signedData: Data()) == .other)
    }

    // MARK: - Публичный ключ

    @Test func publicKeyBlobAndFingerprint() throws {
        let blob = try #require(SSHPublicKey.blob(fromLine: Self.keyLine))
        #expect(SSHPublicKey.fingerprint(blob) == Self.fingerprint)
        // Без комментария, с пробелами и переводом строки — тот же ключ.
        #expect(SSHPublicKey.blob(fromLine: "  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG65Y58RdXjI/955WkvvF/HBgdz5uJ8OYrlHvhAmDGJ5\n") == blob)
        // Тип в строке не совпал с типом внутри ключа — это не ключ.
        #expect(SSHPublicKey.blob(fromLine: "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIG65Y58RdXjI/955WkvvF/HBgdz5uJ8OYrlHvhAmDGJ5") == nil)
        #expect(SSHPublicKey.blob(fromLine: "не ключ") == nil)
    }

    // MARK: - Откуда пришла просьба

    private static let terminal = ProcessLink(pid: 100, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", arguments: ["Terminal"])
    private static let login = ProcessLink(pid: 101, path: "/usr/bin/login", arguments: ["login", "-pf", "me"])
    private static let zsh = ProcessLink(pid: 102, path: "/bin/zsh", arguments: ["-zsh"])
    private static let package = "/Users/me/work/app/node_modules/evil"

    private static func link(_ pid: Int32, _ path: String, _ arguments: [String] = [], cwd: String? = nil) -> ProcessLink {
        ProcessLink(pid: pid, path: path, arguments: arguments.isEmpty ? [path] : arguments, cwd: cwd)
    }

    /// npm install → postinstall пакета → git по SSH.
    private static let postinstall: [ProcessLink] = [
        link(300, "/usr/bin/ssh", ["/usr/bin/ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@github.com", "git-upload-pack", "'x/y.git'"]),
        link(301, "/usr/bin/git", ["git", "ls-remote", "git@github.com:x/y.git"]),
        link(302, "/bin/sh", ["sh", "-c", "node install.js"]),
        link(303, "/opt/homebrew/bin/node", ["node", "install.js"], cwd: package),
        link(304, "/bin/sh", ["sh", "-c", "npm install"]),
        link(305, "/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/npm", "install"], cwd: "/Users/me/work/app"),
        zsh, login, terminal,
    ]

    @Test func commandsFromTheTerminalAreOnlyLogged() {
        let ssh = [Self.link(200, "/usr/bin/ssh", ["ssh", "root@45.59.120.176"]), Self.zsh, Self.login, Self.terminal]
        let origin = AgentWatchRules.origin(ssh)
        #expect(origin.kind == .terminal)
        #expect(origin.name == "Terminal")
        #expect(!AgentWatchRules.isAlarm(origin))
        // Подпись коммита: ssh-keygen ← git ← zsh.
        let commit = [
            Self.link(201, "/usr/bin/ssh-keygen", ["ssh-keygen", "-Y", "sign", "-n", "git"]), Self.link(202, "/usr/bin/git", ["git", "commit"]),
            Self.zsh, Self.login, Self.terminal,
        ]
        #expect(AgentWatchRules.origin(commit).kind == .terminal)
        // tmux: его сервер живёт сам по себе (родитель — launchd), но внутри — твой терминал.
        let tmux = [Self.link(210, "/usr/bin/ssh"), Self.link(211, "/bin/zsh", ["-zsh"]), Self.link(212, "/opt/homebrew/bin/tmux", ["tmux"])]
        #expect(AgentWatchRules.origin(tmux).kind == .terminal)
        // Встроенный терминал VS Code.
        let vscode = [
            Self.link(220, "/usr/bin/ssh"), Self.link(221, "/bin/zsh", ["-zsh"]),
            Self.link(222, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
        ]
        #expect(AgentWatchRules.origin(vscode).kind == .terminal)
    }

    @Test func scriptUsingTheKeyIsAnAlarm() {
        let origin = AgentWatchRules.origin(Self.postinstall)
        #expect(origin.kind == .script)
        // Ближайший к ssh скрипт — тот, кто на самом деле просит ключ.
        #expect(origin.name == "node install.js")
        // «Убить» — сам скрипт, а не ssh, который уже отработал.
        #expect(origin.pid == 303)
        #expect(AgentWatchRules.isAlarm(origin))
        // Тот же скрипт — тот же ключ «Всегда»; npm сам по себе — другой:
        // разрешив git-зависимости npm, не разрешишь чужой postinstall.
        #expect(AgentWatchRules.allowKey(origin) == AgentWatchRules.allowKey(AgentWatchRules.origin(Self.postinstall)))
        let npm = [Self.link(310, "/usr/bin/ssh"), Self.link(311, "/usr/bin/git")] + Self.postinstall.suffix(4)
        let npmOrigin = AgentWatchRules.origin(npm)
        #expect(npmOrigin.name == "node npm")
        #expect(AgentWatchRules.allowKey(npmOrigin) != AgentWatchRules.allowKey(origin))
        #expect(AgentWatchRules.allowKey(origin).hasPrefix("agent|"))
        // Ruby-скрипт с net-ssh ходит в агент сам, без ssh: kamal deploy.
        let kamal = [Self.link(320, "/opt/homebrew/opt/ruby/bin/ruby", ["ruby", "/Users/me/.gem/bin/kamal", "deploy"]), Self.zsh, Self.login, Self.terminal]
        #expect(AgentWatchRules.origin(kamal).kind == .script)
        #expect(AgentWatchRules.origin(kamal).name == "ruby kamal")
    }

    @Test func appsAndBackgroundAreAlarmsToo() {
        // Git из RubyMine, без терминала.
        let ide = [Self.link(400, "/usr/bin/ssh"), Self.link(401, "/usr/bin/git"), Self.link(402, "/Applications/RubyMine.app/Contents/MacOS/rubymine")]
        #expect(AgentWatchRules.origin(ide).kind == .app)
        #expect(AgentWatchRules.origin(ide).name == "RubyMine")
        #expect(AgentWatchRules.isAlarm(AgentWatchRules.origin(ide)))
        // Расширение VS Code запустило sh → ssh: оболочка есть, но это не терминал.
        let plugin = [
            Self.link(410, "/usr/bin/ssh"), Self.link(411, "/bin/sh", ["sh", "-c", "ssh x"]),
            Self.link(412, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
        ]
        #expect(AgentWatchRules.origin(plugin).kind == .app)
        // autossh в фоне: его родитель — launchd, в цепочке его нет.
        let tunnel = [
            Self.link(500, "/usr/bin/ssh", ["/usr/bin/ssh", "-N", "-L", "8888:127.0.0.1:8888", "root@45.59.120.176"]),
            Self.link(501, "/opt/homebrew/bin/autossh", ["/opt/homebrew/bin/autossh", "-M", "0", "-N", "root@45.59.120.176"]),
        ]
        let origin = AgentWatchRules.origin(tunnel)
        #expect(origin.kind == .background)
        #expect(origin.name == "autossh")
        #expect(AgentWatchRules.isAlarm(origin))
    }

    /// git из Xcode (через `xcrun`) и другие инструменты внутри бандла — ещё не приложение:
    /// их запустила твоя оболочка. Приложение — только его главный исполняемый файл.
    @Test func toolsInsideAnAppBundleAreNotTheApp() {
        let xcodeGit = Self.link(601, "/Applications/Xcode.app/Contents/Developer/usr/bin/git", ["git", "pull"])
        let fromTerminal = [Self.link(600, "/usr/bin/ssh", ["ssh", "git@github.com"]), xcodeGit, Self.zsh, Self.login, Self.terminal]
        let origin = AgentWatchRules.origin(fromTerminal)
        #expect(origin.kind == .terminal)
        #expect(!AgentWatchRules.isAlarm(origin))
        #expect(AgentWatchRules.chainText(fromTerminal) == "ssh ← git ← zsh ← Terminal")
        // Тот же git, но запустил его сам Xcode (Source Control → Pull): приложение.
        let fromXcode = [Self.link(610, "/usr/bin/ssh"), xcodeGit, Self.link(612, "/Applications/Xcode.app/Contents/MacOS/Xcode", ["Xcode"])]
        #expect(AgentWatchRules.origin(fromXcode).kind == .app)
        #expect(AgentWatchRules.origin(fromXcode).name == "Xcode")
    }

    /// `login` под root: его родителя иногда не прочитать, и цепочка кончается на нём.
    /// Но login запускают только терминалы — значит, команда из терминала.
    @Test func chainCutAtLoginIsStillTheTerminal() {
        let cut = [Self.link(620, "/usr/bin/ssh", ["ssh", "ubuntu@10.30.4.217"]), Self.zsh, Self.login]
        #expect(AgentWatchRules.origin(cut).kind == .terminal)
        #expect(!AgentWatchRules.isAlarm(AgentWatchRules.origin(cut)))
    }

    /// Ключ открыли по Touch ID для команды из оболочки 102: её обращение — не тревога,
    /// даже если источник выглядит чужим. Скрипт — только если оболочка запустила его сама.
    @Test func commandApprovedByTouchIDIsTrusted() {
        let approved: Set<Int32> = [Self.zsh.pid]
        // Терминал RubyMine: git ← zsh ← RubyMine выглядит как приложение, но команду набрал ты.
        let ide = [Self.link(630, "/usr/bin/ssh"), Self.link(631, "/usr/bin/git"), Self.zsh, Self.link(632, "/Applications/RubyMine.app/Contents/MacOS/rubymine")]
        #expect(AgentWatchRules.isAlarm(AgentWatchRules.origin(ide)))
        #expect(AgentWatchRules.isApproved(ide, origin: AgentWatchRules.origin(ide), shells: approved))
        #expect(!AgentWatchRules.isApproved(ide, origin: AgentWatchRules.origin(ide), shells: []))
        // `kamal deploy` набран в терминале: скрипт и есть команда.
        let kamal = [Self.link(640, "/opt/homebrew/opt/ruby/bin/ruby", ["ruby", "/Users/me/.gem/bin/kamal", "deploy"]), Self.zsh, Self.login, Self.terminal]
        #expect(AgentWatchRules.isApproved(kamal, origin: AgentWatchRules.origin(kamal), shells: approved))
        // postinstall внутри `npm install`: ты набирал npm, а не install.js — тревога остаётся.
        #expect(!AgentWatchRules.isApproved(Self.postinstall, origin: AgentWatchRules.origin(Self.postinstall), shells: approved))
    }

    @Test func chainReadsFromTheClientUpToTheApp() {
        #expect(AgentWatchRules.chainText(Self.postinstall) == "ssh ← git ← sh ← node install.js ← sh ← node npm ← zsh ← Terminal")
    }

    // MARK: - ИИ-агент в терминале (2026-10-21)

    /// Нативный Claude Code: `~/.local/bin/claude` — ссылка на `…/claude/versions/2.1.306`,
    /// и в цепочке он виден под номером версии.
    private static let claude = link(700, "/Users/me/.local/share/claude/versions/2.1.306", ["claude"], cwd: "/Users/me/work/app")
    /// Bash-инструмент Claude Code: `zsh -c` под ним, выше — твоя вкладка.
    private static let claudeCommit: [ProcessLink] = [
        link(701, "/usr/bin/ssh-keygen", ["ssh-keygen", "-Y", "sign", "-n", "git"], cwd: "/Users/me/work/app"),
        link(702, "/usr/bin/git", ["git", "commit", "-m", "x"]), link(703, "/bin/zsh", ["/bin/zsh", "-c", "git commit -m x"]),
        claude, zsh, login, terminal,
    ]

    /// Claude Code сидит в терминале, но команды его — не твои: хук Touch ID он не проходит.
    /// Так пять коммитов подряд подписались без единого окна (2026-10-21).
    @Test func assistantInTheTerminalIsNotYou() {
        let origin = AgentWatchRules.origin(Self.claudeCommit)
        #expect(origin.kind == .assistant)
        #expect(origin.name == "Claude Code")
        // Один ключ на все версии: «Всегда» и срок подтверждения не сбрасываются обновлением.
        #expect(origin.identity == "claude")
        #expect(origin.pid == Self.claude.pid)
        #expect(AgentWatchRules.isAlarm(origin))
        #expect(AgentWatchRules.allowKey(origin) == "agent|assistant|claude")
        #expect(AgentWatchRules.chainText(Self.claudeCommit) == "ssh-keygen ← git ← zsh ← Claude Code ← zsh ← Terminal")
        // В окне Touch ID — от источника, а не от ssh-keygen.
        #expect(AgentWatchRules.requesterText(Self.claudeCommit, origin: origin) == "Claude Code ← zsh ← Terminal")
        // Из npm Claude Code — это node с cli.js пакета.
        let fromNpm = [
            Self.link(710, "/usr/bin/ssh", ["ssh", "git@github.com"]), Self.link(711, "/usr/bin/git", ["git", "push"]),
            Self.link(712, "/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), Self.zsh, Self.login, Self.terminal,
        ]
        #expect(AgentWatchRules.origin(fromNpm).kind == .assistant)
        #expect(AgentWatchRules.origin(fromNpm).identity == "claude")
        // Другие агенты — по имени программы.
        let codex = [Self.link(720, "/usr/bin/ssh"), Self.link(721, "/opt/homebrew/bin/codex", ["codex"]), Self.zsh, Self.login, Self.terminal]
        #expect(AgentWatchRules.origin(codex).name == "Codex")
        // Скрипт под Claude Code (postinstall из его `npm install`) — скрипт: он ближе к ключу.
        let script = Array(Self.postinstall.prefix(6)) + [Self.claude, Self.zsh, Self.login, Self.terminal]
        #expect(AgentWatchRules.origin(script).kind == .script)
        #expect(AgentWatchRules.chainText(script).hasSuffix("node npm ← Claude Code ← zsh ← Terminal"))
        // У приложения источник — сам клиент: «Просит» — вся цепочка.
        let ide = [Self.link(730, "/usr/bin/ssh"), Self.link(731, "/usr/bin/git"), Self.link(732, "/Applications/RubyMine.app/Contents/MacOS/rubymine")]
        #expect(AgentWatchRules.requesterText(ide, origin: AgentWatchRules.origin(ide)) == "ssh ← git ← RubyMine")
    }

    /// Посредник спрашивает Touch ID, когда защищённый ключ просит не твоя команда.
    @Test func gateAsksOnlyStrangers() {
        let now = Date(timeIntervalSince1970: 10_000)
        let assistant = AgentWatchRules.origin(Self.claudeCommit)
        let terminal = AgentOrigin(kind: .terminal, name: "Terminal", identity: "Terminal", pid: 1)
        func verdict(_ origin: AgentOrigin, isProtected: Bool = true, approved: Bool = false, always: Bool = false, until: Date? = nil, canAsk: Bool = true) -> AgentGate.Verdict {
            AgentGate.verdict(origin: origin, isProtected: isProtected, approved: approved, allowedAlways: always, confirmedUntil: until, now: now, canAsk: canAsk)
        }
        #expect(verdict(assistant) == .ask)
        #expect(verdict(terminal) == .pass)
        // Незащищённый ключ, команда, для которой ты открыл ключ по Touch ID, и «Всегда» — проходят.
        #expect(verdict(assistant, isProtected: false) == .pass)
        #expect(verdict(assistant, approved: true) == .pass)
        #expect(verdict(assistant, always: true) == .pass)
        // Подтверждение действует `grace`: пять коммитов подряд — одно окно.
        #expect(verdict(assistant, until: now.addingTimeInterval(AgentGate.grace)) == .pass)
        #expect(verdict(assistant, until: now) == .ask)
        // Root-части нет — как раньше: пропустить и тревога.
        #expect(verdict(assistant, canAsk: false) == .alarm)
        #expect(AgentGate.grace == 600)
    }

    // MARK: - Куда ходили

    @Test func destinationComesFromSSHArguments() {
        let tunnel = ["/usr/bin/ssh", "-N", "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes", "-L", "8888:127.0.0.1:8888", "root@45.59.120.176"]
        #expect(AgentWatchRules.sshDestination(tunnel) == "root@45.59.120.176")
        #expect(AgentWatchRules.sshDestination(["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@github.com", "git-upload-pack", "'me/x.git'"]) == "git@github.com")
        // scp зовёт ssh так: пользователь отдельно, адрес после «--».
        #expect(AgentWatchRules.sshDestination(["ssh", "-x", "-oPermitLocalCommand=no", "-oForwardAgent=no", "-l", "root", "--", "1.2.3.4", "scp -f ~/x"]) == "root@1.2.3.4")
        #expect(AgentWatchRules.sshDestination(["ssh", "-p2222", "-NT", "-i", "~/.ssh/key", "deploy@app.example.com"]) == "deploy@app.example.com")
        #expect(AgentWatchRules.sshDestination(["ssh", "ssh://git@host.example:2222/repo"]) == "git@host.example")
        #expect(AgentWatchRules.sshDestination(["ssh", "-V"]) == nil)
        // В цепочке адрес берём у ssh, а не у git над ним.
        let push = [Self.link(1, "/usr/bin/ssh", ["ssh", "git@github.com", "git-receive-pack", "'me/x.git'"]), Self.link(2, "/usr/bin/git", ["git", "push"])]
        #expect(AgentWatchRules.destination(push) == "git@github.com")
        #expect(AgentWatchRules.destination([Self.link(3, "/usr/bin/ssh-keygen", ["ssh-keygen", "-Y", "sign"])]) == nil)
    }

    // MARK: - Фразы

    @Test func phrases() {
        let terminal = AgentOrigin(kind: .terminal, name: "Terminal", identity: "Terminal", pid: 1)
        let script = AgentOrigin(kind: .script, name: "node install.js", identity: "x", pid: 2)
        let tunnel = AgentOrigin(kind: .background, name: "autossh", identity: "/opt/homebrew/bin/autossh", pid: 3)
        let ide = AgentOrigin(kind: .app, name: "RubyMine", identity: "/Applications/RubyMine.app", pid: 4)
        #expect(GuardPhrase.agentAction(.login(user: "root"), destination: "root@45.59.120.176", place: nil) == "Вход на root@45.59.120.176")
        #expect(GuardPhrase.agentAction(.login(user: "deploy"), destination: nil, place: nil) == "Вход как deploy")
        #expect(GuardPhrase.agentAction(.signature(namespace: "git"), destination: nil, place: "storefront") == "Подпись коммита в storefront")
        #expect(GuardPhrase.agentAction(.signature(namespace: "git"), destination: nil, place: nil) == "Подпись коммита")
        #expect(GuardPhrase.agentAction(.signature(namespace: "file"), destination: nil, place: nil) == "Подпись файла")
        #expect(GuardPhrase.agentAction(.other, destination: nil, place: nil) == "Подпись")
        #expect(GuardPhrase.agentUse("Вход на root@45.59.120.176", origin: terminal) == "Вход на root@45.59.120.176 — из терминала")
        #expect(GuardPhrase.agentUse("Вход на root@45.59.120.176", origin: tunnel) == "Вход на root@45.59.120.176 — autossh в фоне")
        #expect(GuardPhrase.agentUse("Подпись коммита", origin: ide) == "Подпись коммита — из RubyMine")
        let assistant = AgentOrigin(kind: .assistant, name: "Claude Code", identity: "claude", pid: 5)
        #expect(GuardPhrase.agentUse("Подпись коммита в app", origin: assistant) == "Подпись коммита в app — через Claude Code")
        #expect(GuardPhrase.agentAlarm("Подпись коммита в app", origin: assistant) == "SSH-ключом пользуется Claude Code: подпись коммита в app")
        #expect(GuardPhrase.agentRefused("Вход на git@github.com", origin: assistant) == "Не дал SSH-ключ Claude Code: вход на git@github.com")
        #expect(GuardPhrase.agentAlarm("Вход на git@github.com", origin: script) == "SSH-ключом пользуется node install.js: вход на git@github.com")
        english {
            #expect(GuardPhrase.agentAction(.login(user: "root"), destination: "root@1.2.3.4", place: nil) == "Login to root@1.2.3.4")
            #expect(GuardPhrase.agentAlarm("Login to git@github.com", origin: script) == "node install.js is using your SSH key: login to git@github.com")
            #expect(GuardPhrase.agentUse("Commit signature", origin: terminal) == "Commit signature — from the terminal")
            let assistant = AgentOrigin(kind: .assistant, name: "Claude Code", identity: "claude", pid: 5)
            #expect(GuardPhrase.agentUse("Commit signature in app", origin: assistant) == "Commit signature in app — via Claude Code")
            #expect(GuardPhrase.agentRefused("Login to git@github.com", origin: assistant) == "Refused the SSH key to Claude Code: login to git@github.com")
        }
    }

    /// Запись о ключе живёт в том же журнале «Защиты».
    @Test func agentEventsAreStored() throws {
        let repository = try GuardRepository(database: Database(path: ":memory:"))
        let event = try repository.add(kind: .agent, level: .critical, at: Date(timeIntervalSince1970: 1_000), title: "t", detail: "ssh ← zsh", allowKey: "agent|x")
        #expect(try repository.event(event.id)?.kind == .agent)
    }
}

/// Посредник целиком: настоящий `ssh-agent` с одноразовым ключом во временной папке
/// (твой агент и твои ключи не трогаются), а через посредника — `ssh-add` и подпись,
/// как у `git commit`.
@Suite("Защита: посредник перед ssh-agent")
struct SSHAgentRelayTests {
    @Test func passesEverythingThroughAndSeesWhoSigns() throws {
        let agent = try TemporaryAgent()
        defer { agent.stop() }
        let seen = Collected()
        let relay = SSHAgentRelay(path: agent.relayPath, upstream: agent.agentPath) { seen.append($0) }
        try relay.start()
        defer { relay.stop() }

        // Список ключей проходит как есть.
        let list = try run("/usr/bin/ssh-add", ["-l"], socket: agent.relayPath)
        #expect(list.status == 0)
        #expect(list.output.contains(agent.fingerprint))
        #expect(seen.values.isEmpty)

        // Подпись как у git commit: приватного файла уже нет, подписывает только агент.
        let sign = try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "git", "-f", agent.publicKeyPath, agent.messagePath], socket: agent.relayPath)
        #expect(sign.status == 0)
        let signing = try #require(seen.values.first)
        #expect(seen.values.count == 1)
        #expect(signing.signed)
        #expect(SSHSignPurpose(signedData: signing.request.data) == .signature(namespace: "git"))
        #expect(signing.request.keyBlob == SSHPublicKey.blob(fromLine: agent.publicKeyLine))
        // Кто просил — сам ssh-keygen, со своей цепочкой родителей.
        #expect(signing.chain.first?.pid == sign.pid)
        #expect(signing.chain.first?.name == "ssh-keygen")
        #expect(signing.chain.count > 1)
    }

    /// Посредник сказал «нет» (ты отменил окно Touch ID): агент просьбу не видел,
    /// клиент получил отказ, как от агента без такого ключа. Список ключей не трогаем.
    @Test func refusedRequestNeverReachesTheAgent() throws {
        let agent = try TemporaryAgent()
        defer { agent.stop() }
        let seen = Collected()
        let asked = Collected()
        let relay = SSHAgentRelay(path: agent.relayPath, upstream: agent.agentPath) { request in
            asked.append(SSHAgentRelay.Signing(pid: request.pid, chain: request.chain, request: request.request, signed: false, hostKey: request.hostKey))
            return .refuse
        } onSign: { seen.append($0) }
        try relay.start()
        defer { relay.stop() }

        #expect(try run("/usr/bin/ssh-add", ["-l"], socket: agent.relayPath).status == 0)
        #expect(asked.values.isEmpty)
        let sign = try run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "git", "-f", agent.publicKeyPath, agent.messagePath], socket: agent.relayPath)
        #expect(sign.status != 0)
        #expect(seen.values.isEmpty)
        let request = try #require(asked.values.first)
        // Решали, зная, кто просит и что подписывают.
        #expect(request.chain.first?.name == "ssh-keygen")
        #expect(SSHSignPurpose(signedData: request.request.data) == .signature(namespace: "git"))
        // Соединение живо: следующее сообщение того же клиента идёт как обычно.
        #expect(try run("/usr/bin/ssh-add", ["-l"], socket: agent.relayPath).output.contains(agent.fingerprint))
    }

    @Test func missingAgentClosesQuietly() throws {
        let agent = try TemporaryAgent()
        defer { agent.stop() }
        let relay = SSHAgentRelay(path: agent.relayPath, upstream: agent.folder + "/nobody.sock") { _ in }
        try relay.start()
        defer { relay.stop() }
        // Агента нет — клиент видит закрытое соединение, а посредник жив и принимает дальше.
        #expect(try run("/usr/bin/ssh-add", ["-l"], socket: agent.relayPath).status != 0)
        #expect(try run("/usr/bin/ssh-add", ["-l"], socket: agent.relayPath).status != 0)
    }
}

/// Свой ssh-agent во временной папке с одним одноразовым ключом.
private struct TemporaryAgent {
    let folder: String
    let process: Process
    let publicKeyLine: String
    let fingerprint: String

    var agentPath: String { folder + "/a.sock" }
    var relayPath: String { folder + "/r.sock" }
    var keyPath: String { folder + "/k" }
    var publicKeyPath: String { keyPath + ".pub" }
    var messagePath: String { folder + "/msg" }

    init() throws {
        // Путь к сокету — не длиннее 104 байт: временная папка пользователя короткая.
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rdr-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let keyPath = folder + "/k"
        _ = try run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "relay-test", "-f", keyPath, "-q"])
        try Data("commit".utf8).write(to: URL(fileURLWithPath: folder + "/msg"))
        publicKeyLine = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
        let blob = try #require(SSHPublicKey.blob(fromLine: publicKeyLine))
        fingerprint = SSHPublicKey.fingerprint(blob)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", folder + "/a.sock"]
        process.environment = [:]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: folder + "/a.sock") { usleep(10_000) }
        #expect(try run("/usr/bin/ssh-add", ["-q", keyPath], socket: folder + "/a.sock").status == 0)
        // Приватный файл больше не нужен: подписать сможет только агент.
        try FileManager.default.removeItem(atPath: keyPath)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: folder)
    }
}

/// Что увидел посредник — из его потоков.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SSHAgentRelay.Signing] = []

    func append(_ item: SSHAgentRelay.Signing) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var values: [SSHAgentRelay.Signing] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Запустить программу с одним `SSH_AUTH_SOCK` в окружении — без твоего агента.
private func run(_ executable: String, _ arguments: [String], socket: String? = nil) throws -> (status: Int32, output: String, pid: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = socket.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let pid = process.processIdentifier
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self), pid)
}
