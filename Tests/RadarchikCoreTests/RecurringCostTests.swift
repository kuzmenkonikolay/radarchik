import Testing
@testable import RadarchikCore

@Suite("Регулярные траты")
struct RecurringCostTests {
    let project = Fixture.project()

    @Test func monthlyAccruesFromStartThroughEndInclusive() {
        let cost = Fixture.monthly(project, "Сервер", 1500, from: "2026-03", to: "2026-05")
        #expect(cost.accrual(in: ym("2026-02")) == 0)
        #expect(cost.accrual(in: ym("2026-03")) == units(1500))
        #expect(cost.accrual(in: ym("2026-05")) == units(1500))
        #expect(cost.accrual(in: ym("2026-06")) == 0)
    }

    @Test func monthlyWithoutEndKeepsAccruing() {
        let cost = Fixture.monthly(project, "Сервер", 1500, from: "2026-03")
        #expect(cost.accrual(in: ym("2030-01")) == units(1500))
    }

    @Test func priceChangeAppliesFromItsMonthAndKeepsHistory() {
        let cost = Fixture.monthly(project, "Hetzner", 500, from: "2026-01", changes: [("2026-04", 650)])
        #expect(cost.accrual(in: ym("2026-03")) == units(500))
        #expect(cost.accrual(in: ym("2026-04")) == units(650))
        #expect(cost.accrual(in: ym("2026-12")) == units(650))
    }

    @Test func yearlyIsSpreadOverTwelveMonthsAndSumsExactly() {
        // 1000 ₽ = 100 000 коп. = 12 × 8333 + 4 → первые 4 месяца по 8334.
        let cost = Fixture.yearly(project, "Домен", 1000, from: "2026-03")
        let year = YearMonth.range(from: ym("2026-03"), through: ym("2027-02"))
        let accruals = year.map { cost.accrual(in: $0) }
        #expect(accruals.reduce(0, +) == units(1000))
        #expect(accruals.prefix(4).allSatisfy { $0 == 8334 })
        #expect(accruals.dropFirst(4).allSatisfy { $0 == 8333 })
        #expect(cost.accrual(in: ym("2026-02")) == 0)
    }

    @Test func yearlyEndedMidYearFinishesPaidYearButDoesNotRenew() {
        let cost = Fixture.yearly(project, "Домен", 1200, from: "2026-01", to: "2026-05")
        #expect(cost.accrual(in: ym("2026-12")) == units(100))
        #expect(cost.accrual(in: ym("2027-01")) == 0)
    }

    @Test func yearlyRenewalUsesPriceOfRenewalMonth() {
        let cost = Fixture.yearly(project, "Домен", 1200, from: "2026-01", changes: [("2026-06", 2400)])
        #expect(cost.accrual(in: ym("2026-12")) == units(100))   // год оплачен в январе по старой цене
        #expect(cost.accrual(in: ym("2027-01")) == units(200))   // продление — уже по новой
    }

    @Test func monthlyIsDueEveryActiveMonth() {
        let cost = Fixture.monthly(project, "Сервер", 1500, from: "2026-03", to: "2026-05")
        #expect(cost.due(in: ym("2026-02")) == nil)
        #expect(cost.due(in: ym("2026-04")) == units(1500))
        #expect(cost.due(in: ym("2026-06")) == nil)
    }

    @Test func yearlyIsDueWhollyInRenewalMonthsOnly() {
        let cost = Fixture.yearly(project, "Домен", 1200, from: "2026-03", to: "2027-06")
        #expect(cost.due(in: ym("2026-03")) == units(1200))
        #expect(cost.due(in: ym("2026-04")) == nil)
        #expect(cost.due(in: ym("2027-03")) == units(1200))
        #expect(cost.due(in: ym("2028-03")) == nil)   // после последнего месяца продлений нет
    }

    @Test func activityDependsOnEndMonth() {
        let open = Fixture.monthly(project, "Сервер", 100, from: "2026-01")
        let ended = Fixture.monthly(project, "Сервер", 100, from: "2026-01", to: "2026-09")
        #expect(open.isActive(asOf: ym("2026-10")))
        #expect(ended.isActive(asOf: ym("2026-09")))
        #expect(!ended.isActive(asOf: ym("2026-10")))
    }

    @Test func changingPriceDropsLaterChangesAndKeepsEarlier() {
        let cost = Fixture.monthly(project, "Сервер", 100, from: "2026-01", changes: [("2026-05", 200), ("2026-09", 300)])
        let changed = cost.changingPrice(to: units(250), from: ym("2026-07"))
        #expect(changed.prices == [
            PriceChange(effectiveFrom: ym("2026-01"), amount: units(100)),
            PriceChange(effectiveFrom: ym("2026-05"), amount: units(200)),
            PriceChange(effectiveFrom: ym("2026-07"), amount: units(250)),
        ])
    }

    @Test func changingPriceBeforeStartRewritesWholeHistory() {
        let cost = Fixture.monthly(project, "Сервер", 100, from: "2026-03", changes: [("2026-05", 200)])
        // Месяц раньше старта значит «исправить с самого начала» (опечатка в цене).
        let fixed = cost.changingPrice(to: units(150), from: ym("2026-01"))
        #expect(fixed.prices == [PriceChange(effectiveFrom: ym("2026-03"), amount: units(150))])
    }

    @Test func movingStartKeepsPriceThatWasInEffect() {
        let cost = Fixture.monthly(project, "Сервер", 100, from: "2026-01", changes: [("2026-05", 200)])
        #expect(cost.withStartMonth(ym("2026-06")).prices == [
            PriceChange(effectiveFrom: ym("2026-06"), amount: units(200)),
        ])
        #expect(cost.withStartMonth(ym("2025-11")).prices == [
            PriceChange(effectiveFrom: ym("2025-11"), amount: units(100)),
            PriceChange(effectiveFrom: ym("2026-05"), amount: units(200)),
        ])
    }
}
