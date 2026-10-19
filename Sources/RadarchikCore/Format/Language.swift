import Foundation
import Synchronization

/// Язык интерфейса: русский или английский (решение 2026-10-19, перед open source).
///
/// Тексты лежат прямо в коде парами: `L("Настройки", "Settings")`. Языков два,
/// поэтому так проще, чем каталог строк: перевод виден рядом с оригиналом,
/// а подстановки (`\(сумма)`) проверяет компилятор.
///
/// Текущий язык один на всё приложение — его ставит `AppSettings`. Тесты
/// меняют его только внутри блока (`Language.$override.withValue(.en) { … }`),
/// поэтому параллельные тесты друг другу не мешают.
public enum Language: String, CaseIterable, Sendable {
    case ru
    case en

    /// Язык, на котором сейчас говорит Радарчик.
    public static var current: Language { override ?? appWide.withLock { $0 } }

    /// Поставить язык всему приложению (из настроек).
    public static func setAppWide(_ language: Language) {
        appWide.withLock { $0 = language }
    }

    /// Язык на время блока — для тестов и рендера экранов.
    @TaskLocal public static var override: Language?

    private static let appWide = Mutex(Language.ru)

    /// Для системных форматтеров и `\.locale` в SwiftUI.
    public var locale: Locale { Locale(identifier: self == .ru ? "ru_RU" : "en_US") }
}

/// Что выбрано в настройках. По умолчанию — как в системе.
public enum LanguageChoice: String, CaseIterable, Sendable {
    case system
    case ru
    case en

    /// `preferred` — языки системы по порядку (`Locale.preferredLanguages`).
    /// Смотрим только на первый: русская система — русский, любая другая — английский.
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> Language {
        switch self {
        case .ru: return .ru
        case .en: return .en
        case .system:
            guard let first = preferred.first else { return .en }
            return Locale.Language(identifier: first).languageCode == .russian ? .ru : .en
        }
    }
}

/// Текст на текущем языке: `L("Настройки", "Settings")`.
public func L(_ ru: String, _ en: String) -> String {
    Language.current == .ru ? ru : en
}

/// Слова на текущем языке: месяцы, порядковые, число и кавычки.
/// Падежи и русская грамматика — в `RussianWords`.
public enum Words {
    private static let monthsEnglish = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// «Октябрь» / «October».
    public static func monthName(_ month: Int) -> String {
        Language.current == .ru ? RussianWords.monthName(month) : monthsEnglish[month - 1]
    }

    /// «окт» / «Oct» — подписи на графике.
    public static func monthShort(_ month: Int) -> String {
        Language.current == .ru ? RussianWords.monthShort(month) : String(monthsEnglish[month - 1].prefix(3))
    }

    /// «Октябрь 2026» / «October 2026».
    public static func monthYear(_ month: YearMonth) -> String {
        "\(monthName(month.month)) \(month.year)"
    }

    /// «18 октября» / «October 18», с годом — «18 октября 2025» / «October 18, 2025».
    public static func dayMonth(_ day: Int, _ month: Int, year: Int? = nil) -> String {
        switch Language.current {
        case .ru:
            let text = "\(day) \(RussianWords.monthGenitive(month))"
            return year.map { "\(text) \($0)" } ?? text
        case .en:
            let text = "\(monthsEnglish[month - 1]) \(day)"
            return year.map { "\(text), \($0)" } ?? text
        }
    }

    /// «третий» (месяц) / «3rd».
    public static func ordinal(_ number: Int) -> String {
        guard Language.current == .en else { return RussianWords.ordinal(number) }
        let lastTwo = abs(number) % 100
        let suffix = switch (lastTwo, abs(number) % 10) {
        case (11...13, _): "th"
        case (_, 1): "st"
        case (_, 2): "nd"
        case (_, 3): "rd"
        default: "th"
        }
        return "\(number)\(suffix)"
    }

    /// Форма слова по числу: по-русски три формы (1 совет, 3 совета, 5 советов),
    /// по-английски две (1 tip, 3 tips).
    public static func plural(_ number: Int, ru: (String, String, String), en: (String, String)) -> String {
        switch Language.current {
        case .ru: RussianWords.plural(number, ru.0, ru.1, ru.2)
        case .en: number == 1 ? en.0 : en.1
        }
    }

    /// Название в кавычках: «Лендинг» / “Landing”.
    public static func quoted(_ text: String) -> String {
        Language.current == .ru ? "«\(text)»" : "“\(text)”"
    }
}
