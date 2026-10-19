import Foundation

/// Сердце этапа 6 (SPEC §3а): принимает замеры, считает проценты, пишет
/// сводки в базу, держит нормы за неделю и решает, когда тревожить.
///
/// Системных вызовов здесь нет — их делают `SystemProbe` и `ProcessProbe`.
/// Поэтому всё поведение проверяется тестами на выдуманном маке (`FakeMac`).
/// Не потокобезопасен: в приложении живёт внутри одного актора (`ResourceWorker`).
///
/// Как устроена тревога:
/// 1. Замер мака — раз в 5 с, замер процессов — раз в 15 с. По каждому
///    приложению и по маку целиком копятся окна последних 12 минут (`SampleWindow`).
/// 2. Порог берётся из `ResourceRules`: с нормой (медиана и p95 за неделю) или
///    абсолютный, пока нормы нет. «Это нормально» поднимает его.
/// 3. Превышение должно держаться (5–10 минут, давление и нагрев — 2).
/// 4. После тревоги — пауза 3 часа по этому приложению и виду.
/// 5. Прошло само (2 минуты ниже 80% порога или приложение закрыли) — тревога уходит.
public final class ResourceEngine {
    public let rules: ResourceRules

    private let repository: ResourceRepository

    // MARK: Мак целиком
    private var previousTicks: [CPUTicks]?
    private var lastSystemAt: Date?
    private var latestSystem: SystemSnapshot?
    private var minuteBucketer = SystemMinuteBucketer()
    /// Законченные минуты за последний час — график на экране «Система».
    private var recentMinutes: [SystemMinute] = []
    private var drainWindow = SampleWindow(keep: 12 * 60)
    private var pressureWindow = SampleWindow(keep: 12 * 60)
    private var thermalWindow = SampleWindow(keep: 12 * 60)
    /// Заряд за последние 20 минут — если батарея не сказала ток.
    private var levels: [(at: Date, level: Double)] = []
    private var totalMemory: Double

    // MARK: Приложения
    private var previousProcesses: [ProcessReading] = []
    private var lastProcessAt: Date?
    private var usageBucketer = UsageBucketer()
    /// Последний замер приложений, больше всех по процессору — первыми.
    private var latestApps: [AppUsage] = []
    private var cpuWindows: [String: SampleWindow] = [:]
    private var memoryWindows: [String: SampleWindow] = [:]
    private var lastSeen: [String: Date] = [:]

    // MARK: Нормы и тревоги
    private var norms: [String: AppNorms] = [:]
    private var drainNorm: UsageNorm?
    private var normsLoadedAt: Date?
    private var overrides: [AlertKey: Double] = [:]
    private var snoozedUntil: [AlertKey: Date] = [:]
    /// Висят в чёлке, старые первыми.
    private var active: [ResourceAlert] = []
    private var lastCleanup: Date?
    /// Если база не записалась, тревога всё равно показывается — с временным отрицательным id.
    private var nextTemporaryId: Int64 = -1
    public private(set) var lastError: String?

    /// Процессы меряются раз в 15 с: пропуск дольше 2 минут — мак спал, окна заново.
    private static let processGap: TimeInterval = 120
    /// Мак меряется раз в 5 с: пропуск дольше минуты — тоже сон.
    private static let systemGap: TimeInterval = 60
    /// Нет в замерах дольше минуты — приложение закрыли.
    private static let goneAfter: TimeInterval = 60
    private static let windowKeep: TimeInterval = 12 * 60
    /// Допуск на шаг замеров при проверке «держится»: процессы — 30 с, мак — 15 с.
    private static let systemSlack: TimeInterval = 15

    public init(
        repository: ResourceRepository,
        rules: ResourceRules = ResourceRules(),
        totalMemory: Double = Double(ProcessInfo.processInfo.physicalMemory),
        now: Date = Date()
    ) {
        self.repository = repository
        self.rules = rules
        self.totalMemory = totalMemory
        restore(now: now)
    }

    // MARK: - Замер мака целиком (раз в 5 с)

    /// Возвращает тревоги, которые появились в этом замере.
    @discardableResult
    public func ingest(system reading: SystemReading, at date: Date) -> [ResourceAlert] {
        if let lastSystemAt, date.timeIntervalSince(lastSystemAt) > Self.systemGap {
            // Мак спал: «держится» начинается заново.
            drainWindow.removeAll()
            pressureWindow.removeAll()
            thermalWindow.removeAll()
            levels.removeAll()
        }
        lastSystemAt = date
        let previous = previousTicks
        previousTicks = reading.cpuTicks
        // Первый замер: проценты процессора считать ещё не по чему.
        guard let previous else { return [] }
        let cpu = CPULoad.percent(from: previous, to: reading.cpuTicks) ?? latestSystem?.cpuPercent ?? 0

        if let memory = reading.memory, memory.totalBytes > 0 { totalMemory = Double(memory.totalBytes) }
        let onBattery = reading.battery.map { !$0.onAC } ?? false
        let drain = drainRate(reading.battery, at: date)
        let snapshot = SystemSnapshot(
            at: date, cpuPercent: cpu, memory: reading.memory, battery: reading.battery,
            drainRate: drain, temperature: reading.temperature, thermal: reading.thermal
        )
        latestSystem = snapshot
        if let minute = minuteBucketer.add(snapshot) {
            attempt { try repository.save(minute) }
            recentMinutes.append(minute)
            recentMinutes.removeAll { date.timeIntervalSince($0.start) > 3_600 }
        }

        // На батарее копим скорость разряда; на зарядке разряда нет.
        if onBattery {
            if let drain { drainWindow.append(drain, at: date) }
        } else {
            drainWindow.removeAll()
        }
        pressureWindow.append(Double(reading.memory?.pressure.rawValue ?? 0), at: date)
        thermalWindow.append(Double(reading.thermal.rawValue), at: date)

        reloadNormsIfNeeded(now: date)
        cleanupIfNeeded(now: date)
        resolveSystemAlerts(now: date)
        return detectSystemAlerts(now: date)
    }

    // MARK: - Замер процессов (раз в 15 с)

    /// Возвращает тревоги, которые появились в этом замере.
    @discardableResult
    public func ingest(processes readings: [ProcessReading], at date: Date) -> [ResourceAlert] {
        let previousAt = lastProcessAt
        let previous = previousProcesses
        previousProcesses = readings
        lastProcessAt = date
        guard let previousAt else { return [] }
        let seconds = date.timeIntervalSince(previousAt)
        guard seconds > 0, seconds <= Self.processGap else {
            // Мак спал: этот замер — новая точка отсчёта.
            startOverAfterGap()
            return []
        }

        let usage = AppUsageAggregator.usage(previous: previous, current: readings, seconds: seconds)
        latestApps = usage.sorted { $0.cpuPercent > $1.cpuPercent }
        let finished = usageBucketer.add(usage, at: date).filter { !Self.isDust($0) }
        if !finished.isEmpty { attempt { try repository.save(finished) } }
        for item in usage {
            let key = item.app.key
            cpuWindows[key, default: SampleWindow(keep: Self.windowKeep)].append(item.cpuPercent, at: date)
            memoryWindows[key, default: SampleWindow(keep: Self.windowKeep)].append(Double(item.memoryBytes), at: date)
            lastSeen[key] = date
        }

        reloadNormsIfNeeded(now: date)
        resolveAppAlerts(now: date)
        forgetGoneApps(now: date)
        return detectAppAlerts(usage, now: date)
    }

    // MARK: - Ответ на тревогу

    /// «Позже» — тревога уходит, пауза остаётся. «Это нормально» — ещё и поднимает
    /// норму (для давления и нагрева уровня нет — тогда молчим сутки).
    public func respond(to alertId: Int64, with status: AlertStatus, at now: Date) {
        guard let alert = active.first(where: { $0.id == alertId }) else { return }
        if status == .normal {
            if Self.hasLevel(alert.kind) {
                overrides[alert.key] = max(overrides[alert.key] ?? 0, alert.value)
                attempt { try repository.setOverride(kind: alert.kind, appKey: alert.app?.key, level: alert.value, at: now) }
            } else {
                snoozedUntil[alert.key] = max(snoozedUntil[alert.key] ?? .distantPast, now.addingTimeInterval(rules.levelSnooze))
            }
        }
        close(alert, as: status, at: now)
    }

    /// Прочитать нормы из базы заново. Само — раз в час.
    public func reloadNorms(now: Date) {
        normsLoadedAt = now
        let since = now.addingTimeInterval(-rules.normWindow)
        attempt {
            norms = try repository.appNorms(since: since, minimumSamples: rules.appNormMinimumSamples, minimumDays: rules.appNormMinimumDays)
            drainNorm = try repository.drainNorm(since: since, minimumSamples: rules.drainNormMinimumSamples, minimumDays: rules.drainNormMinimumDays)
        }
    }

    /// Дописать незаконченные пятиминутку и минуту (перед выходом).
    public func flush() {
        let buckets = usageBucketer.flush().filter { !Self.isDust($0) }
        if !buckets.isEmpty { attempt { try repository.save(buckets) } }
        if let minute = minuteBucketer.flush() { attempt { try repository.save(minute) } }
    }

    /// Всё для интерфейса: мак сейчас, лидеры среди приложений с нормами, час истории, тревоги.
    public func state(newAlerts: [ResourceAlert] = []) -> ResourceState {
        var history = recentMinutes
        if let current = minuteBucketer.current, history.last?.start != current.start {
            history.append(current)
        }
        let apps = Self.leaders(latestApps).map { usage in
            let norm = norms[usage.app.key]
            return AppUsageRow(
                usage: usage, usualCPU: Self.reliable(norm?.cpu),
                usualMemory: Self.reliable(norm?.memory), usualPower: Self.reliable(norm?.power)
            )
        }
        return ResourceState(
            system: latestSystem, apps: apps, history: history, alerts: active, newAlerts: newAlerts,
            normsCount: norms.values.filter(\.cpu.isReliable).count, lastError: lastError
        )
    }

    // MARK: - Тревоги про приложения

    private func detectAppAlerts(_ usage: [AppUsage], now: Date) -> [ResourceAlert] {
        var created: [ResourceAlert] = []
        for item in usage {
            let key = item.app.key
            let norm = norms[key]

            let cpuKey = AlertKey(kind: .cpu, appKey: key)
            if canAlert(cpuKey, now: now), let window = cpuWindows[key] {
                let usual = Self.reliable(norm?.cpu)
                for threshold in rules.cpu(norm: norm?.cpu, override: overrides[cpuKey])
                where window.isSustained(above: threshold.value, for: threshold.duration, now: now) {
                    let value = window.average(last: threshold.duration, now: now) ?? item.cpuPercent
                    created.append(record(
                        kind: .cpu, app: item.app, value: value, usual: usual, sustained: threshold.duration,
                        title: ResourcePhrase.cpu(app: item.app.name, percent: value, usual: usual), detail: nil, now: now
                    ))
                    break
                }
            }

            let memoryKey = AlertKey(kind: .memory, appKey: key)
            if canAlert(memoryKey, now: now), let window = memoryWindows[key] {
                let threshold = rules.memory(norm: norm?.memory, totalBytes: totalMemory, override: overrides[memoryKey])
                if window.isSustained(above: threshold.value, for: threshold.duration, now: now) {
                    let value = window.average(last: threshold.duration, now: now) ?? Double(item.memoryBytes)
                    let usual = Self.reliable(norm?.memory)
                    created.append(record(
                        kind: .memory, app: item.app, value: value, usual: usual, sustained: threshold.duration,
                        title: ResourcePhrase.memory(app: item.app.name, bytes: value, usual: usual, totalBytes: totalMemory),
                        detail: nil, now: now
                    ))
                }
            }
        }
        return created
    }

    /// Прошло само: 2 минуты ниже 80% порога или приложение закрыли.
    private func resolveAppAlerts(now: Date) {
        for alert in active where !alert.kind.isSystemWide {
            guard let app = alert.app else { continue }
            let gone: Bool
            if let seen = lastSeen[app.key], now.timeIntervalSince(seen) <= Self.goneAfter {
                let norm = norms[app.key]
                switch alert.kind {
                case .cpu:
                    let lowest = rules.cpu(norm: norm?.cpu, override: overrides[alert.key]).map(\.value).min() ?? 0
                    gone = cpuWindows[app.key]?.isSustained(below: lowest * rules.resolveFactor, for: rules.resolveSustain, now: now) ?? true
                case .memory:
                    let threshold = rules.memory(norm: norm?.memory, totalBytes: totalMemory, override: overrides[alert.key])
                    gone = memoryWindows[app.key]?.isSustained(below: threshold.value * rules.resolveFactor, for: rules.resolveSustain, now: now) ?? true
                case .battery, .pressure, .thermal:
                    gone = false
                }
            } else {
                gone = true
            }
            if gone { close(alert, as: .resolved, at: now) }
        }
    }

    // MARK: - Тревоги про мак целиком

    private func detectSystemAlerts(now: Date) -> [ResourceAlert] {
        var created: [ResourceAlert] = []

        let drainKey = AlertKey(kind: .battery, appKey: nil)
        let drain = rules.drain(norm: drainNorm, override: overrides[drainKey])
        if canAlert(drainKey, now: now),
           drainWindow.isSustained(above: drain.value, for: drain.duration, now: now, slack: Self.systemSlack),
           let rate = drainWindow.average(last: drain.duration, now: now) {
            let usual = Self.reliable(drainNorm)
            // Кто ест батарею: по энергии, а если её не узнать — по процессору.
            let culprit = topApp { $0.powerWatts } ?? topApp { $0.cpuPercent }
            created.append(record(
                kind: .battery, app: nil, value: rate, usual: usual, sustained: drain.duration,
                title: ResourcePhrase.battery(rate: rate, usual: usual),
                detail: ResourcePhrase.culprit(for: .battery, app: culprit), now: now
            ))
        }

        // Уровни: 2 — «не хватает» и «горячо»; порог посередине прощает один замер «впритык».
        let pressureKey = AlertKey(kind: .pressure, appKey: nil)
        if canAlert(pressureKey, now: now),
           pressureWindow.isSustained(above: 1.5, for: rules.pressureSustain, now: now, slack: Self.systemSlack) {
            created.append(record(
                kind: .pressure, app: nil, value: Double(MemoryPressure.critical.rawValue), usual: nil, sustained: rules.pressureSustain,
                title: ResourcePhrase.pressure(),
                detail: ResourcePhrase.culprit(for: .pressure, app: topApp { Double($0.memoryBytes) }), now: now
            ))
        }

        let thermalKey = AlertKey(kind: .thermal, appKey: nil)
        if canAlert(thermalKey, now: now),
           thermalWindow.isSustained(above: 1.5, for: rules.thermalSustain, now: now, slack: Self.systemSlack) {
            created.append(record(
                kind: .thermal, app: nil, value: thermalWindow.latest ?? 2, usual: nil, sustained: rules.thermalSustain,
                title: ResourcePhrase.thermal(temperature: latestSystem?.temperature),
                detail: ResourcePhrase.culprit(for: .thermal, app: topApp { $0.cpuPercent }), now: now
            ))
        }
        return created
    }

    private func resolveSystemAlerts(now: Date) {
        for alert in active where alert.kind.isSystemWide {
            let gone: Bool
            switch alert.kind {
            case .battery:
                // Подключил зарядку — разряда нет.
                let plugged = latestSystem?.battery.map(\.onAC) ?? true
                let drain = rules.drain(norm: drainNorm, override: overrides[alert.key])
                gone = plugged || drainWindow.isSustained(below: drain.value * rules.resolveFactor, for: rules.resolveSustain, now: now, slack: Self.systemSlack)
            case .pressure:
                gone = pressureWindow.isSustained(below: 1.5, for: rules.resolveSustain, now: now, slack: Self.systemSlack)
            case .thermal:
                gone = thermalWindow.isSustained(below: 1.5, for: rules.resolveSustain, now: now, slack: Self.systemSlack)
            case .cpu, .memory:
                gone = false
            }
            if gone { close(alert, as: .resolved, at: now) }
        }
    }

    // MARK: - Внутреннее

    /// Нет такой же активной тревоги и прошла пауза после прошлой.
    private func canAlert(_ key: AlertKey, now: Date) -> Bool {
        guard !active.contains(where: { $0.key == key }) else { return false }
        return snoozedUntil[key].map { now >= $0 } ?? true
    }

    private func record(kind: ResourceKind, app: AppIdentity?, value: Double, usual: Double?, sustained: TimeInterval, title: String, detail: String?, now: Date) -> ResourceAlert {
        let draft = ResourceAlert(
            id: 0, kind: kind, app: app, value: value, usual: usual, startedAt: now.addingTimeInterval(-sustained),
            createdAt: now, title: title, detail: detail, status: .active, statusChangedAt: nil
        )
        var alert: ResourceAlert
        do {
            alert = try repository.insert(draft)
        } catch {
            lastError = L("Тревога не записалась: ", "Couldn’t save the alert: ") + "\(error)"
            alert = ResourceAlert(
                id: nextTemporaryId, kind: kind, app: app, value: value, usual: usual, startedAt: draft.startedAt,
                createdAt: now, title: title, detail: detail, status: .active, statusChangedAt: nil
            )
            nextTemporaryId -= 1
        }
        snoozedUntil[alert.key] = now.addingTimeInterval(rules.snooze)
        active.append(alert)
        return alert
    }

    private func close(_ alert: ResourceAlert, as status: AlertStatus, at now: Date) {
        active.removeAll { $0.id == alert.id }
        if alert.id > 0 {
            attempt { try repository.setStatus(status, alertId: alert.id, at: now) }
        }
    }

    /// Разряд, % в час: по току, а если тока нет — по снижению заряда за 20 минут.
    private func drainRate(_ battery: BatteryReading?, at date: Date) -> Double? {
        guard let battery, !battery.onAC else {
            levels.removeAll()
            return nil
        }
        levels.append((date, battery.level))
        levels.removeAll { date.timeIntervalSince($0.at) > 20 * 60 }
        return BatteryMath.drainRate(amperage: battery.amperage, capacityMah: battery.capacityMah)
            ?? BatteryMath.drainRate(levels: levels)
    }

    private func topApp(_ value: (AppUsage) -> Double) -> AppUsage? {
        guard let top = latestApps.max(by: { value($0) < value($1) }), value(top) > 0 else { return nil }
        return top
    }

    /// Мак проснулся: окна и пятиминутка начинаются заново, недописанное — в базу.
    private func startOverAfterGap() {
        let partial = usageBucketer.flush().filter { !Self.isDust($0) }
        if !partial.isEmpty { attempt { try repository.save(partial) } }
        cpuWindows.removeAll()
        memoryWindows.removeAll()
    }

    /// Закрытые давно приложения — из памяти вон.
    private func forgetGoneApps(now: Date) {
        let gone = lastSeen.filter { now.timeIntervalSince($0.value) > 2 * Self.goneAfter }.map(\.key)
        for key in gone {
            lastSeen[key] = nil
            cpuWindows[key] = nil
            memoryWindows[key] = nil
        }
    }

    /// После перезапуска: график за час, «это нормально», паузы и свежие тревоги.
    /// Активные тревоги старше часа закрываем: что бы там ни было, это уже не новость.
    private func restore(now: Date) {
        attempt {
            recentMinutes = try repository.minutes(since: now.addingTimeInterval(-3_600))
            overrides = try repository.overrides()
            try repository.closeActiveAlerts(olderThan: now.addingTimeInterval(-3_600), at: now)
            for alert in try repository.alerts(since: now.addingTimeInterval(-rules.levelSnooze)) {
                extendSnooze(for: alert)
                if alert.status == .active { active.append(alert) }
            }
        }
    }

    private func extendSnooze(for alert: ResourceAlert) {
        var until = alert.createdAt.addingTimeInterval(rules.snooze)
        if alert.status == .normal, !Self.hasLevel(alert.kind), let changed = alert.statusChangedAt {
            until = max(until, changed.addingTimeInterval(rules.levelSnooze))
        }
        snoozedUntil[alert.key] = max(snoozedUntil[alert.key] ?? .distantPast, until)
    }

    private func reloadNormsIfNeeded(now: Date) {
        if let normsLoadedAt, now.timeIntervalSince(normsLoadedAt) < 3_600 { return }
        reloadNorms(now: now)
    }

    /// Раз в 6 часов: сводки старше 8 дней и тревоги старше 60 — из базы вон.
    private func cleanupIfNeeded(now: Date) {
        if let lastCleanup, now.timeIntervalSince(lastCleanup) < 6 * 3_600 { return }
        lastCleanup = now
        attempt {
            try repository.deleteOlderThan(
                usage: now.addingTimeInterval(-Double(ResourceRepository.usageRetentionDays) * 86_400),
                alerts: now.addingTimeInterval(-Double(ResourceRepository.alertRetentionDays) * 86_400)
            )
        }
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lastError = L("Ресурсы не записались: ", "Couldn’t save resource data: ") + "\(error)"
        }
    }

    /// Мелочь (cfprefsd и т. п.) в базу не пишем: тревожить о ней не из-за чего.
    private static func isDust(_ bucket: AppUsageBucket) -> Bool {
        bucket.cpuMax < 0.5 && bucket.memoryMax < 50 * 1_048_576 && bucket.powerAvg < 0.05
    }

    /// Для процессора, памяти и батареи «это нормально» поднимает порог; у давления и нагрева уровня нет.
    private static func hasLevel(_ kind: ResourceKind) -> Bool {
        kind == .cpu || kind == .memory || kind == .battery
    }

    /// Интерфейсу хватает лидеров: по 12 приложений на каждую величину, а не все
    /// 400 групп процессов мака. Порядок — по процессору, как в `latestApps`.
    static let leadersPerMetric = 12

    private static func leaders(_ apps: [AppUsage]) -> [AppUsage] {
        var keys = Set<String>()
        for metric in [{ (app: AppUsage) in app.cpuPercent }, { Double($0.memoryBytes) }, { $0.powerWatts }] {
            keys.formUnion(apps.sorted { metric($0) > metric($1) }.prefix(leadersPerMetric).map(\.app.key))
        }
        return apps.filter { keys.contains($0.app.key) }
    }

    private static func reliable(_ norm: UsageNorm?) -> Double? {
        guard let norm, norm.isReliable else { return nil }
        return norm.median
    }
}
