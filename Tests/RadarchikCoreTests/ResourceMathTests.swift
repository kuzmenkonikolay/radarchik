import Foundation
import Testing
@testable import RadarchikCore

// Этап 6: ресурсы мака (SPEC §3а). Здесь — чистая математика замеров,
// нормы, «держится ли превышение», пороги и раскладка по приложениям.

let GiB = 1_073_741_824.0
let MiB = 1_048_576.0

func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 1e-6) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

@Suite("Ресурсы: процессор, память, батарея, температура")
struct ResourceMathTests {
    @Test func cpuLoadFromTickDeltas() {
        let before = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let after = [CPUTicks(user: 200, system: 100, idle: 900, nice: 0), CPUTicks(user: 50, system: 0, idle: 1150, nice: 0)]
        // Первое ядро занято 150 тиков из 200, второе — 50 из 200: всего половина.
        #expect(near(CPULoad.percent(from: before, to: after), 50))
        // nice — тоже работа.
        #expect(near(CPULoad.percent(from: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)], to: [CPUTicks(user: 0, system: 0, idle: 75, nice: 25)]), 25))
    }

    @Test func cpuLoadSurvivesCounterWrapAndRejectsBadInput() {
        // 32-битный счётчик переполнился: 4294967290 → 10 — это +16 тиков.
        let before = [CPUTicks(user: 4_294_967_290, system: 0, idle: 100, nice: 0)]
        let after = [CPUTicks(user: 10, system: 0, idle: 116, nice: 0)]
        #expect(near(CPULoad.percent(from: before, to: after), 50))
        // Другое число ядер или замер без изменений — не считаем.
        #expect(CPULoad.percent(from: before, to: after + after) == nil)
        #expect(CPULoad.percent(from: after, to: after) == nil)
        #expect(CPULoad.percent(from: [], to: []) == nil)
    }

    @Test func memoryUsedLikeActivityMonitorAndPressureLevels() {
        // active + inactive + speculative + wired + compressed − purgeable − external
        #expect(MemoryMath.usedPages(active: 100, inactive: 50, speculative: 10, wired: 40, compressed: 30, purgeable: 20, external: 60) == 150)
        // Вычитаемых страниц больше, чем есть, — ноль, а не переполнение.
        #expect(MemoryMath.usedPages(active: 1, inactive: 0, speculative: 0, wired: 0, compressed: 0, purgeable: 5, external: 5) == 0)
        #expect(MemoryMath.pressure(sysctlLevel: 1) == .normal)
        #expect(MemoryMath.pressure(sysctlLevel: 2) == .warning)
        #expect(MemoryMath.pressure(sysctlLevel: 4) == .critical)
        #expect(MemoryMath.pressure(sysctlLevel: 0) == .normal)
    }

    @Test func batteryDrainFromCurrentOrFromLevels() {
        // −1500 мА при ёмкости 5000 мА·ч — 30% в час.
        #expect(near(BatteryMath.drainRate(amperage: -1500, capacityMah: 5000), 30))
        // Заряжается или данных нет — разряда нет.
        #expect(BatteryMath.drainRate(amperage: 800, capacityMah: 5000) == nil)
        #expect(BatteryMath.drainRate(amperage: nil, capacityMah: 5000) == nil)
        #expect(BatteryMath.drainRate(amperage: -1500, capacityMah: 0) == nil)
        // Без тока — по снижению заряда: 80 → 76% за 15 минут = 16% в час.
        #expect(near(BatteryMath.drainRate(levels: [(t0, 80), (t0 + 300, 79), (t0 + 900, 76)]), 16))
        // Меньше 10 минут — шум, а не скорость.
        #expect(BatteryMath.drainRate(levels: [(t0, 80), (t0 + 300, 79)]) == nil)
        // Заряд вырос — это не разряд.
        #expect(BatteryMath.drainRate(levels: [(t0, 70), (t0 + 900, 72)]) == nil)
    }

    @Test func onlyUsefulSensorsAreAsked() {
        // Опрос всех 77 датчиков стоил 73 мс (2026-10-19) — спрашиваем только нужные.
        #expect(TemperatureSensors.indicesToRead(["PMU tdie1", "gas gauge battery", "PMU tdie2", "NAND CH0 temp"]) == [0, 2])
        #expect(TemperatureSensors.indicesToRead(["pACC MTR Temp Sensor2", "PMU tcal"]) == [0])
        // Кристалла не нашли — всё, кроме батареи и SSD.
        #expect(TemperatureSensors.indicesToRead(["Sensor A", "gas gauge battery", "Sensor B"]) == [0, 2])
        #expect(TemperatureSensors.indicesToRead([]).isEmpty)
    }

    @Test func chipTemperaturePrefersDieSensors() {
        #expect(near(TemperatureSensors.chipTemperature([("PMU tdie1", 50), ("PMU tdie2", 54), ("gas gauge battery", 30), ("NAND CH0 temp", 40)]), 52))
        #expect(near(TemperatureSensors.chipTemperature([("pACC MTR Temp Sensor2", 60), ("eACC MTR Temp Sensor0", 50), ("gas gauge battery", 30)]), 55))
        // Незнакомые имена — среднее по всем, кроме батареи и SSD.
        #expect(near(TemperatureSensors.chipTemperature([("Sensor A", 45), ("gas gauge battery", 30), ("NAND CH0 temp", 40)]), 45))
        // Нули и мусор отбрасываются.
        #expect(TemperatureSensors.chipTemperature([("PMU tdie1", 0), ("PMU tdie2", -1)]) == nil)
        #expect(TemperatureSensors.chipTemperature([]) == nil)
    }
}

@Suite("Ресурсы: нормы и «держится»")
struct ResourceNormTests {
    @Test func quantilesInterpolate() {
        let values = (1...100).map(Double.init)
        #expect(near(Quantile.of(values, 0.5), 50.5))
        #expect(near(Quantile.of(values, 0.95), 95.05))
        #expect(near(Quantile.of([7], 0.95), 7))
        #expect(near(Quantile.of([1, 3], 0.5), 2))
    }

    @Test func normIsReliableOnlyAfterEnoughDataAndDays() throws {
        let values = Array(repeating: 10.0, count: 60) + [30, 40]
        let norm = try #require(UsageNorm(values: values.shuffled(), days: 3, minimumSamples: 48, minimumDays: 2))
        #expect(norm.median == 10)
        #expect(norm.samples == 62)
        #expect(norm.days == 3)
        #expect(norm.isReliable)
        // Мало данных или всё за один день — нормы ещё нет, только абсолютные пороги.
        #expect(UsageNorm(values: Array(values.prefix(20)), days: 3, minimumSamples: 48, minimumDays: 2)?.isReliable == false)
        #expect(UsageNorm(values: values, days: 1, minimumSamples: 48, minimumDays: 2)?.isReliable == false)
        #expect(UsageNorm(values: [], days: 0, minimumSamples: 48, minimumDays: 2) == nil)
    }

    @Test func sustainedNeedsCoverageMostPointsAndAverage() {
        var window = SampleWindow(keep: 12 * 60)
        for step in 0...20 { window.append(100, at: t0 + Double(step) * 15) }  // 5 минут, замер раз в 15 с
        let now = t0 + 300
        #expect(window.isSustained(above: 90, for: 300, now: now))
        // Окно длиннее, чем мы успели посмотреть, — ещё рано.
        #expect(!window.isSustained(above: 90, for: 600, now: now))
        #expect(near(window.average(last: 300, now: now), 100))
        #expect(window.latest == 100)
    }

    @Test func shortDipsDoNotBreakButLongOnesDo() {
        var dips = SampleWindow(keep: 12 * 60)
        for step in 0...20 { dips.append(step % 10 == 5 ? 40 : 100, at: t0 + Double(step) * 15) }  // 2 провала из 21
        #expect(dips.isSustained(above: 90, for: 300, now: t0 + 300))
        var sagging = SampleWindow(keep: 12 * 60)
        for step in 0...20 { sagging.append(step % 4 == 0 ? 40 : 100, at: t0 + Double(step) * 15) }  // 6 из 21
        #expect(!sagging.isSustained(above: 90, for: 300, now: t0 + 300))
    }

    @Test func staysBelowAndForgetsOldPoints() {
        var window = SampleWindow(keep: 12 * 60)
        for step in 0...10 { window.append(10, at: t0 + Double(step) * 15) }  // 2,5 минуты
        #expect(window.isSustained(below: 50, for: 120, now: t0 + 150))
        #expect(!window.isSustained(below: 5, for: 120, now: t0 + 150))
        // Всё старше 12 минут выбрасывается.
        window.append(10, at: t0 + 1000)
        #expect(window.points.count == 1)
        window.removeAll()
        #expect(window.latest == nil)
    }
}

@Suite("Ресурсы: приложения и пятиминутки")
struct AppUsageTests {
    let chrome = AppIdentity(key: "com.google.Chrome", name: "Google Chrome")
    let node = AppIdentity(key: "process:node", name: "node")

    @Test func helpersBelongToOutermostApp() {
        let renderer = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130.0.6723.70/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(AppIdentityResolver.outermostAppBundle(inExecutablePath: renderer) == "/Applications/Google Chrome.app")
        #expect(AppIdentityResolver.outermostAppBundle(inExecutablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend") == "/Applications/Docker.app")
        #expect(AppIdentityResolver.outermostAppBundle(inExecutablePath: "/opt/homebrew/bin/node") == nil)
        // «.app» — только папка целиком с таким окончанием.
        #expect(AppIdentityResolver.outermostAppBundle(inExecutablePath: "/Users/me/my.app.backup/bin/tool") == nil)
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        #expect(AppIdentityResolver.isXPCService(webContent))
        #expect(!AppIdentityResolver.isXPCService("/opt/homebrew/bin/node"))
    }

    @Test func plainProcessesAreGroupedByName() {
        #expect(AppIdentityResolver.processIdentity("node") == AppIdentity(key: "process:node", name: "node"))
        // Виртуальная машина без приложения-заказчика — понятным именем.
        #expect(AppIdentityResolver.processIdentity("com.apple.Virtualization.VirtualMachine").name == "Виртуальная машина")
    }

    @Test func usageSumsProcessesOfOneAppByDeltas() throws {
        let previous = [
            ProcessReading(pid: 10, startTime: 1, app: chrome, cpuTimeNs: 1_000_000_000, memoryBytes: 500_000_000, energyNj: 1_000_000_000),
            ProcessReading(pid: 11, startTime: 1, app: chrome, cpuTimeNs: 0, memoryBytes: 300_000_000, energyNj: 0),
            ProcessReading(pid: 20, startTime: 5, app: node, cpuTimeNs: 10_000_000_000, memoryBytes: 100_000_000, energyNj: 0),
        ]
        let current = [
            // +1,5 с процессора за 10 с — 15%; +20 Дж — 2 Вт.
            ProcessReading(pid: 10, startTime: 1, app: chrome, cpuTimeNs: 2_500_000_000, memoryBytes: 600_000_000, energyNj: 21_000_000_000),
            ProcessReading(pid: 11, startTime: 1, app: chrome, cpuTimeNs: 500_000_000, memoryBytes: 300_000_000, energyNj: 0),
            // Новый процесс: память считаем сразу, процессор — со следующего замера.
            ProcessReading(pid: 12, startTime: 9, app: chrome, cpuTimeNs: 5_000_000_000, memoryBytes: 100_000_000, energyNj: 0),
            // Тот же pid, но другой процесс (время запуска другое) — тоже новый.
            ProcessReading(pid: 20, startTime: 7, app: node, cpuTimeNs: 1_000_000_000, memoryBytes: 50_000_000, energyNj: 0),
        ]
        let usage = AppUsageAggregator.usage(previous: previous, current: current, seconds: 10)
        let chromeUsage = try #require(usage.first { $0.app == chrome })
        #expect(near(chromeUsage.cpuPercent, 20))
        #expect(chromeUsage.memoryBytes == 1_000_000_000)
        #expect(near(chromeUsage.powerWatts, 2))
        #expect(chromeUsage.processCount == 3)
        let nodeUsage = try #require(usage.first { $0.app == node })
        #expect(nodeUsage.cpuPercent == 0)
        #expect(nodeUsage.memoryBytes == 50_000_000)
    }

    @Test func bucketsAverageWithinFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1_760_000_100)  // ровно начало пятиминутки
        var bucketer = UsageBucketer()
        func sample(cpu: Double, memory: UInt64, power: Double) -> [AppUsage] {
            [AppUsage(app: chrome, cpuPercent: cpu, memoryBytes: memory, powerWatts: power, processCount: 3)]
        }
        #expect(bucketer.add(sample(cpu: 10, memory: 1_000, power: 1), at: start).isEmpty)
        #expect(bucketer.add(sample(cpu: 30, memory: 3_000, power: 3), at: start + 150).isEmpty)
        let finished = bucketer.add(sample(cpu: 50, memory: 5_000, power: 5), at: start + 300)
        #expect(finished == [AppUsageBucket(start: start, app: chrome, cpuAvg: 20, cpuMax: 30, memoryAvg: 2_000, memoryMax: 3_000, powerAvg: 2, samples: 2)])
        #expect(bucketer.flush() == [AppUsageBucket(start: start + 300, app: chrome, cpuAvg: 50, cpuMax: 50, memoryAvg: 5_000, memoryMax: 5_000, powerAvg: 5, samples: 1)])
        #expect(bucketer.flush().isEmpty)
    }

    @Test func systemMinutesAverageAndKeepWorst() {
        let start = Date(timeIntervalSince1970: 1_760_000_100)
        var bucketer = SystemMinuteBucketer()
        func snapshot(_ at: Date, cpu: Double, pressure: MemoryPressure, thermal: ThermalLevel, drain: Double?) -> SystemSnapshot {
            SystemSnapshot(
                at: at, cpuPercent: cpu, memory: MemoryReading(usedBytes: 10, totalBytes: 100, pressure: pressure),
                battery: BatteryReading(level: 80, isCharging: false, onAC: false, amperage: nil, capacityMah: nil, minutesLeft: nil),
                drainRate: drain, temperature: 50, thermal: thermal
            )
        }
        #expect(bucketer.add(snapshot(start, cpu: 20, pressure: .normal, thermal: .nominal, drain: 10)) == nil)
        #expect(bucketer.add(snapshot(start + 30, cpu: 40, pressure: .warning, thermal: .fair, drain: nil)) == nil)
        #expect(bucketer.current?.cpu == 30)
        let minute = bucketer.add(snapshot(start + 60, cpu: 90, pressure: .normal, thermal: .nominal, drain: 12))
        #expect(minute?.start == start)
        #expect(minute?.cpu == 30)
        #expect(minute?.memoryUsed == 10)
        // За минуту запоминаем худшее: давление и нагрев.
        #expect(minute?.pressure == .warning)
        #expect(minute?.thermal == .fair)
        #expect(minute?.drainRate == 10)
        #expect(minute?.onBattery == true)
        #expect(minute?.batteryLevel == 80)
        #expect(bucketer.current?.start == start + 60)
    }
}

@Suite("Ресурсы: пороги тревог")
struct ResourceRulesTests {
    let rules = ResourceRules()

    @Test func cpuThresholdUsesNormWhenReliable() {
        #expect(rules.cpu(norm: UsageNorm(median: 5, p95: 20), override: nil) == [Threshold(value: 30, duration: 300)])
        #expect(rules.cpu(norm: UsageNorm(median: 20, p95: 50), override: nil) == [Threshold(value: 60, duration: 300)])
        // Обычные пики (p95) выше трёх медиан — порог по ним.
        #expect(rules.cpu(norm: UsageNorm(median: 10, p95: 90), override: nil) == [Threshold(value: 90, duration: 300)])
    }

    @Test func cpuWithoutNormUsesAbsoluteTiers() {
        let tiers = [Threshold(value: 90, duration: 600), Threshold(value: 400, duration: 300)]
        #expect(rules.cpu(norm: nil, override: nil) == tiers)
        #expect(rules.cpu(norm: UsageNorm(median: 5, p95: 20, samples: 10, days: 1, isReliable: false), override: nil) == tiers)
        // «Это нормально» на 400%: дальше тревожим только выше 500%.
        #expect(rules.cpu(norm: nil, override: 400) == [Threshold(value: 500, duration: 600), Threshold(value: 500, duration: 300)])
    }

    @Test func memoryThresholds() {
        #expect(rules.memory(norm: UsageNorm(median: 0.8 * GiB, p95: GiB), totalBytes: 24 * GiB, override: nil) == Threshold(value: 2 * GiB, duration: 300))
        // Маленьким приложениям не тревожим ниже 1,5 ГБ.
        #expect(rules.memory(norm: UsageNorm(median: 0.3 * GiB, p95: 0.5 * GiB), totalBytes: 24 * GiB, override: nil) == Threshold(value: 1.5 * GiB, duration: 300))
        // Без нормы — 30% памяти мака, но не меньше 4 ГБ, и держаться дольше.
        #expect(rules.memory(norm: nil, totalBytes: 24 * GiB, override: nil) == Threshold(value: 0.3 * (24 * GiB), duration: 600))
        #expect(rules.memory(norm: nil, totalBytes: 8 * GiB, override: nil) == Threshold(value: 4 * GiB, duration: 600))
        #expect(rules.memory(norm: UsageNorm(median: 0.8 * GiB, p95: GiB), totalBytes: 24 * GiB, override: 3 * GiB) == Threshold(value: 3.75 * GiB, duration: 300))
    }

    @Test func drainThresholds() {
        #expect(rules.drain(norm: UsageNorm(median: 10, p95: 14), override: nil) == Threshold(value: 20, duration: 600))
        #expect(rules.drain(norm: UsageNorm(median: 5, p95: 8), override: nil) == Threshold(value: 15, duration: 600))
        #expect(rules.drain(norm: nil, override: nil) == Threshold(value: 25, duration: 600))
    }
}
