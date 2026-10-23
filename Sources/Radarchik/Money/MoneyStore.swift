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
    /// Только что добавленный доход — по нему раскрывается алерт «Пришли деньги» (D).
    private(set) var news: IncomeNews?

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
    /// Общее настроение для антенки и лица: по закрытому месяцу, а пока ни один
    /// не закрыт — по текущему «пока» (2026-10-19); nil — данных нет вовсе.
    var overallMood: Mood? { MoneyEngine.overallMood(currentMonth: month, ledger: ledger) }
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
    /// Фраза под крупной цифрой на главной: кто проседает и когда итог.
    var homePhrase: String { SummaryPhrase.home(month: month, ledger: ledger) }

    /// Итог текущего месяца «пока» по одному проекту — цифра в его пилюле.
    func monthNet(of projectId: UUID) -> Int64 {
        MoneyEngine.figures(projectId: projectId, month: month, ledger: ledger).net
    }

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
        let currency = ledger.project(id: income.projectId)?.currency
        let before = monthTotals.first { $0.currency == currency }?.amount ?? 0
        let saved = perform(addsIncome: isNew, { try repository.save(income) }) { Self.upsert(income, into: &$0.incomes) }
        // Новый доход этого месяца — алерт «Пришли деньги» с новым итогом месяца.
        if saved, isNew, let currency, let project = ledger.project(id: income.projectId), income.date.yearMonth == month {
            news = IncomeNews(
                id: income.id, amount: income.amount, currency: currency, projectName: project.name, title: income.name,
                before: before, after: monthTotals.first { $0.currency == currency }?.amount ?? income.amount, month: month
            )
        }
        return saved
    }

    @discardableResult
    func deleteIncome(_ id: UUID) -> Bool {
        perform({ try repository.deleteIncome(id: id) }) { $0.incomes.removeAll { $0.id == id } }
    }

    // MARK: - Внутреннее

    /// Сначала база, потом память: если запись не прошла, экран не врёт.
    /// Потом Радарчик реагирует по очереди: новый доход — ловит монетку,
    /// итог месяца вырос (доход, убрал или удешевил трату) — щурится от радости.
    private func perform(addsIncome: Bool = false, _ write: () throws -> Void, apply: (inout Ledger) -> Void) -> Bool {
        let before = monthTotals
        do {
            try write()
            apply(&ledger)
            lastError = nil
        } catch {
            lastError = L("Не получилось сохранить: ", "Couldn’t save: ") + "\(error)"
            return false
        }
        var events: [MascotEvent] = []
        if addsIncome { events.append(.incomeAdded) }
        if MoneyEngine.netGrew(from: before, to: monthTotals) { events.append(.netGrew) }
        play(events)
        return true
    }

    private static func upsert<T: Identifiable>(_ item: T, into items: inout [T]) where T.ID == UUID {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// События по очереди, первое — сразу. Новое сохранение перебивает старую очередь.
    private func play(_ events: [MascotEvent]) {
        guard let first = events.first else { return }
        eventResetTask?.cancel()
        mascotEvent = first
        eventResetTask = Task { [weak self] in
            for (index, event) in events.enumerated() {
                if index > 0 { self?.mascotEvent = event }
                try? await Task.sleep(for: Self.duration(of: event))
                guard !Task.isCancelled else { return }
            }
            self?.mascotEvent = nil
        }
    }

    /// «Поймал монетку» — 2,5 секунды, радость — на миг.
    private static func duration(of event: MascotEvent) -> Duration {
        switch event {
        case .incomeAdded: .seconds(2.5)
        case .netGrew: .seconds(1.6)
        }
    }
}
