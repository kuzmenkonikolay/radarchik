import Foundation
import Testing
@testable import RadarchikCore

@Suite("SQLite: несколько соединений")
struct DatabaseConcurrencyTests {
    /// С этапа 6 ресурсы пишут в ту же базу из фона, а деньги и наблюдение —
    /// с главного потока. Второе соединение должно подождать, пока первое
    /// допишет, а не падать сразу с «database is locked».
    @Test func secondConnectionWaitsForTheWriterInsteadOfFailing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radarchik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("radarchik.sqlite").path

        let writer = try Database(path: path)
        try writer.execute("CREATE TABLE t (x INTEGER)")
        let other = try Database(path: path)

        try writer.execute("BEGIN IMMEDIATE")
        try writer.run("INSERT INTO t VALUES (1)")
        // Первое соединение держит запись 0,2 с и отпускает из другого потока.
        nonisolated(unsafe) let busy = writer
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { try? busy.execute("COMMIT") }

        try other.run("INSERT INTO t VALUES (2)")
        #expect(try other.query("SELECT COUNT(*) FROM t") { $0.int(0) }.first == 2)
    }
}

@Suite("Хранение в SQLite")
struct LedgerRepositoryTests {
    func makeRepository() throws -> LedgerRepository {
        try LedgerRepository(database: Database(path: ":memory:"))
    }

    @Test func roundTripsAllRecords() throws {
        let repo = try makeRepository()
        let p = Fixture.project("Бот", currency: .usd)
        let cost = Fixture.monthly(p, "Сервер", 100, from: "2026-01", to: "2026-12", url: "hetzner.com", changes: [("2026-06", 150)])
        let domain = Fixture.yearly(p, "Домен", 12, from: "2026-03")
        let oneOff = Fixture.oneOff(p, 50, on: "2026-10-05", url: "reg.ru")
        let income = Fixture.income(p, 500, on: "2026-10-10")
        try repo.save(p)
        try repo.save(cost)
        try repo.save(domain)
        try repo.save(oneOff)
        try repo.save(income)

        let loaded = try repo.loadLedger()
        #expect(loaded.projects == [p])
        #expect(loaded.recurringCosts == [cost, domain])
        #expect(loaded.oneOffCosts == [oneOff])
        #expect(loaded.incomes == [income])
    }

    @Test func savingRecurringAgainReplacesPricesAndFields() throws {
        let repo = try makeRepository()
        let p = Fixture.project()
        try repo.save(p)
        var cost = Fixture.monthly(p, "Сервер", 100, from: "2026-01", changes: [("2026-06", 150)])
        try repo.save(cost)

        cost = cost.changingPrice(to: units(120), from: ym("2026-03"))
        cost.name = "Сервер Hetzner"
        cost.endMonth = ym("2026-11")
        try repo.save(cost)

        #expect(try repo.loadLedger().recurringCosts == [cost])
    }

    @Test func deletingProjectDeletesItsRecords() throws {
        let repo = try makeRepository()
        let p = Fixture.project()
        let other = Fixture.project("Другой")
        try repo.save(p)
        try repo.save(other)
        try repo.save(Fixture.monthly(p, "Сервер", 100, from: "2026-01"))
        try repo.save(Fixture.income(p, 100, on: "2026-10-01"))
        try repo.save(Fixture.oneOff(other, 10, on: "2026-10-01"))

        try repo.deleteProject(id: p.id)

        let ledger = try repo.loadLedger()
        #expect(ledger.projects == [other])
        #expect(ledger.recurringCosts.isEmpty)
        #expect(ledger.incomes.isEmpty)
        #expect(ledger.oneOffCosts.count == 1)
    }

    @Test func deletingSingleRecords() throws {
        let repo = try makeRepository()
        let p = Fixture.project()
        let cost = Fixture.monthly(p, "Сервер", 100, from: "2026-01")
        let oneOff = Fixture.oneOff(p, 10, on: "2026-10-01")
        let income = Fixture.income(p, 100, on: "2026-10-01")
        try repo.save(p)
        try repo.save(cost)
        try repo.save(oneOff)
        try repo.save(income)

        try repo.deleteRecurringCost(id: cost.id)
        try repo.deleteOneOffCost(id: oneOff.id)
        try repo.deleteIncome(id: income.id)

        let ledger = try repo.loadLedger()
        #expect(ledger.projects == [p])
        #expect(ledger.recurringCosts.isEmpty && ledger.oneOffCosts.isEmpty && ledger.incomes.isEmpty)
    }

    @Test func reopeningFileKeepsDataAndSchema() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radarchik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("radarchik.sqlite").path
        let p = Fixture.project()

        do {
            let repo = try LedgerRepository(database: Database(path: path))
            try repo.save(p)
        }
        let reopened = try LedgerRepository(database: Database(path: path))
        #expect(try reopened.loadLedger().projects == [p])
    }
}
