import Foundation

/// Журнал старого guard (`logs/access.log`): когда что открывали и закрывали.
/// По нему Радарчик знает, сколько осталось до автозакрытия, — сам guard
/// таймер не показывает. Формат строк:
///
///     2026-10-20 09:42:18 [ALLOW] unlock ssh for me (mode: timer, timeout: 300s)
///     2026-10-20 09:47:18 [AUTO] auto-lock ssh after timeout
///     2026-10-20 10:00:00 [LOCK] locked all
///
/// Журнал пишется от твоего имени, подделать его может любая программа под тобой.
/// Поэтому он только для таймера и счётчиков, а закрыт ли файл, решает его владелец.
public enum LegacyGuardLog {
    public enum Action: Equatable, Sendable {
        case unlock(UnlockMode, timeout: TimeInterval?)
        case lock
        case deny
        case alarm
    }

    public struct Entry: Equatable, Sendable {
        public let at: Date
        public let action: Action
        /// «ssh», «env», «all»; у тревог — nil.
        public let category: String?

        public init(at: Date, action: Action, category: String?) {
            self.at = at
            self.action = action
            self.category = category
        }
    }

    /// guard без режима в строке (старые записи) закрывал через 5 минут.
    public static let defaultTimeout: TimeInterval = 300

    public static func parse(_ text: String, timeZone: TimeZone = .current) -> [Entry] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return text.split(whereSeparator: \.isNewline).compactMap { entry(String($0), formatter) }
    }

    /// Открытые сейчас окна: последнее открытие категории без закрытия после него.
    /// `unlock all` и `locked all` касаются всех категорий.
    public static func windows(_ entries: [Entry]) -> [GuardCategory: UnlockWindow] {
        var open: [GuardCategory: UnlockWindow] = [:]
        // Журнал и так по времени; сортировка с индексом — чтобы записи
        // одной секунды не поменялись местами.
        for (_, entry) in entries.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }) {
            let targets = categories(entry.category)
            switch entry.action {
            case .unlock(let mode, let timeout):
                let window = UnlockWindow(openedAt: entry.at, mode: mode, closesAt: timeout.map { entry.at.addingTimeInterval($0) })
                for category in targets { open[category] = window }
            case .lock:
                for category in targets { open[category] = nil }
            case .deny, .alarm:
                continue
            }
        }
        return open
    }

    /// Сколько раз что открывали начиная с `since` (сегодня с утра — для экрана).
    public static func unlockCounts(_ entries: [Entry], since: Date) -> [GuardCategory: Int] {
        var counts: [GuardCategory: Int] = [:]
        for entry in entries where entry.at >= since {
            guard case .unlock = entry.action else { continue }
            for category in categories(entry.category) { counts[category, default: 0] += 1 }
        }
        return counts
    }

    // MARK: - Разбор строки

    private static func categories(_ name: String?) -> [GuardCategory] {
        guard let name else { return [] }
        if name == "all" { return GuardCategory.allCases }
        return GuardCategory(rawValue: name).map { [$0] } ?? []
    }

    private static func entry(_ line: String, _ formatter: DateFormatter) -> Entry? {
        // «2026-10-20 09:42:18 [ALLOW] …»: дата — первые 19 символов.
        guard line.count > 22, let at = formatter.date(from: String(line.prefix(19))) else { return nil }
        let rest = line.dropFirst(20)
        guard rest.first == "[", let close = rest.firstIndex(of: "]") else { return nil }
        let tag = rest[rest.index(after: rest.startIndex)..<close]
        let message = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
        switch tag {
        case "ALLOW":
            // «unlock ssh for me (mode: timer, timeout: 300s)» или старое «unlock ssh for user me (timeout: 300s)».
            guard let category = word(after: "unlock ", in: message) else { return nil }
            let mode = capture(#"mode: (\w+)"#, in: message).flatMap(UnlockMode.init(rawValue:)) ?? .timer
            let timeout = capture(#"timeout: (\d+)s"#, in: message).flatMap(TimeInterval.init)
            return Entry(at: at, action: .unlock(mode, timeout: mode == .timer ? (timeout ?? defaultTimeout) : nil), category: category)
        case "AUTO":
            return word(after: "auto-lock ", in: message).map { Entry(at: at, action: .lock, category: $0) }
        case "LOCK":
            return word(after: "locked ", in: message).map { Entry(at: at, action: .lock, category: $0) }
        case "DENY":
            return word(after: "unlock ", in: message).map { Entry(at: at, action: .deny, category: $0) }
        case "DAEMON":
            return message.hasPrefix("ALARM") ? Entry(at: at, action: .alarm, category: nil) : nil
        case "ALARM":
            return Entry(at: at, action: .alarm, category: nil)
        default:
            return nil
        }
    }

    private static func word(after prefix: String, in message: String) -> String? {
        guard message.hasPrefix(prefix) else { return nil }
        let word = message.dropFirst(prefix.count).prefix { !$0.isWhitespace }
        return word.isEmpty ? nil : String(word)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// Что открыто и что показать в крыле.
public enum GuardStatus {
    /// guard закрывает фоновой задачей ровно по таймеру — даём ей полминуты,
    /// прежде чем сказать «открыто слишком долго».
    public static let overdueGrace: TimeInterval = 30

    /// Файлы по категориям в порядке `GuardCategory`; пустые категории не показываем.
    public static func categories(_ files: [ProtectedFile], windows: [GuardCategory: UnlockWindow]) -> [CategoryStatus] {
        GuardCategory.allCases.compactMap { category in
            let own = files.filter { $0.category == category }
            guard !own.isEmpty else { return nil }
            return CategoryStatus(category: category, files: own, window: windows[category])
        }
    }

    /// Крыло — только про то, что открыли через guard: у нового, ещё ни разу
    /// не закрытого ключа таймера нет, о нём говорит экран «Защита».
    public static func wing(_ categories: [CategoryStatus], now: Date) -> GuardWing? {
        let open = categories.filter { $0.isOpen && $0.window != nil }
        guard !open.isEmpty else { return nil }
        let remaining = open.compactMap { $0.window?.closesAt }.filter { $0 > now }.min().map { $0.timeIntervalSince(now) }
        let isOverdue = open.contains { status in
            guard let closesAt = status.window?.closesAt else { return false }
            return now > closesAt.addingTimeInterval(overdueGrace)
        }
        return GuardWing(categories: open.map(\.category), remaining: remaining, isOverdue: isOverdue)
    }
}
