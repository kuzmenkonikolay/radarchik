import Foundation
import Testing
@testable import RadarchikCore

private let nb = "\u{00A0}"

/// Выдуманный мак для движка: процессы с заданной нагрузкой и замеры по часам,
/// которые идут только вперёд. Ничего системного — только числа.
final class FakeMac {
    typealias Load = (pid: Int32, app: AppIdentity, cpu: Double, memory: Double, watts: Double)

    let db: Database
    let repository: ResourceRepository
    let engine: ResourceEngine
    var now: Date
    /// Все тревоги, которые движок создал за прогон.
    private(set) var created: [ResourceAlert] = []
    private var cpuTime: [Int32: UInt64] = [:]
    private var energy: [Int32: UInt64] = [:]
    private var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)

    init(now: Date = t0, seed: (ResourceRepository) throws -> Void = { _ in }) throws {
        db = try Database(path: ":memory:")
        repository = try ResourceRepository(database: db)
        try seed(repository)
        engine = ResourceEngine(repository: repository, totalMemory: 24 * GiB, now: now)
        self.now = now
    }

    /// Процессы работают `seconds` секунд, замер раз в 15 с.
    func run(_ seconds: TimeInterval, _ load: [Load]) {
        for _ in 0..<Int(seconds / 15) {
            now += 15
            let readings = load.map { process -> ProcessReading in
                cpuTime[process.pid, default: 0] += UInt64(process.cpu / 100 * 15 * 1e9)
                energy[process.pid, default: 0] += UInt64(process.watts * 15 * 1e9)
                return ProcessReading(
                    pid: process.pid, startTime: 1, app: process.app, cpuTimeNs: cpuTime[process.pid] ?? 0,
                    memoryBytes: UInt64(process.memory), energyNj: energy[process.pid] ?? 0
                )
            }
            created += engine.ingest(processes: readings, at: now)
        }
    }

    /// Мак целиком `seconds` секунд, замер раз в 5 с. Процессор всегда занят на 20%.
    func runSystem(_ seconds: TimeInterval, _ make: () -> SystemReading) {
        for _ in 0..<Int(seconds / 5) {
            now += 5
            ticks.user &+= 100
            ticks.idle &+= 400
            var reading = make()
            reading.cpuTicks = [ticks, ticks]
            created += engine.ingest(system: reading, at: now)
        }
    }
}

extension SystemReading {
    /// На батарее: ток −1500 мА при ёмкости 5000 мА·ч — 30% в час.
    static func onBattery(amperage: Double = -1500) -> SystemReading {
        SystemReading(
            cpuTicks: [], memory: MemoryReading(usedBytes: UInt64(12 * GiB), totalBytes: UInt64(24 * GiB), pressure: .normal),
            battery: BatteryReading(level: 70, isCharging: false, onAC: false, amperage: amperage, capacityMah: 5000, minutesLeft: nil),
            temperature: 50, thermal: .nominal
        )
    }

    static func plugged(pressure: MemoryPressure = .normal, thermal: ThermalLevel = .nominal, temperature: Double? = 50) -> SystemReading {
        SystemReading(
            cpuTicks: [], memory: MemoryReading(usedBytes: UInt64(12 * GiB), totalBytes: UInt64(24 * GiB), pressure: pressure),
            battery: BatteryReading(level: 90, isCharging: true, onAC: true, amperage: 900, capacityMah: 5000, minutesLeft: nil),
            temperature: temperature, thermal: thermal
        )
    }
}

@Suite("Ресурсы: тревоги")
struct ResourceEngineTests {
    let node = AppIdentity(key: "process:node", name: "node")
    let chrome = AppIdentity(key: "com.google.Chrome", name: "Google Chrome")
    let docker = AppIdentity(key: "com.docker.docker", name: "Docker")

    @Test func runawayProcessWithoutNormAlertsAfterTenMinutes() throws {
        let mac = try FakeMac()
        mac.run(9 * 60, [(1, node, 100, 200 * MiB, 0)])
        // Девять минут на одном ядре — ещё терпим: может, это сборка.
        #expect(mac.created.isEmpty)
        mac.run(2 * 60, [(1, node, 100, 200 * MiB, 0)])
        #expect(mac.created.count == 1)
        let alert = try #require(mac.created.first)
        #expect(alert.kind == .cpu)
        #expect(alert.app == node)
        #expect(alert.usual == nil)
        #expect(alert.title == "node ест 100% процессора — целое ядро")
        #expect(mac.engine.state().alerts.map(\.id) == [alert.id])
    }

    @Test func heavyLoadOnManyCoresAlertsSooner() throws {
        let mac = try FakeMac()
        mac.run(4 * 60, [(1, docker, 450, 2 * GiB, 0)])
        #expect(mac.created.isEmpty)
        mac.run(90, [(1, docker, 450, 2 * GiB, 0)])
        #expect(mac.created.map(\.title) == ["Docker ест 450% процессора — 4,5 ядра"])
    }

    @Test func memoryWithoutNormNeedsAThirdOfTheMac() throws {
        let mac = try FakeMac()
        mac.run(11 * 60, [(1, docker, 20, 8 * GiB, 0), (2, chrome, 10, 5 * GiB, 0)])
        #expect(mac.created.map(\.title) == ["Docker держит 8\(nb)ГБ — треть всей памяти"])
    }

    @Test func laterSnoozesForThreeHours() throws {
        let mac = try FakeMac()
        let busy: [FakeMac.Load] = [(1, node, 100, 200 * MiB, 0)]
        mac.run(11 * 60, busy)
        let first = try #require(mac.created.first)
        mac.engine.respond(to: first.id, with: .later, at: mac.now)
        #expect(mac.engine.state().alerts.isEmpty)
        // Нагрузка никуда не делась, но пауза: по этому приложению молчим.
        mac.now += 3600
        mac.run(11 * 60, busy)
        #expect(mac.created.count == 1)
        // Пауза прошла — напоминаем.
        mac.now += 2 * 3600
        mac.run(11 * 60, busy)
        #expect(mac.created.count == 2)
    }

    @Test func thisIsNormalRaisesTheBar() throws {
        let mac = try FakeMac()
        mac.run(11 * 60, [(1, node, 100, 200 * MiB, 0)])
        let first = try #require(mac.created.first)
        mac.engine.respond(to: first.id, with: .normal, at: mac.now)
        mac.now += 4 * 3600
        mac.run(11 * 60, [(1, node, 100, 200 * MiB, 0)])
        // Тот же уровень — теперь норма.
        #expect(mac.created.count == 1)
        mac.now += 4 * 3600
        mac.run(11 * 60, [(1, node, 200, 200 * MiB, 0)])
        // Вдвое выше — снова тревога.
        #expect(mac.created.count == 2)
        // «Это нормально» хранится в базе и переживает перезапуск.
        #expect(try mac.repository.overrides()[AlertKey(kind: .cpu, appKey: node.key)] == first.value)
    }

    @Test func alertGoesAwayWhenLoadDrops() throws {
        let mac = try FakeMac()
        mac.run(11 * 60, [(1, node, 100, 200 * MiB, 0)])
        let alert = try #require(mac.created.first)
        mac.run(60, [(1, node, 10, 200 * MiB, 0)])
        // Минута — ещё рано: вдруг это пауза между задачами.
        #expect(mac.engine.state().alerts.count == 1)
        mac.run(2 * 60, [(1, node, 10, 200 * MiB, 0)])
        #expect(mac.engine.state().alerts.isEmpty)
        #expect(try mac.repository.alerts(since: t0).first { $0.id == alert.id }?.status == .resolved)
    }

    @Test func alertGoesAwayWhenAppQuits() throws {
        let mac = try FakeMac()
        mac.run(11 * 60, [(1, node, 100, 200 * MiB, 0)])
        #expect(mac.created.count == 1)
        mac.run(90, [])
        #expect(mac.engine.state().alerts.isEmpty)
    }

    @Test func memoryAgainstWeeklyNorm() throws {
        let day = 86_400.0
        let mac = try FakeMac { repository in
            // Неделя обычной жизни: Chrome держит 1 ГБ.
            var buckets: [AppUsageBucket] = []
            for d in 1...3 {
                for i in 0..<20 {
                    buckets.append(AppUsageBucket(
                        start: t0 - Double(d) * day - Double(i) * 300, app: AppIdentity(key: "com.google.Chrome", name: "Google Chrome"),
                        cpuAvg: 5, cpuMax: 9, memoryAvg: GiB, memoryMax: GiB, powerAvg: 1, samples: 20
                    ))
                }
            }
            try repository.save(buckets)
        }
        mac.run(6 * 60, [(1, chrome, 5, 3 * GiB, 1)])
        let alert = try #require(mac.created.first)
        #expect(mac.created.count == 1)
        #expect(alert.kind == .memory)
        #expect(alert.usual == GiB)
        #expect(alert.title == "Google Chrome ест 3\(nb)ГБ — в 3 раза больше обычного")
        // Обычные цифры видны и в списке приложений на экране «Система».
        #expect(mac.engine.state().apps.first { $0.id == chrome.key }?.usualMemory == GiB)
    }

    @Test func batteryDrainingFastNamesTheCulprit() throws {
        let mac = try FakeMac()
        mac.run(60, [(1, chrome, 50, GiB, 6), (2, node, 5, 100 * MiB, 0.5)])
        mac.runSystem(11 * 60) { .onBattery() }
        let alert = try #require(mac.created.first { $0.kind == .battery })
        #expect(alert.title == "Батарея садится быстро — 30% в час")
        #expect(alert.detail == "Больше всех ест Google Chrome")
        #expect(near(mac.engine.state().system?.drainRate, 30))
        // Подключил зарядку — тревога ушла сама.
        mac.runSystem(10) { .plugged() }
        #expect(mac.engine.state().alerts.allSatisfy { $0.kind != .battery })
    }

    @Test func memoryPressureAndHeat() throws {
        let mac = try FakeMac()
        mac.run(30, [(1, chrome, 340, 6.2 * GiB, 3)])
        mac.runSystem(3 * 60) { .plugged(pressure: .critical) }
        let pressure = try #require(mac.created.first { $0.kind == .pressure })
        #expect(pressure.title == "Памяти не хватает")
        #expect(pressure.detail == "Больше всех держит Google Chrome — 6,2\(nb)ГБ")
        mac.runSystem(3 * 60) { .plugged(thermal: .serious, temperature: 95) }
        let heat = try #require(mac.created.first { $0.kind == .thermal })
        #expect(heat.title == "Мак перегрелся — 95°")
        #expect(heat.detail == "Больше всех грузит Google Chrome — 340% процессора")
        // Давление прошло — тревога о памяти ушла сама.
        #expect(mac.engine.state().alerts.map(\.kind) == [.thermal])
    }

    @Test func sleepGapStartsOver() throws {
        let mac = try FakeMac()
        mac.run(6 * 60, [(1, node, 100, 200 * MiB, 0)])
        // Мак спал полчаса: два куска по 6 минут — это не 10 минут подряд.
        mac.now += 30 * 60
        mac.run(6 * 60, [(1, node, 100, 200 * MiB, 0)])
        #expect(mac.created.isEmpty)
    }

    @Test func usageIsSavedInFiveMinuteBucketsWithoutDust() throws {
        let mac = try FakeMac()
        let tiny = AppIdentity(key: "process:cfprefsd", name: "cfprefsd")
        mac.run(11 * 60, [(1, chrome, 20, GiB, 1), (2, tiny, 0.1, 5 * MiB, 0)])
        let rows = try mac.db.query("SELECT app_key, COUNT(*) FROM app_usage GROUP BY app_key") { ($0.text(0) ?? "", $0.int(1)) }
        // Мелочь вроде cfprefsd норм не требует и базу не засоряет.
        #expect(rows.map(\.0) == [chrome.key])
        #expect((rows.first?.1 ?? 0) >= 1)
    }

    @Test func hourHistoryForTheChart() throws {
        let mac = try FakeMac()
        mac.runSystem(5 * 60) { .plugged() }
        let history = mac.engine.state().history
        #expect(history.count >= 5)
        #expect(history.allSatisfy { near($0.cpu, 20) })
        #expect(near(mac.engine.state().system?.cpuPercent, 20))
        // И в базе: после перезапуска график за час не пустой.
        #expect(try mac.repository.minutes(since: t0).count >= 4)
    }

    @Test func activeAlertsSurviveRestartButOldOnesAreClosed() throws {
        let db = try Database(path: ":memory:")
        let repository = try ResourceRepository(database: db)
        func alert(createdAt: Date) throws -> ResourceAlert {
            try repository.insert(ResourceAlert(
                id: 0, kind: .cpu, app: node, value: 100, usual: nil, startedAt: createdAt - 600, createdAt: createdAt,
                title: "node ест 100% процессора — целое ядро", detail: nil, status: .active, statusChangedAt: nil
            ))
        }
        let fresh = try alert(createdAt: t0 - 600)
        let stale = try alert(createdAt: t0 - 2 * 3600)
        let engine = ResourceEngine(repository: repository, totalMemory: 24 * GiB, now: t0)
        #expect(engine.state().alerts.map(\.id) == [fresh.id])
        #expect(try repository.alerts(since: t0 - 3 * 3600).first { $0.id == stale.id }?.status == .resolved)
    }
}
