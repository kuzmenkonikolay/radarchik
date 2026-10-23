import Darwin
import Foundation

/// Процесс, как его видит слежка (SPEC §3б): программа, аргументы и кто её запустил.
public struct WatchedProcess: Sendable, Equatable {
    public let pid: Int32
    /// Время запуска: pid переиспользуются, а убить нужно ровно этот процесс.
    public let startTime: UInt64
    /// Путь к программе.
    public let path: String
    /// argv целиком, argv[0] первым.
    public let arguments: [String]
    /// Программа родителя; nil — родитель уже завершился или чужой.
    public let parentPath: String?

    public init(pid: Int32, startTime: UInt64, path: String, arguments: [String], parentPath: String?) {
        self.pid = pid
        self.startTime = startTime
        self.path = path
        self.arguments = arguments
        self.parentPath = parentPath
    }
}

/// Что настораживает в процессе. Правила — из ProcessGuard старого guard
/// (тот их так и не применил: `ps -o comm=` не отдаёт аргументы) и из того,
/// как ведут себя Beavertail и InvisibleFerret.
public enum ProcessThreat: String, Sendable, CaseIterable {
    /// `node -e "…"` — так запускался Beavertail.
    case inlineNode
    /// `python -c "…"`.
    case inlinePython
    /// Скачать и сразу выполнить: `curl … | sh`, `bash <(curl …)`.
    case downloadAndRun
    /// Расшифровать base64 и выполнить.
    case decodeAndRun
    /// Спрятать запуск в фоне: `nohup curl …`, `nohup node -e …`.
    case backgroundPayload
    /// Программа из временной папки.
    case tempExecutable
    /// Скрипт из неизвестной скрытой папки в домашней (`~/.n2/pay` у InvisibleFerret).
    case hiddenScript

    /// Коротко, для чёлки.
    public var title: String {
        switch self {
        case .inlineNode: "node -e"
        case .inlinePython: "python -c"
        case .downloadAndRun: L("Скачивает и сразу запускает: curl | sh", "Downloads and runs: curl | sh")
        case .decodeAndRun: L("Расшифровывает base64 и запускает", "Decodes base64 and runs it")
        case .backgroundPayload: L("Прячет запуск в фоне через nohup", "Hides a launch in the background with nohup")
        case .tempExecutable: L("Программа из временной папки", "A program from a temp folder")
        case .hiddenScript: L("Скрипт из скрытой папки", "A script from a hidden folder")
        }
    }
}

/// Находка: что, насколько серьёзно и командная строка для показа.
public struct ProcessFinding: Sendable, Equatable {
    public let threat: ProcessThreat
    public let level: GuardLevel
    public let process: WatchedProcess
    /// Без секретов и не длиннее 160 символов — для чёлки и журнала.
    public let commandLine: String

    /// По нему работает «Разрешать всегда»: что за угроза, какая программа и кто её запустил.
    /// «node -e из Cursor» и «node -e неизвестно откуда» — разные ключи.
    public var allowKey: String {
        "\(threat.rawValue)|\(process.path)|\(process.parentPath ?? "")"
    }
}

public enum ProcessWatchRules {
    /// Код длиннее этого в `node -e` или `python -c` — уже не «узнать версию».
    public static let longInlineCode = 300
    /// Сколько командной строки показывать.
    public static let commandLineLimit = 160

    public static func evaluate(_ process: WatchedProcess, home: String) -> ProcessFinding? {
        let name = (process.path as NSString).lastPathComponent.lowercased()
        let arguments = Array(process.arguments.dropFirst())
        guard let (threat, level) = verdict(name: name, path: process.path, arguments: arguments, home: home) else { return nil }
        return ProcessFinding(threat: threat, level: level, process: process, commandLine: commandLine(process.arguments))
    }

    // MARK: - Правила

    private static func verdict(name: String, path: String, arguments: [String], home: String) -> (ProcessThreat, GuardLevel)? {
        if isNode(name), let code = inlineCode(arguments, flags: ["-e", "--eval", "-p", "--print", "-pe"], valueFlags: nodeValueFlags, stopAt: []) {
            return (.inlineNode, isDangerous(code, tokens: nodeTokens) ? .critical : .warning)
        }
        if isPython(name), let code = inlineCode(arguments, flags: ["-c"], valueFlags: ["-W", "-X"], stopAt: ["-m"]) {
            return (.inlinePython, isDangerous(code, tokens: pythonTokens) ? .critical : .warning)
        }
        if shells.contains(name), let script = shellScript(arguments) {
            if matches(downloadAndRun, script) { return (.downloadAndRun, .critical) }
            if matches(decodeAndRun, script) { return (.decodeAndRun, .critical) }
            if matches(backgroundPayload, script) { return (.backgroundPayload, .critical) }
            return nil
        }
        if isTemp(path) { return (.tempExecutable, .warning) }
        if interpreters.contains(name) || isPython(name) || isNode(name),
           let script = firstScript(arguments), isInUnknownHiddenFolder(script, home: home) {
            return (.hiddenScript, .warning)
        }
        return nil
    }

    private static func isNode(_ name: String) -> Bool { name == "node" || name == "nodejs" || name == "bun" }

    /// python, python3, python3.12 и Python из Python.app.
    private static func isPython(_ name: String) -> Bool {
        guard name.hasPrefix("python") else { return false }
        return name.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." }
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    private static let interpreters: Set<String> = ["ruby", "perl", "php", "osascript", "sh", "bash", "zsh", "dash", "ksh", "deno"]

    /// Флаги node со значением через пробел: `node -r dotenv/config -e "…"`.
    private static let nodeValueFlags: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions", "--title", "--input-type",
    ]

    /// Встроенный код из аргументов: значение флага `-e` (или `--eval=…`). Ищем только среди
    /// флагов самой программы — до первого не-флага (имени скрипта): `node build.js -e`
    /// передаёт `-e` скрипту, а не node.
    private static func inlineCode(_ arguments: [String], flags: Set<String>, valueFlags: Set<String>, stopAt: Set<String>) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if stopAt.contains(argument) { return nil }
            if flags.contains(argument) {
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            if let equals = argument.firstIndex(of: "="), flags.contains(String(argument[..<equals])) {
                return String(argument[argument.index(after: equals)...])
            }
            // Не флаг — началось имя скрипта и его аргументы.
            guard argument.hasPrefix("-") else { return nil }
            index += valueFlags.contains(argument) ? 2 : 1
        }
        return nil
    }

    /// Признаки того, что встроенный код что-то скачивает, расшифровывает или запускает.
    private static let nodeTokens = [
        "eval(", "atob(", "Buffer.from(", "child_process", "spawn(", "exec(", "execSync(", "fromCharCode", "\\x",
        "require('http", "require(\"http", "require('net", "require(\"net", "fetch(", "XMLHttpRequest", "WebSocket", "decipher", "Decipher", "detached",
    ]
    private static let pythonTokens = [
        "exec(", "eval(", "base64", "b64decode", "marshal", "zlib", "urllib", "socket", "subprocess", "os.system", "__import__",
        "requests.", "http.client", "pty.spawn",
    ]

    private static func isDangerous(_ code: String, tokens: [String]) -> Bool {
        code.count >= longInlineCode || tokens.contains { code.contains($0) }
    }

    /// Текст после `-c` у оболочки (`sh -c "…"`, `bash -lc "…"`, `bash --login -c "…"`).
    private static func shellScript(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return nil }
            // Длинные флаги (--login, --norc) — без значения, идём дальше.
            if argument.hasPrefix("--") {
                index += 1
                continue
            }
            // `-o pipefail` — у -o значение отдельным словом.
            if argument == "-o" || argument == "+o" {
                index += 2
                continue
            }
            guard argument.hasPrefix("-") else { return nil }
            if argument.dropFirst().contains("c") {
                return index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            index += 1
        }
        return nil
    }

    private static let runner = #"(?:sudo\s+)?(?:sh|bash|zsh|dash|ksh|python[0-9.]*|node|perl|ruby|osascript)\b"#
    private static let downloadAndRun = [
        // curl … | sh
        regex(#"\b(?:curl|wget)\b[^|;&\n]*\|\s*"# + runner),
        // bash <(curl …)
        regex(#"\b(?:sh|bash|zsh|dash|python[0-9.]*|node|perl|ruby)\b[^\n]*<\(\s*(?:curl|wget)\b"#),
        // python3 -c "$(curl …)", bash -c "$(curl …)", eval "$(curl …)"
        regex(#"\b(?:sh|bash|zsh|dash|python[0-9.]*|node|perl|ruby|eval)\b[^\n]*\$\(\s*(?:curl|wget)\b"#),
    ]
    private static let decodeAndRun = [
        regex(#"\bbase64\s+(?:-d|--decode|-D)\b[^\n]*\|\s*"# + runner),
        regex(#"\beval\s+"?\$\([^)]*\bbase64\s+(?:-d|--decode|-D)\b"#),
    ]
    private static let backgroundPayload = [
        regex(#"\bnohup\b[^\n]*(?:\b(?:curl|wget)\b|\bnode\s+(?:-e|--eval)\b|\bpython[0-9.]*\s+-c\b)"#),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Шаблоны свои и проверены тестами, поэтому `try!` безопасен.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regexes: [NSRegularExpression], _ text: String) -> Bool {
        regexes.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }

    // MARK: - Где лежит

    /// /tmp и временные папки пользователя. AppTranslocation — это macOS запускает
    /// приложение из «Загрузок» на карантине, так и должно быть.
    static func isTemp(_ path: String) -> Bool {
        if path.contains("/AppTranslocation/") { return false }
        if ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/"].contains(where: path.hasPrefix) { return true }
        // /var/folders/xx/yyyy/T/… — $TMPDIR пользователя.
        let parts = path.split(separator: "/")
        let offset = parts.first == "private" ? 1 : 0
        return parts.count > offset + 4 && parts[offset] == "var" && parts[offset + 1] == "folders" && parts[offset + 4] == "T"
    }

    /// Первый аргумент-путь: скрипт, который запускает интерпретатор.
    private static func firstScript(_ arguments: [String]) -> String? {
        arguments.first { !$0.hasPrefix("-") }
    }

    /// Скрытые папки инструментов, где скрипты живут законно.
    private static let knownHiddenFolders: Set<String> = [
        ".asdf", ".bun", ".bundle", ".cache", ".cargo", ".claude", ".codex", ".colima", ".config", ".continue", ".cursor",
        ".deno", ".docker", ".dotnet", ".expo", ".fnm", ".gem", ".gemini", ".goenv", ".gradle", ".jenv", ".kube", ".lima",
        ".local", ".m2", ".mise", ".node", ".nodenv", ".npm", ".npm-global", ".nvm", ".oh-my-zsh", ".orbstack", ".pnpm",
        ".proto", ".pyenv", ".rbenv", ".rd", ".rustup", ".rvm", ".sdkman", ".swiftpm", ".tfenv", ".volta", ".vscode",
        ".vscode-server", ".windsurf", ".yarn", ".zsh",
    ]

    static func isInUnknownHiddenFolder(_ script: String, home: String) -> Bool {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard script.hasPrefix(prefix + ".") else { return false }
        let first = script.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
        return !knownHiddenFolders.contains(first)
    }

    // MARK: - Показ

    /// argv через пробел, программа — без пути, секреты вычищены, длина — под чёлку.
    private static func commandLine(_ arguments: [String]) -> String {
        guard let first = arguments.first else { return "" }
        let parts = [(first as NSString).lastPathComponent] + arguments.dropFirst()
        let joined = ShellRedactor.redact(parts.joined(separator: " "))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard joined.count > commandLineLimit else { return joined }
        return String(joined.prefix(commandLineLimit - 1)) + "…"
    }
}

/// Аргументы и родитель процесса для слежки. Только процессы этого
/// пользователя: аргументы чужих (root) macOS не отдаёт — и это нормально,
/// малварь из npm-пакета работает от твоего имени.
public enum ProcessArguments {
    /// Программа и argv.
    public struct Command: Sendable, Equatable {
        public let path: String
        public let arguments: [String]
    }

    /// Родитель, владелец и время запуска (микросекунды с 1970).
    public struct Info: Sendable, Equatable {
        public let ppid: Int32
        public let uid: uid_t
        public let startTime: UInt64
    }

    public static func allPids() -> [Int32] { ProcessProbe.allPids() }

    /// Путь к программе процесса (`proc_pidpath`). После exec он меняется, а pid
    /// и время запуска — нет: так `sh -c "exec node -e …"` становится node.
    public static func path(of pid: Int32) -> String? { ProcessProbe.path(of: pid) }

    /// `proc_pidinfo(PROC_PIDTBSDINFO)`; nil — процесс завершился.
    public static func info(pid: Int32) -> Info? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Info(ppid: Int32(bitPattern: info.pbi_ppid), uid: info.pbi_uid, startTime: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    /// Родитель через `sysctl(KERN_PROC_PID)`: отвечает и про чужие процессы
    /// (`login` под root), где `proc_pidinfo` молчит. nil — процесса нет.
    public static func parentPid(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Самое длинное, что отдаёт `sysctl(KERN_PROCARGS2)`: argv и окружение вместе.
    private static let argumentsMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctl(&mib, 2, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : 1 << 20
    }()

    /// Программа и argv; nil — процесс чужой или уже завершился.
    public static func read(pid: Int32) -> Command? {
        var buffer: [UInt8] = []
        return read(pid: pid, buffer: &buffer)
    }

    /// То же с буфером, который живёт между вызовами: слежка читает процессы
    /// каждые 2 секунды, и выделять мегабайт на каждый незачем.
    public static func read(pid: Int32, buffer: inout [UInt8]) -> Command? {
        if buffer.count < argumentsMax { buffer = [UInt8](repeating: 0, count: argumentsMax) }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Раскладка: argc (Int32), путь при запуске, нули выравнивания,
        // argv[0…argc-1] через NUL, дальше окружение — его не читаем.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        guard let execPath = nextString() else { return nil }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<max(Int(argc), 0) {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }
        // Путь при запуске бывает относительным («./a.out») — берём настоящий.
        return Command(path: ProcessProbe.path(of: pid) ?? execPath, arguments: arguments)
    }

    /// Убить ровно тот процесс, что был в тревоге: если pid уже занял другой
    /// (время запуска не совпало), ничего не делаем.
    @discardableResult
    public static func kill(pid: Int32, startTime: UInt64) -> Bool {
        guard let info = info(pid: pid), info.startTime == startTime else { return false }
        return Darwin.kill(pid, SIGKILL) == 0
    }
}
