import Foundation

/// Что нашлось в коде. Шаблоны — из `patterns.dat` старого guard, но починены:
/// там 5 из 22 обрезались на `|` и не работали (в том числе главный, `eval(atob(…))`),
/// а `["\x27]` в grep не означает одинарную кавычку.
public enum CodeThreat: String, Sendable, CaseIterable {
    // Почти наверняка малварь.
    /// `eval(atob(…))`, `eval(Buffer.from(…))` — расшифровать и выполнить.
    case evalDecoded
    /// `spawn(…, { detached: true })` из child_process — скрытый процесс, как у Beavertail.
    case detachedSpawn
    /// `Function('return this')` — выход из песочницы к глобальному объекту.
    case sandboxEscape
    /// `require('child_process').exec(…)` одной строкой.
    case childProcessExec
    /// `\x63\x68…` и `eval` в одной строке.
    case hexEval
    /// `new Function(…fromCharCode…)`.
    case functionFromCharCode
    /// Код собирается из переменных окружения через fromCharCode.
    case envDecode
    /// Расшифровать и выполнить.
    case decryptEval
    /// В конфиге сборки (babel, tailwind, vite…) — сеть, eval или запуск программ.
    /// Конфиг выполняется на каждой сборке, Beavertail прятался в babel.config.js.
    case configLogic
    /// `postinstall` и соседи в package.json что-то скачивают или выполняют.
    case installScript
    /// Код обфусцирован (по метрикам, а не по шаблонам).
    case obfuscated

    // Стоит глянуть.
    case eval
    case functionConstructor
    case childProcess
    /// `.exec('curl …')`, `.exec("bash …")`.
    case shellExec
    case charCodeJoin
    case base64Decode
    /// Адрес по IP, а не по имени: `http://185.12.4.7:1224`.
    case hardcodedIP
    case unicodeEscapes
    case fetchEval
    /// Код в TXT-записи DNS.
    case dnsTXT
    /// Адрес сервера из транзакций блокчейна (TRON, Aptos, BSC) — его не удалить.
    case blockchainDeadDrop
    /// `windowsHide: true` — спрятать окно запущенного процесса.
    case hiddenWindow
    case maybeObfuscated

    public var level: GuardLevel {
        switch self {
        case .evalDecoded, .detachedSpawn, .sandboxEscape, .childProcessExec, .hexEval, .functionFromCharCode,
             .envDecode, .decryptEval, .configLogic, .installScript, .obfuscated:
            .critical
        case .eval, .functionConstructor, .childProcess, .shellExec, .charCodeJoin, .base64Decode, .hardcodedIP,
             .unicodeEscapes, .fetchEval, .dnsTXT, .blockchainDeadDrop, .hiddenWindow, .maybeObfuscated:
            .warning
        }
    }

    /// Коротко, для экрана «Защита» и терминала.
    public var title: String {
        switch self {
        case .evalDecoded: L("расшифровывает и выполняет код", "decodes and runs code")
        case .detachedSpawn: L("запускает скрытый фоновый процесс", "starts a hidden background process")
        case .sandboxEscape: L("выходит из песочницы через Function('return this')", "escapes the sandbox via Function('return this')")
        case .childProcessExec: L("сразу запускает команду через child_process", "runs a command via child_process right away")
        case .hexEval: L("hex-строки и eval", "hex strings and eval")
        case .functionFromCharCode: L("собирает код из кодов символов", "builds code from character codes")
        case .envDecode: L("собирает код из переменных окружения", "builds code from environment variables")
        case .decryptEval: L("расшифровывает и выполняет", "decrypts and runs")
        case .configLogic: L("конфиг сборки ходит в сеть или запускает код", "a build config reaches the network or runs code")
        case .installScript: L("скрипт установки пакета что-то скачивает или запускает", "a package install script downloads or runs something")
        case .obfuscated: L("код обфусцирован", "the code is obfuscated")
        case .eval: "eval()"
        case .functionConstructor: "new Function()"
        case .childProcess: "child_process"
        case .shellExec: L("запуск curl/bash/node из кода", "runs curl/bash/node from code")
        case .charCodeJoin: L("строки из кодов символов", "strings from character codes")
        case .base64Decode: L("расшифровка base64", "base64 decoding")
        case .hardcodedIP: L("адрес сервера по IP", "a server address by IP")
        case .unicodeEscapes: L("строки в \\u-кодах", "strings in \\u escapes")
        case .fetchEval: L("скачивает и выполняет", "downloads and runs")
        case .dnsTXT: L("код из TXT-записи DNS", "code from a DNS TXT record")
        case .blockchainDeadDrop: L("адрес из блокчейна (TRON, Aptos, BSC)", "an address from a blockchain (TRON, Aptos, BSC)")
        case .hiddenWindow: L("прячет окно процесса", "hides the process window")
        case .maybeObfuscated: L("похоже на обфускацию", "looks obfuscated")
        }
    }
}

/// Одна находка: файл, строка и кусок кода без секретов.
public struct CodeFinding: Sendable, Equatable, Identifiable {
    public var id: String { "\(file):\(threat.rawValue)" }
    /// Путь от корня репозитория.
    public let file: String
    /// С единицы; nil — про файл целиком (обфускация).
    public let line: Int?
    public let threat: CodeThreat
    /// Не длиннее 120 символов, секреты вычищены.
    public let excerpt: String

    public init(file: String, line: Int?, threat: CodeThreat, excerpt: String) {
        self.file = file
        self.line = line
        self.threat = threat
        self.excerpt = excerpt
    }
}

/// После чего проверяли.
public enum CodeScanTrigger: String, Sendable {
    case pull
    case checkout
    case clone
    case manual

    /// «git pull» — для фразы.
    public var command: String {
        switch self {
        case .pull: "git pull"
        case .checkout: "git checkout"
        case .clone: "git clone"
        case .manual: L("проверки", "the check")
        }
    }
}

/// Итог одной проверки.
public struct CodeScanReport: Sendable, Equatable {
    public let repository: String
    public let trigger: CodeScanTrigger
    public let filesChecked: Int
    /// Пропущено: слишком большие и нечитаемые.
    public let skipped: Int
    public let findings: [CodeFinding]

    public init(repository: String, trigger: CodeScanTrigger, filesChecked: Int, skipped: Int, findings: [CodeFinding]) {
        self.repository = repository
        self.trigger = trigger
        self.filesChecked = filesChecked
        self.skipped = skipped
        self.findings = findings
    }

    public var level: GuardLevel { findings.map(\.threat.level).max() ?? .info }
    public var critical: [CodeFinding] { findings.filter { $0.threat.level == .critical } }
    public var warnings: [CodeFinding] { findings.filter { $0.threat.level == .warning } }
    /// «storefront».
    public var repositoryName: String { (repository as NSString).lastPathComponent }

    /// Находки одной строки вместе: «логика в конфиге, eval и адрес по IP» —
    /// одна строка кода, и показывать её трижды незачем. Порядок — как у находок
    /// (опасное первым), внутри группы — тоже.
    public var groups: [CodeFindingGroup] {
        var order: [String] = []
        var groups: [String: CodeFindingGroup] = [:]
        for finding in findings {
            let key = "\(finding.file):\(finding.line.map(String.init) ?? "")"
            if let group = groups[key] {
                groups[key] = CodeFindingGroup(file: group.file, line: group.line, threats: group.threats + [finding.threat], excerpt: group.excerpt)
            } else {
                order.append(key)
                groups[key] = CodeFindingGroup(file: finding.file, line: finding.line, threats: [finding.threat], excerpt: finding.excerpt)
            }
        }
        return order.compactMap { groups[$0] }
    }
}

/// Одно место в коде и всё, что на нём нашлось.
public struct CodeFindingGroup: Sendable, Equatable {
    public let file: String
    public let line: Int?
    public let threats: [CodeThreat]
    public let excerpt: String

    public var level: GuardLevel { threats.map(\.level).max() ?? .info }
}

/// Насколько код похож на обфусцированный: очки и признаки.
public struct ObfuscationScore: Sendable, Equatable {
    public let score: Int
    public let signs: [String]
}

/// Проверка кода после `git pull`, `git checkout` и `git clone` (SPEC §3б).
/// Только шаблоны и метрики над текстом — сам git и чтение файлов снаружи.
///
/// Что проверяем: JS/TS, Ruby, Python, shell, PHP, HTML/ERB и package.json.
/// Swift — нет: манифест и плагины SwiftPM на маке выполняются в песочнице.
public enum CodeScanner {
    /// Больше мегабайта — это не код, который пишут руками.
    public static let maxFileSize = 1_000_000
    /// Сколько кода показывать в находке.
    public static let excerptLimit = 120

    // MARK: - Что проверять

    private static let skippedFolders: Set<String> = [
        "node_modules", "vendor", ".git", "dist", "build", ".next", ".nuxt", ".output", "coverage", "tmp", ".yarn", "bower_components",
    ]
    private static let skippedPrefixes = ["public/assets/", "public/packs", "public/vite", "app/assets/builds/"]
    private static let lockfiles: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "gemfile.lock", "podfile.lock",
        "cargo.lock", "composer.lock", "poetry.lock", "pipfile.lock",
    ]
    private static let minifiedSuffixes = [".min.js", ".min.mjs", ".min.css", "-min.js", ".bundle.js"]
    /// Код, который выполняется у тебя: при сборке, установке, запуске.
    private static let codeExtensions: Set<String> = [
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts", "vue", "svelte", "rb", "rake", "gemspec", "ru", "py", "sh", "bash", "zsh",
        "php", "pl", "ps1", "html", "htm", "erb",
    ]
    /// Ruby без расширения, который тоже выполняется (bundler, rake, fastlane).
    private static let rubyFiles: Set<String> = ["gemfile", "rakefile", "podfile", "fastfile", "dangerfile", "guardfile", "capfile", "vagrantfile", "brewfile"]
    /// Обфускацию ищем только в коде: в HTML и шаблонах длинные строки и base64 — норма.
    private static let obfuscationExtensions: Set<String> = ["js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts", "py", "rb", "php", "sh"]

    /// Проверять ли файл (путь от корня репозитория). Пропускаем:
    /// - данные, документы и шифровки (`*.yml.enc` Rails — 296 ложных «обфускаций»
    ///   из 362 у старого guard);
    /// - lock-файлы, vendor, node_modules, сборки и минифицированное.
    public static func shouldScan(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let parts = lowered.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: skippedFolders.contains) { return false }
        if skippedPrefixes.contains(where: lowered.hasPrefix) { return false }
        if lockfiles.contains(name) || minifiedSuffixes.contains(where: name.hasSuffix) { return false }
        if name == "package.json" { return true }
        if rubyFiles.contains(name) { return true }
        // Скрипты без расширения в bin/ и script/ (bin/setup, script/deploy).
        if !name.contains("."), parts.count > 1, ["bin", "script", "scripts"].contains(parts[parts.count - 2]) { return true }
        return codeExtensions.contains((name as NSString).pathExtension)
    }

    // MARK: - Проверка файла

    /// Находки в одном файле — каждая угроза один раз, на первой строке, где встретилась.
    /// Файлы, которые `shouldScan` пропускает, здесь тоже ничего не дают.
    public static func scan(path: String, content: String) -> [CodeFinding] {
        guard shouldScan(path) else { return [] }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "package.json" { return installScripts(path: path, content: content) }

        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var findings: [CodeFinding] = []
        var found = Set<CodeThreat>()
        func add(_ threat: CodeThreat, line index: Int?, match: NSRange? = nil) {
            guard !found.contains(threat) else { return }
            found.insert(threat)
            let text = index.map { lines[$0] } ?? ""
            findings.append(CodeFinding(file: path, line: index.map { $0 + 1 }, threat: threat, excerpt: excerpt(text, around: match, threat: threat)))
        }

        let isConfig = configFiles.contains(name)
        for (index, line) in lines.enumerated() {
            for threat in lineThreats where !found.contains(threat) && (threat != .configLogic || isConfig) {
                if let match = locate(threat, in: line) { add(threat, line: index, match: match) }
            }
        }
        // Скрытый процесс собирают на нескольких строках: require, spawn, { detached: true }.
        if content.contains("child_process"), first(spawnCall, in: content) != nil,
           let index = lines.firstIndex(where: { first(detachedTrue, in: $0) != nil }) {
            add(.detachedSpawn, line: index, match: first(detachedTrue, in: lines[index]))
        }
        if obfuscationExtensions.contains((name as NSString).pathExtension) {
            let score = obfuscation(content)
            if score.score >= 60 {
                add(.obfuscated, line: nil)
            } else if score.score >= 30 {
                add(.maybeObfuscated, line: nil)
            }
        }
        // Критичное — первым: его показываем в чёлке.
        return findings.enumerated().sorted { ($1.element.threat.level, $0.offset) < ($0.element.threat.level, $1.offset) }.map(\.element)
    }

    // MARK: - Шаблоны

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Шаблоны свои и проверены тестами, поэтому `try!` безопасен.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let quote = #"['"`]"#
    private static let evalCall = regex(#"(?<![.\w])eval\s*\("#)
    private static let evalWord = regex(#"\beval\b"#)

    /// Шаблон по шагам: каждый следующий ищется после предыдущего. Так «A, потом B,
    /// потом C» проверяется за один проход по строке. Регулярка `A.*B.*C` на длинной
    /// строке без совпадения ушла бы в перебор и подвесила бы проверку.
    private static let steps: [CodeThreat: [NSRegularExpression]] = [
        .evalDecoded: [regex(#"(?<![.\w])eval\s*\(\s*(?:atob|Buffer\.from|unescape|decodeURIComponent)\b"#)],
        .sandboxEscape: [regex(#"\bFunction\s*\(\s*"# + quote + #"return\s+this"#)],
        .childProcessExec: [regex(#"require\s*\(\s*"# + quote + #"child_process"# + quote + #"\s*\)\s*\.\s*(?:exec|execSync|spawn|execFile)\b"#)],
        .functionFromCharCode: [regex(#"\bnew\s+Function\s*\("#), regex(#"fromCharCode"#)],
        .envDecode: [regex(#"process\.env"#), regex(#"\.split\b"#), regex(#"\.map\b"#), regex(#"String\.fromCharCode"#)],
        .decryptEval: [regex(#"[dD]ecipher"#), regex(#"\.update\s*\("#), evalCall],
        .eval: [evalCall],
        .functionConstructor: [regex(#"\bnew\s+Function\s*\("#)],
        .childProcess: [regex(#"child_process"#)],
        .shellExec: [regex(#"\.exec(?:Sync)?\s*\(\s*"# + quote + #"\s*(?:curl|wget|bash|sh|zsh|node|python[0-9.]*)\b"#)],
        .charCodeJoin: [regex(#"fromCharCode"#), regex(#"\.join\s*\("#)],
        .base64Decode: [regex(#"Buffer\.from\s*\("#), regex(quote + #"base64"# + quote)],
        .fetchEval: [regex(#"XMLHttpRequest|\bfetch\s*\("#), evalCall],
        .dnsTXT: [regex(#"\bresolveTxt\b|\bdns\.resolve\s*\([^)\n]*"# + quote + #"TXT"# + quote, [.caseInsensitive])],
        .blockchainDeadDrop: [regex(#"api\.trongrid\.io|\btronweb\b|aptoslabs\.com|bscscan\.com|bsc-dataseed"#, [.caseInsensitive])],
        .hiddenWindow: [regex(#"windowsHide\s*:\s*true"#)],
    ]

    /// Что ищем построчно и в каком порядке.
    private static let lineThreats: [CodeThreat] = [
        .evalDecoded, .sandboxEscape, .childProcessExec, .hexEval, .functionFromCharCode, .envDecode, .decryptEval, .configLogic,
        .eval, .functionConstructor, .childProcess, .shellExec, .charCodeJoin, .base64Decode, .hardcodedIP, .unicodeEscapes,
        .fetchEval, .dnsTXT, .blockchainDeadDrop, .hiddenWindow,
    ]

    /// Где в строке угроза; nil — её там нет.
    private static func locate(_ threat: CodeThreat, in line: String) -> NSRange? {
        switch threat {
        case .hexEval:
            // Три и больше `\xNN` и eval в одной строке.
            guard hexEscape.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) >= 3 else { return nil }
            return first([evalWord], in: line)
        case .unicodeEscapes:
            let all = NSRange(line.startIndex..., in: line)
            return unicodeEscape.numberOfMatches(in: line, range: all) >= 3 ? unicodeEscape.firstMatch(in: line, range: all)?.range : nil
        case .hardcodedIP:
            return publicIPAddress(in: line)
        case .configLogic:
            return first(configDanger, in: line)
        case .detachedSpawn:
            return first(detachedTrue, in: line)
        default:
            guard let steps = steps[threat] else { return nil }
            return inOrder(steps, in: line)
        }
    }

    /// Все шаги по порядку; найденное — место первого шага.
    private static func inOrder(_ steps: [NSRegularExpression], in line: String) -> NSRange? {
        let length = (line as NSString).length
        var from = 0
        var start: NSRange?
        for step in steps {
            guard from <= length, let match = step.firstMatch(in: line, range: NSRange(location: from, length: length - from)) else { return nil }
            if start == nil { start = match.range }
            from = match.range.location + match.range.length
        }
        return start
    }

    private static let spawnCall = [regex(#"\bspawn\s*\("#)]
    private static let detachedTrue = [regex(#"detached\s*:\s*true"#)]

    /// Конфиги сборки — их выполняет каждая сборка и тесты. Логики там быть не должно.
    private static let configFiles: Set<String> = [
        "babel.config.js", "babel.config.cjs", "babel.config.mjs", ".babelrc.js", "webpack.config.js", "webpack.config.ts",
        "rollup.config.js", "rollup.config.mjs", "vite.config.js", "vite.config.ts", "vite.config.mjs", "jest.config.js",
        "jest.config.ts", ".eslintrc.js", ".eslintrc.cjs", "eslint.config.js", "eslint.config.mjs", "prettier.config.js",
        ".prettierrc.js", "tailwind.config.js", "tailwind.config.ts", "tailwind.config.cjs", "postcss.config.js",
        "postcss.config.cjs", "next.config.js", "next.config.mjs", "next.config.ts", "nuxt.config.js", "nuxt.config.ts",
        "svelte.config.js", "astro.config.mjs", "metro.config.js", "craco.config.js", "vue.config.js", "karma.conf.js",
        "gulpfile.js", "gruntfile.js",
    ]
    private static let configDanger = [regex(
        #"(?<![.\w])eval\s*\(|child_process|\.exec(?:Sync)?\s*\(|Buffer\.from\s*\(|\batob\s*\(|new\s+Function|\bfetch\s*\(\s*"#
            + quote + #"https?:|\bhttps?\.(?:get|request)\s*\(|require\s*\(\s*"# + quote + #"(?:https?|net|dgram|child_process)"# + quote
    )]

    private static let ipURL = regex(#"https?://(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})"#)

    /// IP-адрес в ссылке, кроме локальных: 127.*, 10.*, 192.168.*, 172.16–31.*, 169.254.*, 0.0.0.0.
    private static func publicIPAddress(in line: String) -> NSRange? {
        for match in ipURL.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            let octets = (1...4).compactMap { Range(match.range(at: $0), in: line).flatMap { Int(line[$0]) } }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { continue }
            let isLocal = octets[0] == 127 || octets[0] == 10 || octets[0] == 0
                || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
            if !isLocal { return match.range }
        }
        return nil
    }

    private static func first(_ regexes: [NSRegularExpression], in text: String) -> NSRange? {
        let range = NSRange(text.startIndex..., in: text)
        return regexes.lazy.compactMap { $0.firstMatch(in: text, range: range)?.range }.first
    }

    // MARK: - package.json

    /// Скрипты, которые npm и yarn запускают сами при установке пакетов.
    private static let lifecycleScripts: Set<String> = [
        "preinstall", "install", "postinstall", "prepare", "prepack", "postpack", "prepublish", "prepublishOnly", "preuninstall", "postuninstall",
    ]
    private static let installDanger = regex(
        #"\b(?:curl|wget)\b|\bnode\s+(?:-e|--eval|-p|--print)\b|\b(?:sh|bash|zsh)\s+-c\b|\bpython[0-9.]*\s+-c\b|\bbase64\b|\beval\b|https?://\d"#
    )

    private static func installScripts(path: String, content: String) -> [CodeFinding] {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else { return [] }
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        for name in scripts.keys.sorted() where lifecycleScripts.contains(name) {
            guard let command = scripts[name] as? String,
                  installDanger.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
            else { continue }
            let line = lines.firstIndex { $0.contains("\"\(name)\"") }
            let shown = "\"\(name)\": \"\(command)\""
            return [CodeFinding(file: path, line: line.map { $0 + 1 }, threat: .installScript, excerpt: excerpt(shown, around: nil, threat: .installScript))]
        }
        return []
    }

    // MARK: - Кусок кода для показа

    /// Строка без секретов, вокруг найденного места, не длиннее `excerptLimit`.
    /// Секреты вычищаются по всей строке до обрезки: иначе обрезанный пополам
    /// ключ не узнать и половина утекла бы на экран.
    private static func excerpt(_ line: String, around match: NSRange?, threat: CodeThreat) -> String {
        let redacted = ShellRedactor.redact(line)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard redacted.count > excerptLimit else { return redacted }
        // Где найденное теперь, после вычистки: ищем ту же угрозу заново.
        var start = 0
        if match != nil, let found = locate(threat, in: redacted), let range = Range(found, in: redacted) {
            start = max(redacted.distance(from: redacted.startIndex, to: range.lowerBound) - 30, 0)
        }
        let characters = Array(redacted)
        // Два места под «…» по краям — и ровно `excerptLimit` в сумме.
        let width = excerptLimit - 2
        let from = min(start, max(characters.count - width, 0))
        let to = min(from + width, characters.count)
        return (from > 0 ? "…" : "") + String(characters[from..<to]) + (to < characters.count ? "…" : "")
    }

    // MARK: - Обфускация

    private static let dataURI = regex(#"data:[\w/+.-]*;base64,[A-Za-z0-9+/=]+"#)
    private static let hexEscape = regex(#"\\x[0-9a-fA-F]{2}"#)
    private static let unicodeEscape = regex(#"\\u[0-9a-fA-F]{4}"#)
    private static let base64Blob = regex(#"[A-Za-z0-9+/]{100,}={0,2}"#)
    private static let encodedArray = regex(#"\[\s*(?:(?:"[^"\n]{1,50}"|'[^'\n]{1,50}')\s*,\s*){10,}"#)
    private static let shortVariable = regex(#"\b(?:var|let|const)\s+[a-zA-Z_$]{1,2}\s*="#)
    private static let splitKeyword = regex(#"(?:"[a-z]{1,4}"|'[a-z]{1,4}')\s*\+\s*(?:"[a-z]{1,4}"|'[a-z]{1,4}')\s*\+\s*(?:"[a-z]{1,4}"|'[a-z]{1,4}')"#)

    /// Обфусцированный код отличается от обычного по метрикам — так ловится и
    /// незнакомая обфускация, для которой шаблона нет. Очки как в codescan.sh:
    /// от 60 — обфускация, от 30 — «похоже».
    public static func obfuscation(_ content: String) -> ObfuscationScore {
        // Картинки в data:-ссылках — законный base64, их не считаем.
        let text = dataURI.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
        let range = NSRange(text.startIndex..., in: text)
        func count(_ regex: NSRegularExpression) -> Int { regex.numberOfMatches(in: text, range: range) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var score = 0
        var signs: [String] = []

        let long = lines.filter { $0.count > 500 }.count
        if long > 3 {
            score += 30
            signs.append(L("\(long) строк длиннее 500 символов", "\(long) lines longer than 500 characters"))
        }
        let veryLong = lines.filter { $0.count > 1_000 }.count
        if veryLong > 0 {
            score += 40
            signs.append(L("строк длиннее 1000 символов: \(veryLong)", "lines longer than 1000 characters: \(veryLong)"))
        }
        let hex = count(hexEscape)
        if hex > 20 {
            score += 40
            signs.append(L("\(hex) hex-кодов \\xNN", "\(hex) \\xNN hex escapes"))
        }
        let unicode = count(unicodeEscape)
        if unicode > 20 {
            score += 40
            signs.append(L("\(unicode) кодов \\uNNNN", "\(unicode) \\uNNNN escapes"))
        }
        let blobs = count(base64Blob)
        if blobs > 0 {
            score += 35
            signs.append(L("base64 длиннее 100 символов: \(blobs)", "base64 longer than 100 characters: \(blobs)"))
        }
        if count(encodedArray) > 0 {
            score += 35
            signs.append(L("массив из 10+ закодированных строк", "an array of 10+ encoded strings"))
        }
        // На коротком файле доля ничего не значит: 1 из 2 строк — уже 50%.
        if lines.count >= 10 {
            let percent = count(shortVariable) * 100 / lines.count
            if percent > 30 {
                score += 25
                signs.append(L("однобуквенные переменные в \(percent)% строк", "one-letter variables on \(percent)% of lines"))
            }
        }
        if text.count > 200 {
            let symbols = text.unicodeScalars.filter { "[](){}!@#$%^&*~|\\".unicodeScalars.contains($0) }.count
            let letters = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
            if letters > 0, symbols * 100 / letters > 60 {
                score += 30
                signs.append(L("спецсимволов \(symbols * 100 / letters)% от букв", "symbols at \(symbols * 100 / letters)% of letters"))
            }
        }
        let charCodes = text.components(separatedBy: "fromCharCode").count - 1
        if charCodes > 5 {
            score += 30
            signs.append(L("\(charCodes) вызовов fromCharCode", "\(charCodes) fromCharCode calls"))
        }
        let splits = count(splitKeyword)
        if splits > 3 {
            score += 25
            signs.append(L("\(splits) склеек коротких строк", "\(splits) short-string concatenations"))
        }
        return ObfuscationScore(score: score, signs: signs)
    }
}
