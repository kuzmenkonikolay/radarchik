import Testing
@testable import RadarchikCore

@Suite("Куда платить")
struct PaymentsTests {
    @Test func groupsByPayeeAndSortsByAmount() {
        let rub = Fixture.project("Курсы")
        let usd = Fixture.project("Бот", currency: .usd)
        let ledger = Ledger(
            projects: [rub, usd],
            recurringCosts: [
                Fixture.monthly(rub, "VPS", 2000, from: "2026-01", url: "https://timeweb.cloud/my"),
                Fixture.monthly(rub, "База", 3000, from: "2026-01", url: "selectel.ru/db"),
                Fixture.monthly(rub, "Сервер", 15_500, from: "2026-01", url: "https://my.selectel.ru/servers"),
                Fixture.monthly(usd, "Vercel Pro", 20, from: "2026-01", url: "https://vercel.com/dashboard"),
            ],
            oneOffCosts: [],
            incomes: []
        )
        let groups = Payments.groups(month: ym("2026-10"), ledger: ledger)
        #expect(groups.map(\.title) == ["Selectel", "Timeweb", "Vercel"])
        #expect(groups[0].totals == [CurrencyAmount(currency: .rub, amount: units(18_500))])
        #expect(groups[0].items.map(\.costName) == ["Сервер", "База"])   // внутри группы — по сумме
        #expect(groups[0].url?.absoluteString == "https://my.selectel.ru/servers")
        #expect(groups[2].totals == [CurrencyAmount(currency: .usd, amount: units(20))])
        #expect(Payments.totals(of: groups) == [
            CurrencyAmount(currency: .rub, amount: units(20_500)),
            CurrencyAmount(currency: .usd, amount: units(20)),
        ])
    }

    @Test func yearlyShowsUpOnlyInRenewalMonthWithFullAmount() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [Fixture.yearly(p, "Домен", 1200, from: "2026-03", url: "https://reg.ru/domains")],
            oneOffCosts: [], incomes: []
        )
        #expect(Payments.groups(month: ym("2026-10"), ledger: ledger).isEmpty)
        let march = Payments.groups(month: ym("2027-03"), ledger: ledger)
        #expect(march.first?.totals == [CurrencyAmount(currency: .rub, amount: units(1200))])
        #expect(march.first?.items.first?.period == .yearly)
    }

    @Test func costsWithoutLinkGoToOtherGroupAtTheEnd() {
        let p = Fixture.project()
        let ledger = Ledger(
            projects: [p],
            recurringCosts: [
                Fixture.monthly(p, "Бухгалтер", 9000, from: "2026-01"),
                Fixture.monthly(p, "Сервер", 100, from: "2026-01", url: "hetzner.com"),
            ],
            oneOffCosts: [], incomes: []
        )
        let groups = Payments.groups(month: ym("2026-10"), ledger: ledger)
        #expect(groups.map(\.title) == ["Hetzner", "Другое"])
        #expect(groups.last?.url == nil)
    }

    @Test func endedAndArchivedCostsAreNotDue() {
        let p = Fixture.project()
        let old = Fixture.project("Старый", archived: true)
        let ledger = Ledger(
            projects: [p, old],
            recurringCosts: [
                Fixture.monthly(p, "Сервер", 100, from: "2026-01", to: "2026-09", url: "hetzner.com"),
                Fixture.monthly(old, "Сервер", 100, from: "2026-01", url: "hetzner.com"),
            ],
            oneOffCosts: [], incomes: []
        )
        #expect(Payments.groups(month: ym("2026-10"), ledger: ledger).isEmpty)
    }

    @Test func payeeIsTheRegistrableDomainOfTheLink() {
        #expect(Payments.payeeKey(for: "https://www.My.Selectel.ru/a?b=c") == "selectel.ru")
        #expect(Payments.payeeKey(for: "console.hetzner.cloud") == "hetzner.cloud")
        #expect(Payments.payeeKey(for: "vercel.com") == "vercel.com")
        #expect(Payments.payeeKey(for: nil) == nil)
        #expect(Payments.payeeKey(for: "   ") == nil)
        #expect(Payments.payeeTitle(forKey: "selectel.ru") == "Selectel")
        #expect(Payments.normalizedURL("my.selectel.ru")?.absoluteString == "https://my.selectel.ru")
        #expect(Payments.normalizedURL("http://localhost:3000")?.absoluteString == "http://localhost:3000")
    }
}
