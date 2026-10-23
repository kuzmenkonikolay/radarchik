import Foundation

/// «Что это?» (2026-10-22, просьба пользователя): спросить Claude про процесс из алерта
/// ресурсов или про то, что заметила «Защита» — соединение скрипта, подозрительный
/// запуск, чужой с SSH-ключом. Уходит только то, что и так на экране, плюс путь и подпись
/// программы: имя, кто запустил (имена программ), цифры. Ни аргументов с секретами
/// (командная строка — уже после `ShellRedactor`), ни содержимого файлов.
public struct ExplainFacts: Equatable, Sendable {
    public enum Subject: String, Equatable, Sendable {
        /// Процесс ест больше обычного.
        case resource
        /// Скрипт или агент вышел в сеть.
        case network
        /// Подозрительный запуск.
        case process
        /// Чужой взял SSH-ключ.
        case agent
    }

    public let subject: Subject
    /// Фраза Радарчика из алерта: «duetexpertd ест 76% процессора — обычно почти ноль».
    public let headline: String
    public let process: String
    public let path: String?
    /// «системный, подпись Apple», «Developer ID Application: Anthropic PBC», «не подписан».
    public let signing: String?
    /// «curl ← zsh ← Claude Code ← zsh ← Terminal».
    public let chain: String?
    /// «держится 5 мин», «через прокси 127.0.0.1:8888».
    public let notes: [String]
    /// Командная строка уже без секретов.
    public let commandLine: String?

    public init(
        subject: Subject, headline: String, process: String, path: String? = nil, signing: String? = nil, chain: String? = nil, notes: [String] = [],
        commandLine: String? = nil
    ) {
        self.subject = subject
        self.headline = headline
        self.process = process
        self.path = path
        self.signing = signing
        self.chain = chain
        self.notes = notes
        self.commandLine = commandLine
    }
}

/// Ответ Claude: что это, стоит ли волноваться, что делать.
public struct Explanation: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        case normal
        case attention
        case unknown
    }

    public let what: String
    public let verdict: Verdict
    public let advice: String

    public init(what: String, verdict: Verdict, advice: String) {
        self.what = what
        self.verdict = verdict
        self.advice = advice
    }
}

/// Ответ с моделью и ценой — как у разбора дня.
public struct ExplainResult: Equatable, Sendable {
    public let explanation: Explanation
    public let model: String
    public let costUSD: Double

    public init(explanation: Explanation, model: String, costUSD: Double) {
        self.explanation = explanation
        self.model = model
        self.costUSD = costUSD
    }
}

public enum ExplainPrompt {
    public static var system: String {
        L("""
        Ты — Радарчик, маленький помощник в чёлке мака разработчика. Он заметил процесс или сетевое соединение и спрашивает: «что это?». \
        Ответь по делу, без вступлений. Поля: what — что это за программа (или куда и зачем обычно ходит такой процесс), одно-два предложения; \
        verdict — normal, если для такой программы это обычное поведение; attention, если стоит присмотреться; unknown, если по этим данным сказать нельзя; \
        advice — одно предложение, что делать: ничего, подождать, перезапустить, проверить, убить. \
        Не выдумывай: незнакомую программу так и назови незнакомой. Подпись Apple и системный путь — сильный довод за normal; \
        скрипт из node_modules, временной папки или адрес без имени — за attention. Пиши по-русски, обращайся на ты.
        """, """
        You are Radarchik, a small helper living in the notch of a developer’s Mac. They noticed a process or a network connection and ask: “what is this?”. \
        Answer to the point, no preamble. Fields: what — what this program is (or where and why such a process usually connects), one or two sentences; \
        verdict — normal if this is ordinary behaviour for such a program; attention if it deserves a look; unknown if the facts don’t say; \
        advice — one sentence on what to do: nothing, wait, restart, check, kill. \
        Don’t make things up: call an unfamiliar program unfamiliar. An Apple signature and a system path argue for normal; \
        a script from node_modules, a temp folder or a bare address argue for attention. Address the user informally.
        """)
    }

    /// Факты строками, по одной на строку: Claude читает их как список.
    public static func user(_ facts: ExplainFacts) -> String {
        var lines = [L("Заметил: \(facts.headline)", "Noticed: \(facts.headline)")]
        let kind: String = switch facts.subject {
        case .resource: L("процесс ест больше обычного", "a process eats more than usual")
        case .network: L("скрипт или агент вышел в сеть на новый адрес", "a script or agent reached a new address")
        case .process: L("подозрительный запуск", "a suspicious launch")
        case .agent: L("чужой процесс взял SSH-ключ", "a foreign process used the SSH key")
        }
        lines.append(L("Вид: \(kind)", "Kind: \(kind)"))
        lines.append(L("Программа: \(facts.process)", "Program: \(facts.process)"))
        if let path = facts.path { lines.append(L("Путь: \(path)", "Path: \(path)")) }
        if let signing = facts.signing { lines.append(L("Подпись: \(signing)", "Signature: \(signing)")) }
        if let chain = facts.chain { lines.append(L("Кто запустил: \(chain)", "Launched by: \(chain)")) }
        if let command = facts.commandLine { lines.append(L("Командная строка: \(command)", "Command line: \(command)")) }
        lines += facts.notes
        return lines.joined(separator: "\n")
    }
}
