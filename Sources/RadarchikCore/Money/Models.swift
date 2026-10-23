import Foundation

// Модель денег. Все суммы — Int64 в минимальных единицах (копейки, центы)
// валюты проекта: так нет ошибок округления, а SQLite хранит их как INTEGER.

/// Валюта проекта. Конвертации нет: каждый проект живёт в своей валюте,
/// общая сводка показывает каждую валюту отдельно (решение 2026-10-18).
public enum Currency: String, CaseIterable, Sendable {
    case rub = "RUB"
    case usd = "USD"
    case eur = "EUR"

    public var symbol: String {
        switch self {
        case .rub: "₽"
        case .usd: "$"
        case .eur: "€"
        }
    }
}

/// Стартап. Все его траты и доходы — в `currency`.
public struct Project: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Цвет чипа, «#RRGGBB».
    public var colorHex: String
    public var currency: Currency
    public var createdAt: Date
    /// Архивный проект не показывается и не попадает в итоги, но данные остаются.
    public var isArchived: Bool

    public init(
        id: UUID = UUID(), name: String, colorHex: String, currency: Currency,
        createdAt: Date = Date(), isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.currency = currency
        self.createdAt = createdAt
        self.isArchived = isArchived
    }
}

public enum CostPeriod: String, CaseIterable, Sendable {
    case monthly
    case yearly
}

/// Цена регулярной траты, действующая с месяца `effectiveFrom`.
public struct PriceChange: Hashable, Sendable {
    public var effectiveFrom: YearMonth
    public var amount: Int64

    public init(effectiveFrom: YearMonth, amount: Int64) {
        self.effectiveFrom = effectiveFrom
        self.amount = amount
    }
}

/// Регулярная трата: «ввёл один раз — дальше начисляется само».
///
/// История задним числом не переписывается:
/// - новая цена — новая запись в `prices` с месяца, с которого действует;
/// - выключение — `endMonth` (последний оплачиваемый месяц), а не флаг.
/// Расчёты — в `RecurringCost+Accrual.swift`.
public struct RecurringCost: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    /// Где платить (кабинет хостинга). По домену группируется «Куда платить».
    public var url: String?
    public var period: CostPeriod
    public var startMonth: YearMonth
    /// Последний месяц, когда трата действует (включительно); nil — активна.
    /// Для годовой — последний месяц, в котором ещё может быть продление.
    public var endMonth: YearMonth?
    /// По возрастанию `effectiveFrom`; первая цена — со `startMonth`.
    public var prices: [PriceChange]
    public var createdAt: Date
    /// День месяца, когда списывают (1…28); nil — день неизвестен, и алерт
    /// «Пора платить» не приходит (дизайн v2, 2026-10-20).
    public var dueDay: Int?

    public init(
        id: UUID = UUID(), projectId: UUID, name: String, url: String? = nil,
        period: CostPeriod, startMonth: YearMonth, endMonth: YearMonth? = nil,
        prices: [PriceChange], createdAt: Date = Date(), dueDay: Int? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.url = url
        self.period = period
        self.startMonth = startMonth
        self.endMonth = endMonth
        self.prices = prices.sorted { $0.effectiveFrom < $1.effectiveFrom }
        self.createdAt = createdAt
        self.dueDay = dueDay.map { min(max($0, 1), 28) }
    }

    /// Новая трата с одной ценой со стартового месяца.
    public init(
        id: UUID = UUID(), projectId: UUID, name: String, url: String? = nil,
        period: CostPeriod, startMonth: YearMonth, amount: Int64, createdAt: Date = Date(), dueDay: Int? = nil
    ) {
        self.init(
            id: id, projectId: projectId, name: name, url: url, period: period,
            startMonth: startMonth, endMonth: nil,
            prices: [PriceChange(effectiveFrom: startMonth, amount: amount)], createdAt: createdAt, dueDay: dueDay
        )
    }
}

/// Разовая трата (купил шаблон, оплатил рекламу).
public struct OneOffCost: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var url: String?
    public var amount: Int64
    public var date: LocalDate
    public var createdAt: Date

    public init(
        id: UUID = UUID(), projectId: UUID, name: String, url: String? = nil,
        amount: Int64, date: LocalDate, createdAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.url = url
        self.amount = amount
        self.date = date
        self.createdAt = createdAt
    }
}

/// Доход: вносится руками (решение 2026-10-18 — без импорта из платёжек).
public struct Income: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var amount: Int64
    public var date: LocalDate
    public var createdAt: Date

    public init(
        id: UUID = UUID(), projectId: UUID, name: String,
        amount: Int64, date: LocalDate, createdAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.amount = amount
        self.date = date
        self.createdAt = createdAt
    }
}

/// Все деньги целиком. Записей мало (десятки, сотни), поэтому они лежат
/// в памяти, а итоги считаются на лету — без кэшей, которые надо инвалидировать.
public struct Ledger: Hashable, Sendable {
    public var projects: [Project]
    public var recurringCosts: [RecurringCost]
    public var oneOffCosts: [OneOffCost]
    public var incomes: [Income]

    public init(projects: [Project], recurringCosts: [RecurringCost], oneOffCosts: [OneOffCost], incomes: [Income]) {
        self.projects = projects
        self.recurringCosts = recurringCosts
        self.oneOffCosts = oneOffCosts
        self.incomes = incomes
    }

    public static let empty = Ledger(projects: [], recurringCosts: [], oneOffCosts: [], incomes: [])

    public func project(id: UUID) -> Project? { projects.first { $0.id == id } }

    /// Проекты, которые показываются и считаются в итогах.
    public var activeProjects: [Project] { projects.filter { !$0.isArchived } }
}

/// Сумма в конкретной валюте — для сводок, где валют может быть несколько.
public struct CurrencyAmount: Hashable, Sendable {
    public var currency: Currency
    public var amount: Int64

    public init(currency: Currency, amount: Int64) {
        self.currency = currency
        self.amount = amount
    }
}
