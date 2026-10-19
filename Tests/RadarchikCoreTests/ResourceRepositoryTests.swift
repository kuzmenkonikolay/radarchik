import Foundation
import Testing
@testable import RadarchikCore

@Suite("Ресурсы: хранение")
struct ResourceRepositoryTests {
    let chrome = AppIdentity(key: "com.google.Chrome", name: "Google Chrome")
    let day = 86_400.0

    func make() throws -> (Database, ResourceRepository) {
        let db = try Database(path: ":memory:")
        return (db, try ResourceRepository(database: db))
    }

    func bucket(_ start: Date, cpu: Double = 5, memory: Double = GiB, power: Double = 1) -> AppUsageBucket {
        AppUsageBucket(start: start, app: chrome, cpuAvg: cpu, cpuMax: cpu * 2, memoryAvg: memory, memoryMax: memory, powerAvg: power, samples: 20)
    }

    @Test func normsComeFromFiveMinuteBucketsOfTheLastWeek() throws {
        let (_, repo) = try make()
        var buckets: [AppUsageBucket] = []
        // Три дня по 20 пятиминуток: память 1 ГБ, процессор 5%.
        for d in 0..<3 {
            for i in 0..<20 { buckets.append(bucket(t0 - Double(d) * day - Double(i) * 300)) }
        }
        // Восемь дней назад — уже не в счёт.
        buckets.append(bucket(t0 - 8 * day, cpu: 500, memory: 30 * GiB))
        try repo.save(buckets)
        // Та же пятиминутка ещё раз (перезапуск) — заменяет, а не дублирует.
        try repo.save([bucket(t0)])

        let norms = try repo.appNorms(since: t0 - 7 * day, minimumSamples: 48, minimumDays: 2)
        let norm = try #require(norms[chrome.key])
        #expect(norm.cpu.median == 5)
        #expect(norm.memory.p95 == GiB)
        #expect(norm.power.median == 1)
        #expect(norm.cpu.samples == 60)
        #expect(norm.cpu.days == 3)
        #expect(norm.cpu.isReliable)
    }

    @Test func minutesAlertsAndOverridesRoundTrip() throws {
        let (_, repo) = try make()
        let minute = SystemMinute(
            start: t0, cpu: 23, memoryUsed: 14 * GiB, pressure: .warning, batteryLevel: 80,
            onBattery: true, drainRate: 9, temperature: 52, thermal: .fair
        )
        try repo.save(minute)
        #expect(try repo.minutes(since: t0 - 60) == [minute])

        let alert = try repo.insert(ResourceAlert(
            id: 0, kind: .memory, app: chrome, value: 4 * GiB, usual: GiB, startedAt: t0 - 300, createdAt: t0,
            title: "Google Chrome ест 4 ГБ — в 4 раза больше обычного", detail: nil, status: .active, statusChangedAt: nil
        ))
        #expect(alert.id > 0)
        try repo.setStatus(.normal, alertId: alert.id, at: t0 + 60)
        let stored = try repo.alerts(since: t0 - 1)
        #expect(stored.count == 1)
        #expect(stored.first?.app == chrome)
        #expect(stored.first?.status == .normal)
        #expect(stored.first?.statusChangedAt == t0 + 60)
        #expect(stored.first?.usual == GiB)

        try repo.setOverride(kind: .memory, appKey: chrome.key, level: 4 * GiB, at: t0)
        // Ниже прежнего — норму не опускает.
        try repo.setOverride(kind: .memory, appKey: chrome.key, level: 3 * GiB, at: t0 + 1)
        try repo.setOverride(kind: .battery, appKey: nil, level: 30, at: t0)
        let overrides = try repo.overrides()
        #expect(overrides[AlertKey(kind: .memory, appKey: chrome.key)] == 4 * GiB)
        #expect(overrides[AlertKey(kind: .battery, appKey: nil)] == 30)
    }

    @Test func drainNormFromMinutesOnBattery() throws {
        let (_, repo) = try make()
        for d in 0..<2 {
            for i in 0..<70 {
                try repo.save(SystemMinute(
                    start: t0 - Double(d) * day - Double(i) * 60, cpu: 10, memoryUsed: GiB, pressure: .normal,
                    batteryLevel: 70, onBattery: true, drainRate: 8, temperature: nil, thermal: .nominal
                ))
            }
        }
        // На зарядке разряда нет — эти минуты в норму не идут.
        try repo.save(SystemMinute(
            start: t0 + 60, cpu: 10, memoryUsed: GiB, pressure: .normal, batteryLevel: 90,
            onBattery: false, drainRate: nil, temperature: nil, thermal: .nominal
        ))
        let norm = try #require(try repo.drainNorm(since: t0 - 7 * day, minimumSamples: 120, minimumDays: 2))
        #expect(norm.median == 8)
        #expect(norm.samples == 140)
        #expect(norm.isReliable)
    }

    @Test func cleanupDropsOldUsageButKeepsRecent() throws {
        let (_, repo) = try make()
        try repo.save([bucket(t0 - 9 * day), bucket(t0)])
        try repo.save(SystemMinute(start: t0 - 9 * day, cpu: 1, memoryUsed: nil, pressure: .normal, batteryLevel: nil, onBattery: false, drainRate: nil, temperature: nil, thermal: .nominal))
        _ = try repo.insert(ResourceAlert(id: 0, kind: .cpu, app: chrome, value: 100, usual: nil, startedAt: t0 - 90 * day, createdAt: t0 - 90 * day, title: "старое", detail: nil, status: .later, statusChangedAt: nil))
        try repo.deleteOlderThan(usage: t0 - 8 * day, alerts: t0 - 60 * day)
        #expect(try repo.appNorms(since: t0 - 30 * day, minimumSamples: 1, minimumDays: 1)[chrome.key]?.cpu.samples == 1)
        #expect(try repo.minutes(since: t0 - 30 * day).isEmpty)
        #expect(try repo.alerts(since: t0 - 365 * day).isEmpty)
    }

    @Test func resourceTablesAreAddedToExistingDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radarchik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("radarchik.sqlite").path
        let project = Fixture.project()
        // Так выглядит база после этапа 5: деньги, наблюдение и советы, версия 3.
        do {
            let db = try Database(path: path)
            try DatabaseSchema.migrate(db, upTo: 3)
            // Сырым SQL: LedgerRepository сам догнал бы схему до последней версии.
            try db.run(
                "INSERT INTO projects (id, name, color_hex, currency, created_at, is_archived) VALUES (?, ?, ?, ?, ?, 0)",
                [.text(project.id.uuidString), .text(project.name), .text(project.colorHex),
                 .text(project.currency.rawValue), .real(project.createdAt.timeIntervalSince1970)]
            )
            #expect(try db.userVersion() == 3)
        }
        let db = try Database(path: path)
        let repo = try ResourceRepository(database: db)
        try repo.save([bucket(t0)])
        #expect(try db.userVersion() == DatabaseSchema.latestVersion)
        #expect(try LedgerRepository(database: Database(path: path)).loadLedger().projects == [project])
    }
}
