import Foundation

/// Деньги проекта (или валюты) за один месяц.
public struct MonthFigures: Hashable, Sendable {
    public var income: Int64 = 0
    /// Регулярные траты (годовые — по 1/12).
    public var recurring: Int64 = 0
    public var oneOff: Int64 = 0

    public init(income: Int64 = 0, recurring: Int64 = 0, oneOff: Int64 = 0) {
        self.income = income
        self.recurring = recurring
        self.oneOff = oneOff
    }

    public var cost: Int64 { recurring + oneOff }
    public var net: Int64 { income - cost }

    public static let zero = MonthFigures()

    public static func + (lhs: MonthFigures, rhs: MonthFigures) -> MonthFigures {
        MonthFigures(income: lhs.income + rhs.income, recurring: lhs.recurring + rhs.recurring, oneOff: lhs.oneOff + rhs.oneOff)
    }
}

/// Точка графика: итог одного месяца.
public struct MonthPoint: Identifiable, Hashable, Sendable {
    public let month: YearMonth
    public let figures: MonthFigures
    public var id: YearMonth { month }
}

/// Отчёт по проекту за месяц: всё для чипа и экрана проекта.
public struct ProjectReport: Identifiable, Hashable, Sendable {
    public let project: Project
    public let month: YearMonth
    public let current: MonthFigures
    public let previous: MonthFigures
    /// nil, если прошлый итог был ровно 0 и процент не определён.
    public let growthPercent: Double?
    public let mood: Mood
    /// Итог за всё время по `month` включительно.
    public let allTimeNet: Int64
    public var id: UUID { project.id }
}

/// Как проект выглядит на сводке (чип). Показываются итог и настроение
/// последнего закрытого месяца. У нового проекта закрытого месяца ещё нет,
/// поэтому у него итог текущего месяца «пока» и настроения нет.
public struct ProjectGlance: Identifiable, Hashable, Sendable {
    public let project: Project
    /// Месяц, за который показан итог.
    public let month: YearMonth
    public let net: Int64
    /// nil — первый месяц ещё идёт.
    public let mood: Mood?
    public var isFirstMonth: Bool { mood == nil }
    public var id: UUID { project.id }
}

/// Сводка по одной валюте: сумма всех её проектов. По ней горит антенка.
public struct CurrencySummary: Identifiable, Hashable, Sendable {
    public let currency: Currency
    public let current: MonthFigures
    public let previous: MonthFigures
    public let growthPercent: Double?
    public let mood: Mood
    public var id: Currency { currency }
}

/// Все проекты одной валюты по месяцам — график «Все проекты» на сводке.
public struct CurrencyHistory: Identifiable, Hashable, Sendable {
    public let currency: Currency
    /// Старые месяцы первыми, последний — текущий.
    public let points: [MonthPoint]
    public var id: Currency { currency }
}

/// Все расчёты денег. Чистые функции от `Ledger` — их легко тестировать,
/// а данных так мало, что считать каждый раз заново дешевле, чем кэшировать.
public enum MoneyEngine {
    // MARK: - Месяц

    public static func figures(projectId: UUID, month: YearMonth, ledger: Ledger) -> MonthFigures {
        figures(projectIds: [projectId], month: month, ledger: ledger)
    }

    /// Сумма по нескольким проектам — для сводок по валюте.
    static func figures(projectIds: Set<UUID>, month: YearMonth, ledger: Ledger) -> MonthFigures {
        var result = MonthFigures()
        for income in ledger.incomes where projectIds.contains(income.projectId) && income.date.yearMonth == month {
            result.income += income.amount
        }
        for cost in ledger.oneOffCosts where projectIds.contains(cost.projectId) && cost.date.yearMonth == month {
            result.oneOff += cost.amount
        }
        for cost in ledger.recurringCosts where projectIds.contains(cost.projectId) {
            result.recurring += cost.accrual(in: month)
        }
        return result
    }

    // MARK: - Рост и настроение

    /// Рост итога в процентах относительно |прошлого итога|. Делим на модуль,
    /// иначе выход из минуса в плюс (−10к → +5к) выглядел бы как падение.
    public static func growthPercent(current: Int64, previous: Int64) -> Double? {
        guard previous != 0 else { return nil }
        return Double(current - previous) * 100 / Double(previous.magnitude)
    }

    /// Правило настроения из ТЗ. Пороги ±5% сравниваются в целых числах,
    /// без Double, чтобы ровно 5% не превратились в 4,9999%.
    public static func mood(net: Int64, previousNet: Int64, lossStreak: Int) -> Mood {
        if net < 0 { return .losing(streak: max(lossStreak, 1)) }
        if net == 0 { return .stable }
        guard previousNet != 0 else { return .growing }
        // рост ≥ 5%  ⇔  (net − prev) × 100 ≥ 5 × |prev|  ⇔  (net − prev) × 20 ≥ |prev|
        let scaledDelta = (net - previousNet) * 20
        let base = Int64(previousNet.magnitude)
        if scaledDelta >= base { return .growing }
        if scaledDelta >= -base { return .stable }
        return .declining
    }

    // MARK: - Проекты

    public static func report(for project: Project, month: YearMonth, ledger: Ledger) -> ProjectReport {
        let ids: Set<UUID> = [project.id]
        let current = figures(projectIds: ids, month: month, ledger: ledger)
        let previous = figures(projectIds: ids, month: month.previous, ledger: ledger)
        return ProjectReport(
            project: project,
            month: month,
            current: current,
            previous: previous,
            growthPercent: growthPercent(current: current.net, previous: previous.net),
            mood: mood(projectIds: ids, month: month, current: current, previous: previous, ledger: ledger),
            allTimeNet: allTimeNet(projectId: project.id, through: month, ledger: ledger)
        )
    }

    /// Отчёты по всем неархивным проектам, в порядке создания
    /// (при равной дате — в порядке хранения).
    public static func reports(month: YearMonth, ledger: Ledger) -> [ProjectReport] {
        ledger.activeProjects
            .enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map { report(for: $0.element, month: month, ledger: ledger) }
    }

    /// Итог за всё время по `month` включительно.
    public static func allTimeNet(projectId: UUID, through month: YearMonth, ledger: Ledger) -> Int64 {
        guard let first = firstMonth(projectIds: [projectId], ledger: ledger), first <= month else { return 0 }
        return YearMonth.range(from: first, through: month)
            .reduce(0) { $0 + figures(projectIds: [projectId], month: $1, ledger: ledger).net }
    }

    /// Последние `count` месяцев до `month` включительно, старые первыми (для графика).
    public static func history(projectId: UUID, endingAt month: YearMonth, count: Int, ledger: Ledger) -> [MonthPoint] {
        points(projectIds: [projectId], endingAt: month, count: count, ledger: ledger)
    }

    // MARK: - Валюты

    /// Сводки по каждой валюте, где есть неархивные проекты (порядок: ₽, $, €).
    public static func currencySummaries(month: YearMonth, ledger: Ledger) -> [CurrencySummary] {
        Currency.allCases.compactMap { currency in
            let ids = Set(ledger.activeProjects.filter { $0.currency == currency }.map(\.id))
            guard !ids.isEmpty else { return nil }
            let current = figures(projectIds: ids, month: month, ledger: ledger)
            let previous = figures(projectIds: ids, month: month.previous, ledger: ledger)
            return CurrencySummary(
                currency: currency,
                current: current,
                previous: previous,
                growthPercent: growthPercent(current: current.net, previous: previous.net),
                mood: mood(projectIds: ids, month: month, current: current, previous: previous, ledger: ledger)
            )
        }
    }

    /// Общее настроение — худшее из валют; nil, если проектов нет.
    public static func overallMood(_ summaries: [CurrencySummary]) -> Mood? {
        Mood.worst(summaries.map(\.mood))
    }

    /// Настроение для антенки и лица: по последнему закрытому месяцу, а пока
    /// ни один не закрыт — по текущему «пока» (решение 2026-10-19). Иначе весь
    /// первый месяц Радарчик сидел бы с серыми глазами. Правила те же:
    /// прошлого месяца нет, поэтому плюс с нуля — рост, минус — «в минусе»,
    /// траты без доходов — «доходов пока нет».
    public static func overallMood(currentMonth: YearMonth, ledger: Ledger) -> Mood? {
        let closed = closedSummaries(currentMonth: currentMonth, ledger: ledger)
        if !closed.isEmpty { return overallMood(closed) }
        return overallMood(currencySummaries(month: currentMonth, ledger: ledger).filter { $0.current != .zero })
    }

    /// Вырос ли итог месяца хоть в одной валюте: Радарчик тогда на миг радуется.
    /// Валюты, которой раньше не было, считаются с нуля.
    public static func netGrew(from before: [CurrencyAmount], to after: [CurrencyAmount]) -> Bool {
        after.contains { item in
            item.amount > (before.first { $0.currency == item.currency }?.amount ?? 0)
        }
    }

    // MARK: - Все проекты

    /// Итог месяца «пока» по всем проектам, по валютам: доходы минус траты.
    /// Регулярные траты начислены с 1-го числа, поэтому в начале месяца здесь
    /// минус, и он растёт по мере доходов (крыло чёлки, решение 2026-10-19).
    /// Валюты, где в этом месяце ничего нет, пропускаются; «в ноль» — показывается.
    public static func monthTotals(month: YearMonth, ledger: Ledger) -> [CurrencyAmount] {
        currencySummaries(month: month, ledger: ledger)
            .filter { $0.current != .zero }
            .map { CurrencyAmount(currency: $0.currency, amount: $0.current.net) }
    }

    /// Последние `count` месяцев до `month` включительно по всем неархивным проектам —
    /// по графику на валюту, без конвертации. Валюты без единой записи к `month`
    /// пропускаются. Месяцы до первых записей — нулевые: столбиков всегда `count`.
    public static func overallHistory(endingAt month: YearMonth, count: Int, ledger: Ledger) -> [CurrencyHistory] {
        Currency.allCases.compactMap { currency in
            let ids = Set(ledger.activeProjects.filter { $0.currency == currency }.map(\.id))
            guard hasData(projectIds: ids, through: month, ledger: ledger) else { return nil }
            return CurrencyHistory(currency: currency, points: points(projectIds: ids, endingAt: month, count: count, ledger: ledger))
        }
    }

    // MARK: - Последний закрытый месяц
    //
    // Антенка, чипы и фраза смотрят на прошлый, уже закрытый месяц (решение
    // 2026-10-18). В текущем регулярные траты начислены с 1-го числа, а доходы
    // ещё не пришли, и первые дни каждого месяца всё горело бы оранжевым.
    // Текущий месяц показывается отдельно, как «пока».

    /// Сводки по валютам за последний закрытый месяц. Валюты, у которых
    /// к тому месяцу не было ни одной записи, пропускаются: про них ещё нечего сказать.
    public static func closedSummaries(currentMonth: YearMonth, ledger: Ledger) -> [CurrencySummary] {
        let closed = currentMonth.previous
        return currencySummaries(month: closed, ledger: ledger).filter { summary in
            let ids = Set(ledger.activeProjects.filter { $0.currency == summary.currency }.map(\.id))
            return hasData(projectIds: ids, through: closed, ledger: ledger)
        }
    }

    /// Чипы сводки: закрытый месяц, а у нового проекта — текущий «пока».
    public static func glances(currentMonth: YearMonth, ledger: Ledger) -> [ProjectGlance] {
        let closed = currentMonth.previous
        return reports(month: closed, ledger: ledger).map { report in
            if hasData(projectIds: [report.project.id], through: closed, ledger: ledger) {
                return ProjectGlance(project: report.project, month: closed, net: report.current.net, mood: report.mood)
            }
            let current = figures(projectIds: [report.project.id], month: currentMonth, ledger: ledger)
            return ProjectGlance(project: report.project, month: currentMonth, net: current.net, mood: nil)
        }
    }

    /// Есть ли у проектов хоть одна запись не позже `month`.
    public static func hasData(projectIds: Set<UUID>, through month: YearMonth, ledger: Ledger) -> Bool {
        guard let first = firstMonth(projectIds: projectIds, ledger: ledger) else { return false }
        return first <= month
    }

    // MARK: - Внутреннее

    /// Месяцы для графика: старые первыми, последний — `month`.
    private static func points(projectIds: Set<UUID>, endingAt month: YearMonth, count: Int, ledger: Ledger) -> [MonthPoint] {
        YearMonth.range(from: month.adding(months: -(count - 1)), through: month).map {
            MonthPoint(month: $0, figures: figures(projectIds: projectIds, month: $0, ledger: ledger))
        }
    }

    /// Настроение группы проектов: «спит», если доходов ещё не было,
    /// иначе — правило из ТЗ с подсчётом месяцев подряд в минусе.
    private static func mood(
        projectIds: Set<UUID>, month: YearMonth,
        current: MonthFigures, previous: MonthFigures, ledger: Ledger
    ) -> Mood {
        guard let firstIncome = firstIncomeMonth(projectIds: projectIds, through: month, ledger: ledger) else {
            return .sleeping
        }
        var streak = 0
        if current.net < 0 {
            // Считаем назад, пока итог в минусе. До первого дохода проект «спал» —
            // эти месяцы убытком не считаются.
            var cursor = month
            while cursor >= firstIncome, figures(projectIds: projectIds, month: cursor, ledger: ledger).net < 0 {
                streak += 1
                cursor = cursor.previous
            }
        }
        return mood(net: current.net, previousNet: previous.net, lossStreak: streak)
    }

    private static func firstIncomeMonth(projectIds: Set<UUID>, through month: YearMonth, ledger: Ledger) -> YearMonth? {
        ledger.incomes
            .filter { projectIds.contains($0.projectId) && $0.date.yearMonth <= month }
            .map(\.date.yearMonth)
            .min()
    }

    /// Самый ранний месяц, где у проектов есть хоть какие-то деньги.
    private static func firstMonth(projectIds: Set<UUID>, ledger: Ledger) -> YearMonth? {
        let months = ledger.incomes.filter { projectIds.contains($0.projectId) }.map(\.date.yearMonth)
            + ledger.oneOffCosts.filter { projectIds.contains($0.projectId) }.map(\.date.yearMonth)
            + ledger.recurringCosts.filter { projectIds.contains($0.projectId) }.map(\.startMonth)
        return months.min()
    }
}
