import Testing
@testable import RadarchikCore

/// Фраза говорит о последнем ЗАКРЫТОМ месяце (решение 2026-10-18): в текущем
/// регулярные траты начислены с 1-го числа, а доходы ещё не пришли. Текущий
/// месяц «пока» показывают крыло чёлки и график «Все проекты» (`MoneyEngine.monthTotals`).
/// Поэтому тесты «живут» в ноябре, а настроение считается по октябрю.
@Suite("Фраза Радарчика")
struct SummaryPhraseTests {
    let nb = "\u{00A0}"
    let minus = "\u{2212}"

    @Test func emptyLedgerInvitesToStart() {
        #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: .empty)
            == "Пока ни одного проекта. Заведи первый — и я начну считать.")
    }

    @Test func closedMonthWithProblemsAndPayments() {
        let ledger = threeProjects()
        #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger) ==
            "Октябрь закрыли в плюсе и с ростом. «Лендинг» третий месяц в минусе, «API для видео» проседает. "
            + "К оплате 30,5к\(nb)₽, больше всего Selectel — 15,5к\(nb)₽.")
        // В ноябре доходов ещё нет, а траты уже начислены — это видно в крыле чёлки, но не в антенке.
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [CurrencyAmount(currency: .rub, amount: units(-30_500))])
    }

    @Test func singleProjectDoesNotRepeatItself() {
        let p = Fixture.project("Лендинг")
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [Fixture.monthly(p, "Сервер", 10_000, from: "2026-01", url: "hetzner.com")],
            oneOffCosts: [],
            incomes: [Fixture.income(p, 15_000, on: "2026-07-10")]
        )
        #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger)
            == "Октябрь закрыли в минусе — уже третий месяц подряд. К оплате 10к\(nb)₽ — всё в Hetzner.")
    }

    @Test func severalCurrenciesAreDescribedSeparately() {
        let rub = Fixture.project("Курсы", currency: .rub)
        let usd = Fixture.project("Бот", currency: .usd)
        let ledger = Ledger(
            projects: [rub, usd],
            recurringCosts: [Fixture.monthly(usd, "Vercel", 300, from: "2026-01", url: "vercel.com")],
            oneOffCosts: [],
            incomes: [
                Fixture.income(rub, 1_000, on: "2026-09-10"),
                Fixture.income(rub, 1_000, on: "2026-10-10"),
                Fixture.income(usd, 100, on: "2026-10-10"),
                Fixture.income(rub, 500, on: "2026-11-02"),
            ]
        )
        #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger)
            == "Октябрь: ₽ — в плюсе, ровно; $ — в минусе. «Бот» в минусе. К оплате 300\(nb)$ — всё в Vercel.")
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [
            CurrencyAmount(currency: .rub, amount: units(500)),
            CurrencyAmount(currency: .usd, amount: units(-300)),
        ])
    }

    @Test func firstMonthHasNothingToSumUpYet() {
        // Всё заведено только в текущем месяце — закрытого месяца ещё нет.
        let p = Fixture.project("Новый")
        let ledger = Ledger(projects: [p], recurringCosts: [], oneOffCosts: [], incomes: [Fixture.income(p, 5_000, on: "2026-11-03")])
        #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger)
            == "Закрытых месяцев пока нет — итог подведу, когда этот закончится.")
        #expect(MoneyEngine.monthTotals(month: ym("2026-11"), ledger: ledger) == [CurrencyAmount(currency: .rub, amount: units(5_000))])
    }

    @Test func projectsWithoutAnyIncomeYet() {
        let p = Fixture.project("Новый")
        let ledger = Ledger(projects: [p], recurringCosts: [Fixture.monthly(p, "Сервер", 500, from: "2026-09")], oneOffCosts: [], incomes: [])
        // Трата без ссылки — в группе «Другое», поэтому без «всё в …».
        #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger)
            == "Октябрь закрыли без доходов. К оплате 500\(nb)₽.")
    }

    // MARK: - По-английски (2026-10-19)

    @Test func englishPhrases() {
        english {
            #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: .empty)
                == "No projects yet. Add your first one and I’ll start counting.")
            #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: threeProjects()) ==
                "October closed in profit and growing. “Лендинг” is at a loss for the 3rd month, “API для видео” is dipping. "
                + "Due: ₽30.5k, the biggest is Selectel — ₽15.5k.")
        }
    }

    @Test func englishLossStreakAndSinglePayee() {
        let p = Fixture.project("Landing")
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [Fixture.monthly(p, "Server", 10_000, from: "2026-01", url: "hetzner.com")],
            oneOffCosts: [],
            incomes: [Fixture.income(p, 15_000, on: "2026-07-10")]
        )
        english {
            #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger)
                == "October closed at a loss — 3rd month in a row. Due: ₽10k — all to Hetzner.")
        }
    }

    @Test func englishSeveralCurrenciesAndNoClosedMonth() {
        let rub = Fixture.project("Courses", currency: .rub)
        let usd = Fixture.project("Bot", currency: .usd)
        let ledger = Ledger(
            projects: [rub, usd],
            recurringCosts: [Fixture.monthly(usd, "Vercel", 300, from: "2026-01", url: "vercel.com")],
            oneOffCosts: [],
            incomes: [
                Fixture.income(rub, 1_000, on: "2026-09-10"),
                Fixture.income(rub, 1_000, on: "2026-10-10"),
                Fixture.income(usd, 100, on: "2026-10-10"),
            ]
        )
        let fresh = Fixture.project("New")
        let firstMonth = Ledger(projects: [fresh], recurringCosts: [], oneOffCosts: [], incomes: [Fixture.income(fresh, 5_000, on: "2026-11-03")])
        let sleeping = Ledger(projects: [fresh], recurringCosts: [Fixture.monthly(fresh, "Server", 500, from: "2026-09")], oneOffCosts: [], incomes: [])
        english {
            #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: ledger)
                == "October: ₽ — in profit, steady; $ — at a loss. “Bot” is at a loss. Due: $300 — all to Vercel.")
            #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: firstMonth)
                == "No closed months yet — I’ll sum up when this one ends.")
            #expect(SummaryPhrase.make(month: ym("2026-11"), ledger: sleeping)
                == "October closed with no income. Due: ₽500.")
        }
    }

    @Test func russianWords() {
        #expect(RussianWords.ordinal(2) == "второй")
        #expect(RussianWords.ordinal(3) == "третий")
        #expect(RussianWords.ordinal(14) == "14-й")
        #expect(RussianWords.monthName(10) == "Октябрь")
        #expect(RussianWords.monthYear(ym("2026-10")) == "Октябрь 2026")
        #expect(RussianWords.plural(1, "совет", "совета", "советов") == "совет")
        #expect(RussianWords.plural(3, "совет", "совета", "советов") == "совета")
        #expect(RussianWords.plural(11, "совет", "совета", "советов") == "советов")
        #expect(RussianWords.plural(22, "совет", "совета", "советов") == "совета")
    }

    /// Три рублёвых проекта: «Курсы» растёт, «API для видео» проседает,
    /// «Лендинг» третий месяц в минусе (по октябрю).
    private func threeProjects() -> Ledger {
        let courses = Fixture.project("Курсы")
        let api = Fixture.project("API для видео")
        let landing = Fixture.project("Лендинг")
        return Ledger(
            projects: [courses, api, landing],
            recurringCosts: [
                Fixture.monthly(courses, "Сервер", 15_500, from: "2026-01", url: "https://my.selectel.ru"),
                Fixture.monthly(api, "VPS", 5_000, from: "2026-01", url: "https://timeweb.cloud"),
                Fixture.monthly(landing, "Сервер", 10_000, from: "2026-01", url: "https://hetzner.com"),
            ],
            oneOffCosts: [],
            incomes: [
                Fixture.income(courses, 60_000, on: "2026-09-10"),
                Fixture.income(courses, 80_000, on: "2026-10-10"),
                Fixture.income(api, 30_000, on: "2026-09-10"),
                Fixture.income(api, 15_000, on: "2026-10-10"),
                Fixture.income(landing, 15_000, on: "2026-07-10"),
            ]
        )
    }
}
