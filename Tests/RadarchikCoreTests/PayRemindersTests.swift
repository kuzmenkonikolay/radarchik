import Foundation
import Testing
@testable import RadarchikCore

@Suite("Пора платить")
struct PayRemindersTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }()

    @Test func remindsWithinWindowAndSkipsTheRest() {
        let p = Fixture.project()
        var selectel = Fixture.monthly(p, "GPU сервер", 15_500, from: "2026-01", url: "my.selectel.ru")
        selectel.dueDay = 22
        var hetzner = Fixture.monthly(p, "Hetzner", 4_500, from: "2026-01")
        hetzner.dueDay = 28
        let noDay = Fixture.monthly(p, "Домен", 240, from: "2026-01")
        let ledger = Ledger(projects: [p], recurringCosts: [selectel, hetzner, noDay], oneOffCosts: [], incomes: [])

        let reminders = Payments.upcoming(today: LocalDate(string: "2026-10-20")!, within: 2, ledger: ledger, calendar: calendar)
        #expect(reminders.count == 1)
        #expect(reminders[0].payee == "Selectel")
        #expect(reminders[0].daysLeft == 2)
        #expect(reminders[0].amount == units(15_500))
        #expect(reminders[0].dueDate == LocalDate(string: "2026-10-22"))
        #expect(reminders[0].id == "\(selectel.id.uuidString)|2026-10")
    }

    @Test func looksIntoNextMonthAndClampsDay() {
        let p = Fixture.project()
        var cost = Fixture.monthly(p, "Сервер", 100, from: "2026-01")
        cost.dueDay = 1
        let ledger = Ledger(projects: [p], recurringCosts: [cost], oneOffCosts: [], incomes: [])
        let reminders = Payments.upcoming(today: LocalDate(string: "2026-10-30")!, within: 2, ledger: ledger, calendar: calendar)
        #expect(reminders.map(\.dueDate) == [LocalDate(string: "2026-11-01")!])
        #expect(reminders[0].daysLeft == 2)
        // День списания больше 28 не бывает: февраль.
        #expect(RecurringCost(projectId: p.id, name: "x", period: .monthly, startMonth: ym("2026-01"), amount: 1, dueDay: 31).dueDay == 28)
    }

    @Test func switchedOffAndFutureCostsDoNotRemind() {
        let p = Fixture.project()
        var off = Fixture.monthly(p, "Старый", 100, from: "2026-01", to: "2026-09")
        off.dueDay = 21
        var future = Fixture.monthly(p, "Будущий", 100, from: "2026-12")
        future.dueDay = 21
        let ledger = Ledger(projects: [p], recurringCosts: [off, future], oneOffCosts: [], incomes: [])
        #expect(Payments.upcoming(today: LocalDate(string: "2026-10-20")!, within: 2, ledger: ledger, calendar: calendar).isEmpty)
    }

    @Test func yearlyRemindsOnlyInRenewalMonth() {
        let p = Fixture.project()
        var domain = Fixture.yearly(p, "Домен", 2_400, from: "2025-10")
        domain.dueDay = 5
        let ledger = Ledger(projects: [p], recurringCosts: [domain], oneOffCosts: [], incomes: [])
        #expect(Payments.upcoming(today: LocalDate(string: "2026-10-04")!, within: 2, ledger: ledger, calendar: calendar).count == 1)
        #expect(Payments.upcoming(today: LocalDate(string: "2026-11-04")!, within: 2, ledger: ledger, calendar: calendar).isEmpty)
    }

    @Test func dueDaySurvivesTheDatabase() throws {
        let repository = try LedgerRepository(database: Database(path: ":memory:"))
        let p = Fixture.project()
        try repository.save(p)
        var cost = Fixture.monthly(p, "Сервер", 100, from: "2026-01")
        cost.dueDay = 22
        try repository.save(cost)
        #expect(try repository.loadLedger().recurringCosts.first?.dueDay == 22)
        cost.dueDay = nil
        try repository.save(cost)
        #expect(try repository.loadLedger().recurringCosts.first?.dueDay == nil)
    }
}

@Suite("Фраза главной")
struct HomePhraseTests {
    @Test func emptyAndInProgress() {
        #expect(SummaryPhrase.home(month: ym("2026-10"), ledger: .empty) == "Пусто. Добавь первый проект — я посчитаю.")
        let p = Fixture.project()
        let ledger = Ledger(projects: [p], recurringCosts: [], oneOffCosts: [], incomes: [Fixture.income(p, 100, on: "2026-10-03")])
        #expect(SummaryPhrase.home(month: ym("2026-10"), ledger: ledger) == "Октябрь ещё идёт — итог подведу 1-го.")
    }

    @Test func namesTheProblemsThenPromisesTheTotal() {
        let a = Fixture.project("Парсер")
        let b = Fixture.project("Лендинг")
        let ledger = Ledger(
            projects: [a, b],
            recurringCosts: [Fixture.monthly(b, "Сервер", 1_000, from: "2026-05")],
            oneOffCosts: [],
            incomes: [
                Fixture.income(a, 5_000, on: "2026-08-10"), Fixture.income(a, 6_000, on: "2026-09-10"),
                Fixture.income(b, 100, on: "2026-07-10"), Fixture.income(b, 100, on: "2026-08-10"), Fixture.income(b, 100, on: "2026-09-10"),
            ]
        )
        #expect(SummaryPhrase.home(month: ym("2026-10"), ledger: ledger) == "«Лендинг» третий месяц в минусе. Итог подведу 1-го.")
    }

    @Test func payChip() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [
                Fixture.monthly(p, "GPU", 15_500, from: "2026-01", url: "my.selectel.ru"),
                Fixture.monthly(p, "Hetzner", 4_500, from: "2026-01", url: "console.hetzner.cloud"),
            ],
            oneOffCosts: [], incomes: []
        )
        #expect(SummaryPhrase.payChip(Payments.groups(month: ym("2026-10"), ledger: ledger)) == "К оплате 20к · больше всего Selectel")
        #expect(SummaryPhrase.payChip([]) == nil)
    }
}

@Suite("Эмоции лица")
struct FaceEmotionTests {
    @Test func statesMapToFaces() {
        #expect(MascotState.idleScan.emotion == .smug)
        #expect(MascotState.catchCoin.emotion == .happy)
        #expect(MascotState.catchCoin.hands == .up)
        #expect(MascotState.tipWave.wearsGlasses)
        #expect(MascotState.tipWave.hands == .wave)
        #expect(MascotState.nervous.emotion == .sad)
        #expect(MascotState.alarm.emotion == .wide)
        #expect(Mood.losing(streak: 2).emotion == .sad)
        #expect(Mood.sleeping.emotion == .sleep)
    }
}
