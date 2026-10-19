import Foundation

/// Вычистка секретов из команд терминала — до записи на диск (SPEC §3).
///
/// Правила по убыванию надёжности:
/// 1. Целые блоки и известные форматы токенов (приватные ключи, sk-ant-, ghp_, AKIA…, JWT).
/// 2. Логин:пароль в адресах и секретные параметры query.
/// 3. Заголовок Authorization и флаги вида `--password=…`, `--token …`.
/// 4. Присваивания с «секретным» именем: `RAILS_MASTER_KEY=…`, `API_TOKEN=…`.
/// 5. Длинные случайные строки (32+ символа с цифрами и буквами): ключи, хэши, UUID.
///
/// Лишняя вычистка безопаснее пропущенного секрета: длинное имя ветки
/// с цифрами тоже превратится в ‹secret›, и это осознанный выбор.
public enum ShellRedactor {
    public static let placeholder = "‹secret›"

    public static func redact(_ command: String) -> String {
        var text = command
        for rule in rules {
            text = rule.apply(to: text)
        }
        return redactRandomBlobs(text)
    }

    /// Шаблон для поиска повторов и для LLM: без значений, кавычек и чисел,
    /// домашняя папка — «~». `git commit -m "fix"` → `git commit -m "…"`.
    public static func template(_ redacted: String, home: String) -> String {
        var text = shortenHome(redacted, home: home)
        text = replace(#""[^"]*""#, in: text, with: "\"…\"")
        text = replace(#"'[^']*'"#, in: text, with: "'…'")
        text = replace(#"\b([A-Za-z_][A-Za-z0-9_]*)=\S+"#, in: text, with: "$1=…")
        text = replace(#"\b\d+\b"#, in: text, with: "N")
        text = replace(#"\s+"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `/Users/me/work` → `~/work` (только целый компонент пути).
    public static func shortenHome(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?=/|\s|$|["'])"#
        return replace(pattern, in: text, with: "~")
    }

    // MARK: - Правила

    private struct Rule {
        let regex: NSRegularExpression
        let template: String

        func apply(to text: String) -> String {
            regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
    }

    private static func rule(_ pattern: String, _ template: String, _ options: NSRegularExpression.Options = []) -> Rule {
        // Шаблоны свои и проверены тестами, поэтому `try!` здесь безопасен.
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template)
    }

    private static let rules: [Rule] = [
        // 1. Приватные ключи и известные форматы токенов.
        rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----"#, placeholder, [.dotMatchesLineSeparators]),
        rule(#"sk-ant-[A-Za-z0-9_\-]{8,}"#, placeholder),
        rule(#"\bsk-[A-Za-z0-9_\-]{20,}"#, placeholder),
        rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, placeholder),
        rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, placeholder),
        rule(#"\bglpat-[A-Za-z0-9_\-]{20,}"#, placeholder),
        rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, placeholder),
        rule(#"\bAKIA[0-9A-Z]{16}\b"#, placeholder),
        rule(#"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}"#, placeholder),
        rule(#"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#, placeholder),
        // 2. Логин:пароль в адресе и секретные параметры query.
        rule(#"(\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s/:@]+):[^\s/@]+@"#, "$1:" + placeholder + "@"),
        rule(#"([?&](?:token|access_token|refresh_token|api_key|apikey|key|secret|password|sig|signature|auth|code)=)[^&\s"']+"#,
             "$1" + placeholder, [.caseInsensitive]),
        // 3. Заголовок Authorization и флаги с секретом.
        rule(#"(Authorization:\s*(?:Bearer|Basic|Token)?\s*)[^\s"']+"#, "$1" + placeholder, [.caseInsensitive]),
        rule(#"(--?(?:password|passwd|pass|token|secret|api[-_]?key|access[-_]?key|auth)(?:=|\s+))("[^"]*"|'[^']*'|[^\s"']+)"#,
             "$1" + placeholder, [.caseInsensitive]),
        // 4. Присваивания с «секретным» именем переменной.
        rule(#"\b([A-Za-z_][A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASS|PWD|AUTH|CREDENTIALS?|PRIVATE|SESSION|COOKIE|SALT|DSN)[A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s"']+)"#,
             "$1=" + placeholder, [.caseInsensitive]),
    ]

    /// 5. Длинные случайные строки: 32+ символа без «/» и «.», есть и цифры, и буквы.
    /// Пути и обычные длинные слова не трогаются.
    private static let blob = try! NSRegularExpression(pattern: #"[A-Za-z0-9+_\-]{32,}={0,2}"#)

    private static func redactRandomBlobs(_ text: String) -> String {
        var result = text as NSString
        let matches = blob.matches(in: text, range: NSRange(location: 0, length: result.length))
        // С конца, чтобы диапазоны ещё не заменённых совпадений не сдвигались.
        for match in matches.reversed() {
            let candidate = result.substring(with: match.range)
            if candidate.contains(where: \.isNumber) && candidate.contains(where: \.isLetter) {
                result = result.replacingCharacters(in: match.range, with: placeholder) as NSString
            }
        }
        return result as String
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

/// Сообщение от zsh-хука (Support/radarchik.zsh), формат v1:
/// `1 \t начало (сек, дробные) \t длительность (мс) \t код выхода \t папка \t команда`.
/// Сырая команда живёт только в памяти: в базу идёт `makeCommand` — уже чистая.
public struct ShellMessage: Equatable, Sendable {
    public let startedAt: Date
    public let durationMs: Int64
    public let exitCode: Int32
    public let cwd: String
    public let command: String

    public static func parse(_ raw: String) -> ShellMessage? {
        let parts = raw.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "1",
              let start = Double(parts[1]), let duration = Int64(parts[2]), let exitCode = Int32(parts[3])
        else { return nil }
        let command = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return ShellMessage(
            startedAt: Date(timeIntervalSince1970: start), durationMs: max(duration, 0),
            exitCode: exitCode, cwd: String(parts[4]), command: command
        )
    }

    public func makeCommand(home: String) -> ShellCommand {
        let clean = ShellRedactor.redact(command)
        return ShellCommand(
            command: clean,
            template: ShellRedactor.template(clean, home: home),
            cwd: ShellRedactor.shortenHome(cwd, home: home),
            startedAt: startedAt,
            durationMs: durationMs,
            exitCode: exitCode
        )
    }
}
