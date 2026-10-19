import Foundation

/// Календарный месяц без дня и часового пояса: «2026-10».
///
/// Все начисления идут помесячно, поэтому месяц — отдельный value-тип, а не
/// `Date`: так не бывает сдвигов из-за поясов и летнего времени, а арифметика
/// («+12 месяцев», «сколько месяцев между») сводится к целым через `index`.
public struct YearMonth: Hashable, Comparable, Sendable {
    public let year: Int
    /// 1...12
    public let month: Int

    public init(year: Int, month: Int) {
        precondition((1...12).contains(month), "month must be in 1...12")
        self.year = year
        self.month = month
    }

    /// Сквозной номер месяца: удобно сравнивать, вычитать и сдвигать.
    public var index: Int { year * 12 + (month - 1) }

    public init(index: Int) {
        self.init(year: index / 12, month: index % 12 + 1)
    }

    /// Месяц, в который попадает дата по календарю (по умолчанию — часы компьютера).
    public init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month], from: date)
        self.init(year: components.year!, month: components.month!)
    }

    /// Разбор «2026-10» (так месяц лежит в SQLite). Месяц можно без нуля: «2026-1».
    public init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month)
        else { return nil }
        self.init(year: year, month: month)
    }

    public var stringValue: String { String(format: "%04d-%02d", year, month) }

    public func adding(months: Int) -> YearMonth { YearMonth(index: index + months) }
    public var previous: YearMonth { adding(months: -1) }
    public var next: YearMonth { adding(months: 1) }

    /// Сколько месяцев прошло от `other` до `self` (отрицательное, если `other` позже).
    public func months(since other: YearMonth) -> Int { index - other.index }

    /// Месяцы от `from` до `through` включительно; пусто, если `from` позже.
    public static func range(from: YearMonth, through: YearMonth) -> [YearMonth] {
        guard from <= through else { return [] }
        return (from.index...through.index).map(YearMonth.init(index:))
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool { lhs.index < rhs.index }
}

/// Календарная дата без времени: «2026-10-18». Для разовых трат и доходов.
public struct LocalDate: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        precondition(LocalDate.isValid(year: year, month: month, day: day), "invalid date")
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Разбор «2026-10-18» с проверкой, что такой день есть в месяце.
    public init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              LocalDate.isValid(year: year, month: month, day: day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var yearMonth: YearMonth { YearMonth(year: year, month: month) }
    public var stringValue: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Дата в полдень этого дня: полдень не съезжает на соседний день
    /// ни при смене пояса, ни при переводе часов.
    public func date(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        (1...12).contains(month) && day >= 1 && day <= daysIn(year: year, month: month)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
