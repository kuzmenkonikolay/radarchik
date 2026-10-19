import Foundation
import Testing
@testable import RadarchikCore

@Suite("Месяцы и даты")
struct CalendarTypesTests {
    @Test func monthStringRoundTrip() {
        #expect(YearMonth(string: "2026-10")?.stringValue == "2026-10")
        #expect(YearMonth(string: "2026-1")?.stringValue == "2026-01")
        #expect(YearMonth(string: "2026-13") == nil)
        #expect(YearMonth(string: "октябрь") == nil)
    }

    @Test func addingMonthsCrossesYears() {
        #expect(ym("2026-11").adding(months: 3) == ym("2027-02"))
        #expect(ym("2026-01").previous == ym("2025-12"))
        #expect(ym("2026-12").next == ym("2027-01"))
        #expect(ym("2027-01").months(since: ym("2026-10")) == 3)
        #expect(ym("2026-10").months(since: ym("2027-01")) == -3)
    }

    @Test func rangeIsInclusive() {
        #expect(YearMonth.range(from: ym("2026-11"), through: ym("2027-01")).map(\.stringValue) == ["2026-11", "2026-12", "2027-01"])
        #expect(YearMonth.range(from: ym("2026-02"), through: ym("2026-01")).isEmpty)
    }

    @Test func monthFromDateRespectsTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Moscow"))
        // 2026-10-31 22:30 UTC — в Москве это уже 1 ноября.
        let date = Date(timeIntervalSince1970: 1_793_485_800)
        #expect(YearMonth(date, calendar: calendar) == ym("2026-11"))
    }

    @Test func localDateParsingValidatesDays() {
        #expect(day("2026-10-18").yearMonth == ym("2026-10"))
        #expect(day("2026-10-05").stringValue == "2026-10-05")
        #expect(LocalDate(string: "2026-02-29") == nil)   // 2026 не високосный
        #expect(LocalDate(string: "2028-02-29") != nil)
        #expect(LocalDate(string: "2026-10-32") == nil)
        #expect(LocalDate(string: "вчера") == nil)
    }

    @Test func localDatesCompareChronologically() {
        #expect(day("2026-09-30") < day("2026-10-01"))
        #expect(day("2025-12-31") < day("2026-01-01"))
    }

    @Test func localDateSurvivesDaylightSavingSwitch() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let date = day("2026-03-29")   // в эту ночь в Европе переводят часы
        #expect(LocalDate(date.date(calendar: calendar), calendar: calendar) == date)
    }
}
