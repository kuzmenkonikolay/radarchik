import Foundation
@testable import RadarchikCore

// Короткие конструкторы для тестов: суммы в целых рублях/долларах,
// месяцы и даты строками, все даты создания одинаковые и «круглые»
// (целые секунды), чтобы сравнение после SQLite было точным.

func ym(_ string: String) -> YearMonth { YearMonth(string: string)! }
func day(_ string: String) -> LocalDate { LocalDate(string: string)! }
/// Целые единицы валюты → копейки/центы.
func units(_ value: Int64) -> Int64 { value * 100 }

/// Проверки на английском интерфейсе. Язык меняется только внутри блока
/// (TaskLocal), поэтому параллельные тесты на русском ему не мешают.
func english<T>(_ body: () throws -> T) rethrows -> T {
    try Language.$override.withValue(.en, operation: body)
}

enum Fixture {
    static let createdAt = Date(timeIntervalSince1970: 1_760_000_000)

    static func project(_ name: String = "Курсы", currency: Currency = .rub, archived: Bool = false) -> Project {
        Project(name: name, colorHex: "#5AC8FA", currency: currency, createdAt: createdAt, isArchived: archived)
    }

    static func monthly(
        _ project: Project, _ name: String, _ amount: Int64,
        from: String, to: String? = nil, url: String? = nil, changes: [(String, Int64)] = []
    ) -> RecurringCost {
        recurring(project, name, amount, period: .monthly, from: from, to: to, url: url, changes: changes)
    }

    static func yearly(
        _ project: Project, _ name: String, _ amount: Int64,
        from: String, to: String? = nil, url: String? = nil, changes: [(String, Int64)] = []
    ) -> RecurringCost {
        recurring(project, name, amount, period: .yearly, from: from, to: to, url: url, changes: changes)
    }

    static func income(_ project: Project, _ amount: Int64, on date: String, name: String = "Подписки") -> Income {
        Income(projectId: project.id, name: name, amount: units(amount), date: day(date), createdAt: createdAt)
    }

    static func oneOff(_ project: Project, _ amount: Int64, on date: String, name: String = "Разовая", url: String? = nil) -> OneOffCost {
        OneOffCost(projectId: project.id, name: name, url: url, amount: units(amount), date: day(date), createdAt: createdAt)
    }

    private static func recurring(
        _ project: Project, _ name: String, _ amount: Int64, period: CostPeriod,
        from: String, to: String?, url: String?, changes: [(String, Int64)]
    ) -> RecurringCost {
        let prices = [PriceChange(effectiveFrom: ym(from), amount: units(amount))]
            + changes.map { PriceChange(effectiveFrom: ym($0.0), amount: units($0.1)) }
        return RecurringCost(
            projectId: project.id, name: name, url: url, period: period,
            startMonth: ym(from), endMonth: to.map(ym), prices: prices, createdAt: createdAt
        )
    }
}
