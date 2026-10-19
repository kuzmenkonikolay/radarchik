import Foundation
import Observation
import RadarchikCore

/// Деньги для интерфейса. Держит `Ledger` в памяти, каждое изменение сразу
/// пишет в SQLite и отдаёт готовые отчёты на текущий месяц.
///
/// Отчёты — вычисляемые свойства без кэша: данных мало, а SwiftUI сам
/// перерисует экран, когда поменяется `ledger` или `month`.
@MainActor
@Observable
final class MoneyStore {
    private(set) var ledger: Ledger
    /// Текущий месяц по часам компьютера. Антенка и чипы смотрят на прошлый,
    /// закрытый месяц (`closedMonth`), а текущий показывается как «пока» (SPEC §8).
    private(set) var month: YearMonth
    /// Ошибка записи в базу — показывается баннером, пока её не закроют.
    var lastError: String?
    /// Короткое событие для Радарчика (поймал монетку), сбрасывается само.
    private(set) var mascotEvent: MascotEvent?

    private let repository: LedgerRepository
    @ObservationIgnored private var eventResetTask: Task<Void, Never>?

    init(repository: LedgerRepository, now: Date = Date()) throws {
        self.repository = repository
        self.ledger = try repository.loadLedger()
        self.month = YearMonth(now)
    }

    /// Настоящая база в ~/Library/Application Support/Radarchik/.
    static func live() throws -> MoneyStore {
        let url = try LedgerRepository.defaultDatabaseURL()
        return try MoneyStore(repository: LedgerRepository(database: Database(path: url.path)))
    }

    /// Вызывается при наведении, смене дня и пробуждении мака.
    func refreshMonth(now: Date = Date()) {
        let current = YearMonth(now)
        if current != month { month = current }
    }

    // MARK: - Сводка

    /// Последний закрытый месяц: по нему горит антенка и считаются чипы.
    var closedMonth: YearMonth { month.previous }
    /// Неархивные проекты в порядке создания.
    var projects: [Project] { glances.map(\.project) }
    /// Чипы проектов: итог и настроение закрытого месяца (у нового — текущий «пока»).
    var glances: [ProjectGlance] { MoneyEngine.glances(currentMonth: month, ledger: ledger) }
    var closedSummaries: [CurrencySummary] { MoneyEngine.closedSummaries(currentMonth: month, ledger: ledger) }
    /// Общее настроение закрытого месяца; nil — закрытых месяцев ещё нет (антенка тусклая).
    var overallMood: Mood? { MoneyEngine.overallMood(closedSummaries) }
    /// Итог текущего месяца «пока» по всем проектам — левое крыло чёлки.
    /// В начале месяца в минусе: траты начислены, доходы ещё не пришли.
    var monthTotals: [CurrencyAmount] { MoneyEngine.monthTotals(month: month, ledger: ledger) }
    /// Все проекты за полгода, по графику на валюту — на сводке.
    var overallHistory: [CurrencyHistory] { MoneyEngine.overallHistory(endingAt: month, count: 6, ledger: ledger) }
    /// Платить надо сейчас, поэтому «Куда платить» — за текущий месяц.
    var payments: [PaymentGroup] { Payments.groups(month: month, ledger: ledger) }
    var dueTotals: [CurrencyAmount] { Payments.totals(of: payments) }
    /// Фраза Радарчика при наведении (о закрытом месяце и платежах).
    var phrase: String { SummaryPhrase.make(month: month, ledger: ledger) }

    // MARK: - Отчёты для экрана проекта

    func report(for project: Project, month: YearMonth) -> ProjectReport {
        MoneyEngine.report(for: project, month: month, ledger: ledger)
    }

    /// Последние 6 месяцев для графика.
    func history(for projectId: UUID, endingAt month: YearMonth) -> [MonthPoint] {
        MoneyEngine.history(projectId: projectId, endingAt: month, count: 6, ledger: ledger)
    }

    /// Регулярные траты проекта: сначала действующие в месяце, потом выключенные.
    func recurringCosts(for projectId: UUID, in month: YearMonth) -> [RecurringCost] {
        ledger.recurringCosts
            .filter { $0.projectId == projectId }
            .sorted { lhs, rhs in
                let l = lhs.isActive(asOf: month), r = rhs.isActive(asOf: month)
                if l != r { return l }
                return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
    }

    func oneOffCosts(for projectId: UUID, in month: YearMonth) -> [OneOffCost] {
        ledger.oneOffCosts.filter { $0.projectId == projectId && $0.date.yearMonth == month }
    }

    func incomes(for projectId: UUID, in month: YearMonth) -> [Income] {
        ledger.incomes.filter { $0.projectId == projectId && $0.date.yearMonth == month }
    }

    /// Следующий свободный цвет из палитры — для нового проекта.
    func suggestedProjectColor() -> String {
        let used = Set(ledger.projects.map(\.colorHex))
        return DS.projectColors.first { !used.contains($0) } ?? DS.projectColors[ledger.projects.count % DS.projectColors.count]
    }

    // MARK: - Изменения (true — сохранено)

    @discardableResult
    func save(_ project: Project) -> Bool {
        perform({ try repository.save(project) }) { Self.upsert(project, into: &$0.projects) }
    }

    @discardableResult
    func deleteProject(_ id: UUID) -> Bool {
        perform({ try repository.deleteProject(id: id) }) { ledger in
            ledger.projects.removeAll { $0.id == id }
            ledger.recurringCosts.removeAll { $0.projectId == id }
            ledger.oneOffCosts.removeAll { $0.projectId == id }
            ledger.incomes.removeAll { $0.projectId == id }
        }
    }

    @discardableResult
    func save(_ cost: RecurringCost) -> Bool {
        perform({ try repository.save(cost) }) { Self.upsert(cost, into: &$0.recurringCosts) }
    }

    @discardableResult
    func deleteRecurringCost(_ id: UUID) -> Bool {
        perform({ try repository.deleteRecurringCost(id: id) }) { $0.recurringCosts.removeAll { $0.id == id } }
    }

    @discardableResult
    func save(_ cost: OneOffCost) -> Bool {
        perform({ try repository.save(cost) }) { Self.upsert(cost, into: &$0.oneOffCosts) }
    }

    @discardableResult
    func deleteOneOffCost(_ id: UUID) -> Bool {
        perform({ try repository.deleteOneOffCost(id: id) }) { $0.oneOffCosts.removeAll { $0.id == id } }
    }

    @discardableResult
    func save(_ income: Income) -> Bool {
        let isNew = !ledger.incomes.contains { $0.id == income.id }
        let saved = perform({ try repository.save(income) }) { Self.upsert(income, into: &$0.incomes) }
        if saved && isNew { emit(.incomeAdded) }
        return saved
    }

    @discardableResult
    func deleteIncome(_ id: UUID) -> Bool {
        perform({ try repository.deleteIncome(id: id) }) { $0.incomes.removeAll { $0.id == id } }
    }

    // MARK: - Внутреннее

    /// Сначала база, потом память: если запись не прошла, экран не врёт.
    private func perform(_ write: () throws -> Void, apply: (inout Ledger) -> Void) -> Bool {
        do {
            try write()
            apply(&ledger)
            lastError = nil
            return true
        } catch {
            lastError = L("Не получилось сохранить: ", "Couldn’t save: ") + "\(error)"
            return false
        }
    }

    private static func upsert<T: Identifiable>(_ item: T, into items: inout [T]) where T.ID == UUID {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// Событие живёт 2,5 секунды — столько длится «поймал монетку».
    private func emit(_ event: MascotEvent) {
        eventResetTask?.cancel()
        mascotEvent = event
        eventResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.mascotEvent = nil
        }
    }
}
