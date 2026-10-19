import Testing
@testable import RadarchikCore

@Suite("Итоги, рост и настроение")
struct MoneyEngineTests {
    @Test func monthFiguresCombineRecurringOneOffAndIncome() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [Fixture.monthly(p, "Сервер", 1500, from: "2026-01")],
            oneOffCosts: [Fixture.oneOff(p, 300, on: "2026-10-05")],
            incomes: [Fixture.income(p, 5000, on: "2026-10-10"), Fixture.income(p, 1000, on: "2026-09-30")]
        )
        let figures = MoneyEngine.figures(projectId: p.id, month: ym("2026-10"), ledger: ledger)
        #expect(figures.income == units(5000))
        #expect(figures.recurring == units(1500))
        #expect(figures.oneOff == units(300))
        #expect(figures.cost == units(1800))
        #expect(figures.net == units(3200))
    }

    @Test func growthIsMeasuredAgainstAbsolutePreviousNet() {
        #expect(MoneyEngine.growthPercent(current: 110, previous: 100) == 10)
        #expect(MoneyEngine.growthPercent(current: 90, previous: 100) == -10)
        #expect(MoneyEngine.growthPercent(current: 5_000, previous: -10_000) == 150)
        #expect(MoneyEngine.growthPercent(current: -15_000, previous: -10_000) == -50)
        #expect(MoneyEngine.growthPercent(current: 50, previous: 0) == nil)
    }

    @Test func moodFollowsTableFromSpec() {
        #expect(MoneyEngine.mood(net: 105, previousNet: 100, lossStreak: 0) == .growing)      // ровно +5% — уже рост
        #expect(MoneyEngine.mood(net: 104, previousNet: 100, lossStreak: 0) == .stable)
        #expect(MoneyEngine.mood(net: 95, previousNet: 100, lossStreak: 0) == .stable)       // ровно −5% — ещё ровно
        #expect(MoneyEngine.mood(net: 94, previousNet: 100, lossStreak: 0) == .declining)
        #expect(MoneyEngine.mood(net: 5_000, previousNet: -10_000, lossStreak: 0) == .growing) // из минуса в плюс
        #expect(MoneyEngine.mood(net: 50, previousNet: 0, lossStreak: 0) == .growing)
        #expect(MoneyEngine.mood(net: 0, previousNet: 100, lossStreak: 0) == .stable)        // вышли в ноль
        #expect(MoneyEngine.mood(net: -1, previousNet: 100, lossStreak: 1) == .losing(streak: 1))
    }

    @Test func projectWithoutIncomeSleeps() {
        let p = Fixture.project()
        let ledger = Ledger(projects: [p], recurringCosts: [Fixture.monthly(p, "Сервер", 1500, from: "2026-01")], oneOffCosts: [], incomes: [])
        #expect(MoneyEngine.report(for: p, month: ym("2026-10"), ledger: ledger).mood == .sleeping)
    }

    @Test func lossStreakCountsOnlySinceFirstIncome() {
        // Январь–май проект «спал» (одни траты), в июне первый доход,
        // июль–октябрь снова одни траты → четвёртый месяц в минусе.
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [Fixture.monthly(p, "Сервер", 1000, from: "2026-01")],
            oneOffCosts: [],
            incomes: [Fixture.income(p, 5000, on: "2026-06-10")]
        )
        #expect(MoneyEngine.report(for: p, month: ym("2026-10"), ledger: ledger).mood == .losing(streak: 4))
    }

    @Test func reportHasGrowthAndAllTimeNet() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [Fixture.monthly(p, "Сервер", 1000, from: "2026-08")],
            oneOffCosts: [Fixture.oneOff(p, 200, on: "2026-09-15")],
            incomes: [
                Fixture.income(p, 1500, on: "2026-08-20"),
                Fixture.income(p, 3000, on: "2026-09-20"),
                Fixture.income(p, 4000, on: "2026-10-01"),
            ]
        )
        let report = MoneyEngine.report(for: p, month: ym("2026-10"), ledger: ledger)
        #expect(report.current.net == units(3000))
        #expect(report.previous.net == units(1800))
        #expect(report.growthPercent == Double(1200 * 100) / 1800)
        #expect(report.mood == .growing)
        // 8500 доходов − 3 месяца сервера по 1000 − разовая 200
        #expect(report.allTimeNet == units(5300))
    }

    @Test func summariesAreSplitByCurrencyWithoutConversion() {
        let rub = Fixture.project("Курсы", currency: .rub)
        let usd = Fixture.project("Бот", currency: .usd)
        let ledger = Ledger(
            projects: [usd, rub],
            recurringCosts: [Fixture.monthly(rub, "Selectel", 2000, from: "2026-01"), Fixture.monthly(usd, "Vercel", 300, from: "2026-01")],
            oneOffCosts: [],
            incomes: [Fixture.income(rub, 10_000, on: "2026-10-05"), Fixture.income(usd, 100, on: "2026-10-05")]
        )
        let summaries = MoneyEngine.currencySummaries(month: ym("2026-10"), ledger: ledger)
        #expect(summaries.map(\.currency) == [.rub, .usd])
        #expect(summaries[0].current.net == units(8000))
        #expect(summaries[0].mood == .growing)
        #expect(summaries[1].current.net == units(-200))
        // У долларового проекта первый доход в октябре, до этого он спал.
        #expect(summaries[1].mood == .losing(streak: 1))
        #expect(MoneyEngine.overallMood(summaries) == .losing(streak: 1))
    }

    @Test func currencyWithoutAnyIncomeSleeps() {
        let p = Fixture.project("Новый", currency: .eur)
        let ledger = Ledger(projects: [p], recurringCosts: [Fixture.monthly(p, "Сервер", 10, from: "2026-01")], oneOffCosts: [], incomes: [])
        #expect(MoneyEngine.currencySummaries(month: ym("2026-10"), ledger: ledger).first?.mood == .sleeping)
    }

    @Test func archivedProjectsAreLeftOut() {
        let live = Fixture.project("Курсы")
        let dead = Fixture.project("Старый", archived: true)
        let ledger = Ledger(
            projects: [live, dead],
            recurringCosts: [Fixture.monthly(dead, "Сервер", 999, from: "2026-01")],
            oneOffCosts: [],
            incomes: [Fixture.income(live, 100, on: "2026-10-01")]
        )
        let summaries = MoneyEngine.currencySummaries(month: ym("2026-10"), ledger: ledger)
        #expect(summaries.count == 1)
        #expect(summaries[0].current.net == units(100))
        #expect(MoneyEngine.reports(month: ym("2026-10"), ledger: ledger).map(\.project.name) == ["Курсы"])
    }

    @Test func overallMoodIsNilWithoutProjects() {
        #expect(MoneyEngine.overallMood(MoneyEngine.currencySummaries(month: ym("2026-10"), ledger: .empty)) == nil)
    }

    @Test func historyReturnsLastMonthsOldestFirst() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p], recurringCosts: [], oneOffCosts: [],
            incomes: [Fixture.income(p, 100, on: "2026-10-01"), Fixture.income(p, 50, on: "2026-08-01")]
        )
        let history = MoneyEngine.history(projectId: p.id, endingAt: ym("2026-10"), count: 3, ledger: ledger)
        #expect(history.map(\.month) == [ym("2026-08"), ym("2026-09"), ym("2026-10")])
        #expect(history.map(\.figures.net) == [units(50), 0, units(100)])
    }

    // MARK: - Все проекты: текущий месяц «пока» (крыло чёлки) и график по месяцам

    @Test func monthTotalsStartNegativeAndGrowWithIncome() {
        let a = Fixture.project("Магазин")
        let b = Fixture.project("Блог")
        var ledger = Ledger(
            projects: [a, b],
            recurringCosts: [
                Fixture.monthly(a, "Сервер", 9_000, from: "2026-10"),
                // Годовая — по 1/12 в месяц: 100.
                Fixture.yearly(b, "Домен", 1_200, from: "2026-10"),
            ],
            oneOffCosts: [],
            incomes: []
        )
        // Начало ноября: траты начислены с 1-го, доходов ещё нет — минус.
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [CurrencyAmount(currency: .rub, amount: units(-9_100))])

        // Пришли доходы — итог растёт, с обоих проектов вместе.
        ledger.incomes = [Fixture.income(a, 12_000, on: "2026-11-05"), Fixture.income(b, 1_000, on: "2026-11-07")]
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [CurrencyAmount(currency: .rub, amount: units(3_900))])
    }

    @Test func monthTotalsAreSplitByCurrencyAndSkipEmptyOnes() {
        let rub = Fixture.project("Курсы", currency: .rub)
        let usd = Fixture.project("Бот", currency: .usd)
        let eur = Fixture.project("Тихий", currency: .eur)
        let archived = Fixture.project("Старый", archived: true)
        let ledger = Ledger(
            projects: [usd, eur, rub, archived],
            recurringCosts: [Fixture.monthly(usd, "Vercel", 300, from: "2026-01"), Fixture.monthly(archived, "Сервер", 999, from: "2026-01")],
            oneOffCosts: [],
            // У евро-проекта в ноябре ничего нет, был только октябрь.
            incomes: [Fixture.income(rub, 500, on: "2026-11-02"), Fixture.income(eur, 50, on: "2026-10-02")]
        )
        // Порядок всегда ₽, $, €; архивный проект не считается.
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [
            CurrencyAmount(currency: .rub, amount: units(500)),
            CurrencyAmount(currency: .usd, amount: units(-300)),
        ])
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: .empty).isEmpty)
    }

    @Test func monthTotalsShowZeroWhenIncomeCoversCosts() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p], recurringCosts: [Fixture.monthly(p, "Сервер", 700, from: "2026-11")], oneOffCosts: [],
            incomes: [Fixture.income(p, 700, on: "2026-11-03")]
        )
        // В ноль — это тоже итог, его показываем (пропускаем только пустой месяц).
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [CurrencyAmount(currency: .rub, amount: 0)])
    }

    @Test func overallHistorySumsProjectsOfEachCurrencyByMonth() {
        let a = Fixture.project("Магазин")
        let b = Fixture.project("Подкаст")
        let usd = Fixture.project("Бот", currency: .usd)
        let ledger = Ledger(
            projects: [a, b, usd],
            recurringCosts: [Fixture.monthly(b, "Сервер", 1_000, from: "2026-09")],
            oneOffCosts: [Fixture.oneOff(a, 200, on: "2026-10-03")],
            incomes: [
                Fixture.income(a, 5_000, on: "2026-09-10"),
                Fixture.income(b, 3_000, on: "2026-11-01"),
                Fixture.income(usd, 100, on: "2026-11-02"),
            ]
        )
        let history = MoneyEngine.overallHistory(endingAt: ym("2026-11"), count: 3, ledger: ledger)
        // Без конвертации: у каждой валюты свой график.
        #expect(history.map(\.currency) == [.rub, .usd])
        #expect(history[0].points.map(\.month) == [ym("2026-09"), ym("2026-10"), ym("2026-11")])
        // Сентябрь 5000 − 1000, октябрь −1000 − 200, ноябрь 3000 − 1000.
        #expect(history[0].points.map(\.figures.net) == [units(4_000), units(-1_200), units(2_000)])
        // Месяцы до первых записей — нулевые, но на месте: у графика всегда `count` столбиков.
        #expect(history[1].points.map(\.figures.net) == [0, 0, units(100)])
    }

    @Test func overallHistorySkipsCurrenciesWithoutRecordsYet() {
        let rub = Fixture.project("Курсы")
        // Проект заведён, но записей нет; у второго запись только в будущем месяце.
        let usd = Fixture.project("Новый", currency: .usd)
        let eur = Fixture.project("Потом", currency: .eur)
        let ledger = Ledger(
            projects: [rub, usd, eur],
            recurringCosts: [],
            oneOffCosts: [],
            incomes: [Fixture.income(rub, 100, on: "2026-11-01"), Fixture.income(eur, 10, on: "2026-12-01")]
        )
        #expect(MoneyEngine.overallHistory(endingAt: ym("2026-11"), count: 6, ledger: ledger).map(\.currency) == [.rub])
        #expect(MoneyEngine.overallHistory(endingAt: ym("2026-11"), count: 6, ledger: .empty).isEmpty)
    }

    // MARK: - Последний закрытый месяц (по нему горит антенка)

    @Test func closedSummariesLookAtPreviousMonthAndSkipCurrenciesWithoutHistory() {
        let rub = Fixture.project("Курсы", currency: .rub)
        let usd = Fixture.project("Новый", currency: .usd)
        let ledger = Ledger(
            projects: [rub, usd],
            recurringCosts: [Fixture.monthly(rub, "Сервер", 1_000, from: "2026-09")],
            oneOffCosts: [],
            incomes: [
                Fixture.income(rub, 3_000, on: "2026-10-05"),
                // Ноябрь — текущий месяц: доход ещё не влияет на антенку.
                Fixture.income(rub, 50_000, on: "2026-11-02"),
                // У долларового проекта записи только в текущем месяце.
                Fixture.income(usd, 10, on: "2026-11-02"),
            ]
        )
        let summaries = MoneyEngine.closedSummaries(currentMonth: ym("2026-11"), ledger: ledger)
        #expect(summaries.map(\.currency) == [.rub])
        #expect(summaries[0].current.net == units(2_000))
        #expect(MoneyEngine.overallMood(summaries) == .growing)   // сентябрь −1000 → октябрь +2000
    }

    @Test func overallMoodIsNilBeforeFirstClosedMonth() {
        let p = Fixture.project()
        let ledger = Ledger(projects: [p], recurringCosts: [], oneOffCosts: [], incomes: [Fixture.income(p, 100, on: "2026-11-01")])
        #expect(MoneyEngine.overallMood(MoneyEngine.closedSummaries(currentMonth: ym("2026-11"), ledger: ledger)) == nil)
    }

    @Test func glanceShowsClosedMonthOrCurrentForNewProject() {
        let old = Fixture.project("Курсы")
        let new = Fixture.project("Новый")
        let ledger = Ledger(
            projects: [old, new],
            recurringCosts: [Fixture.monthly(old, "Сервер", 1_000, from: "2026-01")],
            oneOffCosts: [],
            incomes: [
                Fixture.income(old, 4_000, on: "2026-10-05"),
                Fixture.income(old, 9_000, on: "2026-11-05"),
                Fixture.income(new, 700, on: "2026-11-03"),
            ]
        )
        let glances = MoneyEngine.glances(currentMonth: ym("2026-11"), ledger: ledger)
        #expect(glances.map(\.project.name) == ["Курсы", "Новый"])

        #expect(glances[0].month == ym("2026-10"))
        #expect(glances[0].net == units(3_000))
        #expect(glances[0].mood == .growing)
        #expect(!glances[0].isFirstMonth)

        #expect(glances[1].month == ym("2026-11"))
        #expect(glances[1].net == units(700))
        #expect(glances[1].mood == nil)
        #expect(glances[1].isFirstMonth)
    }
}
