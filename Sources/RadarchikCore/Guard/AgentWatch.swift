import Darwin
import Foundation

// Слежка за SSH-ключом (SPEC §3б, 2026-10-20). Закрытый файл ключа не мешает
// ssh-agent: если ключ попал в агента, им может пользоваться любая программа
// под тобой. Поэтому терминал ходит к агенту через посредника (`SSHAgentRelay`),
// а тот записывает, кто попросил подписать и что.
//
// - Команда, набранная в терминале, — просто запись в журнал.
// - Скрипт, приложение или фоновый процесс — тревога (глаза красные), пока не
//   скажешь «Всегда».

/// Программа в цепочке запуска: от клиента ssh-agent вверх, к приложению.
public struct ProcessLink: Sendable, Equatable, Codable {
    public let pid: Int32
    public let path: String
    /// argv целиком, argv[0] первым.
    public let arguments: [String]
    /// Рабочая папка: по ней install.js одного пакета не спутать с install.js другого.
    public let cwd: String?

    public init(pid: Int32, path: String, arguments: [String], cwd: String? = nil) {
        self.pid = pid
        self.path = path
        self.arguments = arguments
        self.cwd = cwd
    }

    /// Имя программы маленькими буквами — для правил: «ssh», «node», «zsh».
    public var name: String { (path as NSString).lastPathComponent.lowercased() }

    /// Приложение, внутри которого программа: «Terminal», «RubyMine»; nil — не из `.app`.
    public var appName: String? {
        AppIdentityResolver.outermostAppBundle(inExecutablePath: path).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }
}

/// Цепочка родителей процесса: кто попросил агента подписать и кто его запустил.
public enum ProcessChain {
    /// Процесс и его родители до launchd (его самого не берём), не больше `limit`.
    /// У чужого процесса (`login` под root) аргументы не прочитать, но родитель
    /// известен через sysctl — цепочка идёт дальше, до терминала.
    public static func read(pid: Int32, limit: Int = 16) -> [ProcessLink] {
        var chain: [ProcessLink] = []
        // Один буфер на всю цепочку: аргументы читаются в него по очереди.
        var buffer: [UInt8] = []
        var current = pid
        while current > 1, chain.count < limit, let path = ProcessArguments.path(of: current) {
            let arguments = ProcessArguments.read(pid: current, buffer: &buffer)?.arguments ?? []
            chain.append(ProcessLink(pid: current, path: path, arguments: arguments, cwd: cwd(of: current)))
            guard let ppid = ProcessArguments.info(pid: current)?.ppid ?? ProcessArguments.parentPid(of: current), ppid != current else { break }
            current = ppid
        }
        return chain
    }

    /// Рабочая папка процесса (`PROC_PIDVNODEPATHINFO`); nil — чужой или завершился.
    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

/// Откуда пришла просьба подписать.
public struct AgentOrigin: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Команда, набранная в терминале: Terminal, iTerm, Ghostty, терминал VS Code, tmux.
        case terminal
        /// Скрипт: node, python, ruby — npm, postinstall пакета, kamal.
        case script
        /// Приложение без терминала: git из RubyMine, расширение редактора.
        case app
        /// ИИ-агент в терминале: Claude Code, Codex. Команды его, а не твои —
        /// хук Touch ID он не проходит, цепочка упирается в терминал.
        case assistant
        /// Фоновый процесс без приложения и терминала: autossh, агент launchd.
        case background
    }

    public let kind: Kind
    /// Для фраз: «Terminal», «node install.js», «RubyMine», «autossh».
    public let name: String
    /// Для «Разрешать всегда» — точнее имени: путь программы и скрипта.
    public let identity: String
    /// Кого убивать по кнопке: скрипт, а если его нет — сам клиент агента.
    public let pid: Int32

    public init(kind: Kind, name: String, identity: String, pid: Int32) {
        self.kind = kind
        self.name = name
        self.identity = identity
        self.pid = pid
    }
}

public enum AgentWatchRules {
    /// Откуда просьба: идём от клиента вверх по цепочке.
    /// - Первый же интерпретатор (node, python, ruby) — скрипт. Ближайший к клиенту:
    ///   он и просит ключ, а npm выше — только тот, кто его запустил.
    /// - ИИ-агент (Claude Code, Codex) — отдельный источник: его команды набрал не ты.
    ///   Скрипт под ним (postinstall) всё равно скрипт — он ближе к клиенту.
    /// - Дошли до приложения: терминал, если по дороге была оболочка и приложение —
    ///   терминал; иначе — приложение.
    /// - tmux и screen живут сами по себе, но с оболочкой внутри — это терминал.
    /// - Ни приложения, ни терминала — фоновый процесс.
    public static func origin(_ chain: [ProcessLink]) -> AgentOrigin {
        let client = chain.first?.pid ?? 0
        var script: ProcessLink?
        var sawShell = false
        var sawLogin = false
        for link in chain {
            if let app = appOf(link) {
                if let script { return scriptOrigin(script) }
                if sawShell && isTerminal(app: app, process: link.name) {
                    return AgentOrigin(kind: .terminal, name: app, identity: app, pid: client)
                }
                let bundle = AppIdentityResolver.outermostAppBundle(inExecutablePath: link.path) ?? link.path
                return AgentOrigin(kind: .app, name: app, identity: bundle, pid: client)
            }
            if let assistant = assistant(link) {
                if let script { return scriptOrigin(script) }
                return AgentOrigin(kind: .assistant, name: assistant.name, identity: assistant.identity, pid: link.pid)
            }
            if script == nil && isInterpreter(link.name) { script = link }
            if shells.contains(link.name) { sawShell = true }
            if link.name == "login" { sawLogin = true }
            if multiplexers.contains(link.name) && sawShell && script == nil {
                return AgentOrigin(kind: .terminal, name: (link.path as NSString).lastPathComponent, identity: link.path, pid: client)
            }
        }
        if let script { return scriptOrigin(script) }
        // `login` запускают только терминалы. Цепочка оборвалась на нём (он под root,
        // родителя не прочитать) — это всё равно команда из терминала.
        if sawLogin && sawShell {
            return AgentOrigin(kind: .terminal, name: "login", identity: "/usr/bin/login", pid: client)
        }
        guard let top = chain.last(where: { !shells.contains($0.name) }) ?? chain.last else {
            return AgentOrigin(kind: .background, name: "?", identity: "?", pid: client)
        }
        return AgentOrigin(kind: .background, name: (top.path as NSString).lastPathComponent, identity: top.path, pid: client)
    }

    /// Тревога — всё, что не набрано в терминале.
    public static func isAlarm(_ origin: AgentOrigin) -> Bool {
        origin.kind != .terminal
    }

    /// Ключ «Разрешать всегда»: что за источник и его путь.
    public static func allowKey(_ origin: AgentOrigin) -> String {
        "agent|\(origin.kind.rawValue)|\(origin.identity)"
    }

    /// Команду набрал ты и открыл для неё ключ по Touch ID (`shells` — pid оболочек,
    /// у которых такая команда ещё идёт): её собственное обращение к ключу — не тревога,
    /// даже если источник выглядит чужим (git из RubyMine с его терминала). Скрипт
    /// считается самой командой, только если оболочка запустила его напрямую
    /// (`kamal deploy`); postinstall внутри `npm install` ты не набирал — тревога остаётся.
    public static func isApproved(_ chain: [ProcessLink], origin: AgentOrigin, shells approved: Set<Int32>) -> Bool {
        guard !approved.isEmpty, let index = chain.firstIndex(where: { approved.contains($0.pid) }), index > 0 else { return false }
        return origin.kind != .script || origin.pid == chain[index - 1].pid
    }

    /// Скрипт набрал ты сам: его родитель — интерактивная оболочка (`-zsh`, без `-c`),
    /// как у `npm install` или `kamal deploy` в терминале. Под `zsh -c` от Claude Code
    /// или под другим скриптом — нет.
    public static func isTypedScript(_ chain: [ProcessLink], origin: AgentOrigin) -> Bool {
        guard origin.kind == .script, let index = chain.firstIndex(where: { $0.pid == origin.pid }), index + 1 < chain.count else { return false }
        return isInteractiveShell(chain[index + 1])
    }

    static func isInteractiveShell(_ link: ProcessLink) -> Bool {
        guard shells.contains(link.name) else { return false }
        return !link.arguments.dropFirst().contains { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("c")) }
    }

    /// Цепочка словами, от клиента к приложению: «ssh ← git ← node npm ← zsh ← Terminal».
    /// Только имена программ — аргументов с возможными секретами здесь нет.
    public static func chainText(_ chain: [ProcessLink]) -> String {
        var names: [String] = []
        for link in chain {
            if let app = appOf(link) {
                names.append(app)
                break
            }
            // login между Terminal и оболочкой ничего не говорит.
            if link.name == "login" { continue }
            if let assistant = assistant(link) {
                names.append(assistant.name)
                continue
            }
            names.append(isInterpreter(link.name) ? scriptOrigin(link).name : (link.path as NSString).lastPathComponent)
        }
        return names.joined(separator: " ← ")
    }

    /// Кто просит — для окна Touch ID: цепочка от источника, а не от клиента.
    /// «Claude Code ← zsh ← Terminal», «node install.js ← sh ← node npm ← zsh ← Terminal»;
    /// у приложения и терминала источник — сам клиент, цепочка целиком.
    public static func requesterText(_ chain: [ProcessLink], origin: AgentOrigin) -> String {
        guard let index = chain.firstIndex(where: { $0.pid == origin.pid }) else { return chainText(chain) }
        return chainText(Array(chain[index...]))
    }

    /// Куда ходили: адрес из аргументов ssh в цепочке; nil — ssh в ней нет (подпись коммита, net-ssh).
    public static func destination(_ chain: [ProcessLink]) -> String? {
        chain.first { $0.name == "ssh" }.flatMap { sshDestination($0.arguments) }
    }

    /// Адрес из argv ssh: «root@45.59.120.176», «git@github.com». Флаги можно склеивать
    /// (`-NT`, `-p2222`, `-oX=y`), у части из них значение — следующим словом.
    static func sshDestination(_ arguments: [String]) -> String? {
        var login: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { break }
            let flags = Array(argument.dropFirst())
            for (position, flag) in flags.enumerated() where sshValueFlags.contains(flag) {
                let attached = String(flags[(position + 1)...])
                if attached.isEmpty { index += 1 }
                if flag == "l" { login = attached.isEmpty ? (index < arguments.count ? arguments[index] : nil) : attached }
                break
            }
            index += 1
        }
        guard index < arguments.count else { return nil }
        var destination = arguments[index]
        if destination.hasPrefix("ssh://") {
            destination = String(destination.dropFirst("ssh://".count))
            if let slash = destination.firstIndex(of: "/") { destination = String(destination[..<slash]) }
            if let colon = destination.lastIndex(of: ":"), !destination[colon...].contains("]") { destination = String(destination[..<colon]) }
        }
        guard !destination.isEmpty else { return nil }
        if !destination.contains("@"), let login { return login + "@" + destination }
        return destination
    }

    // MARK: - Внутреннее

    /// Флаги ssh, у которых есть значение (man ssh).
    private static let sshValueFlags = Set("BbcDEeFIiJLlmOoPpQRSWw")
    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"]
    private static let multiplexers: Set<String> = ["tmux", "screen", "zellij"]
    private static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "ruby", "perl", "php", "osascript", "java", "lua", "tclsh", "rscript"]
    /// Терминалы и редакторы со встроенным терминалом.
    private static let terminalApps: Set<String> = [
        "terminal", "iterm", "iterm2", "ghostty", "wezterm", "alacritty", "kitty", "warp", "hyper", "tabby", "rio",
        "visual studio code", "cursor", "windsurf", "zed",
    ]

    /// ИИ-агенты в терминале. Нативный Claude Code лежит в `~/.local/share/claude/versions/2.1.306`
    /// (имя файла — номер версии, `~/.local/bin/claude` — ссылка на него), из npm — `node …/claude-code/cli.js`.
    /// `identity` — ключ «Всегда» и срока подтверждения: один на все версии.
    private static let assistants: [String: String] = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider", "cursor-agent": "Cursor Agent", "copilot": "Copilot CLI",
    ]

    static func assistant(_ link: ProcessLink) -> (name: String, identity: String)? {
        if link.path.contains("/claude/versions/") { return ("Claude Code", "claude") }
        if let name = assistants[link.name] { return (name, link.name) }
        if isInterpreter(link.name), let script = scriptArgument(link.arguments), script.contains("/claude-code/") { return ("Claude Code", "claude") }
        return nil
    }

    /// Приложение — только если программа его главный исполняемый файл (`Contents/MacOS/`).
    /// Инструмент внутри бандла (git из Xcode через `xcrun`, node из редактора) — ещё не
    /// приложение: кто его запустил, видно выше по цепочке.
    private static func appOf(_ link: ProcessLink) -> String? {
        guard link.path.contains("/Contents/MacOS/") else { return nil }
        return link.appName
    }

    /// Расширения редакторов на Electron работают в «… Helper (Plugin)»: их оболочка — не твой терминал.
    private static func isTerminal(app: String, process: String) -> Bool {
        terminalApps.contains(app.lowercased()) && !process.contains("(plugin)")
    }

    /// python, python3, python3.12 — тоже интерпретаторы.
    private static func isInterpreter(_ name: String) -> Bool {
        if interpreters.contains(name) { return true }
        guard name.hasPrefix("python") else { return false }
        return name.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Скрипт: «node install.js» и путь к нему. Встроенный код (`node -e`) — без скрипта.
    private static func scriptOrigin(_ link: ProcessLink) -> AgentOrigin {
        let interpreter = (link.path as NSString).lastPathComponent
        let script = scriptArgument(link.arguments)
        let name = script.map { interpreter + " " + ($0 as NSString).lastPathComponent } ?? interpreter
        let scriptPath = script.map { absolute($0, cwd: link.cwd) } ?? ""
        return AgentOrigin(kind: .script, name: name, identity: link.path + " " + scriptPath, pid: link.pid)
    }

    /// Первый аргумент-скрипт после флагов интерпретатора; у `python -m pip` — модуль.
    private static func scriptArgument(_ arguments: [String]) -> String? {
        let valueFlags: Set<String> = ["-r", "--require", "--import", "--loader", "-I", "-W", "-X", "-C", "--conditions", "--title", "--input-type"]
        let inline: Set<String> = ["-e", "-c", "--eval", "-p", "--print", "-pe"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if inline.contains(argument) { return nil }
            if argument == "-m" { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            guard argument.hasPrefix("-") else { return argument }
            index += valueFlags.contains(argument) ? 2 : 1
        }
        return nil
    }

    private static func absolute(_ path: String, cwd: String?) -> String {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        guard let cwd else { return path }
        return ((cwd as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
}
