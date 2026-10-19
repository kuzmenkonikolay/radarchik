import Foundation

/// Копит замеры приложений в пятиминутки: в базу идут они, а не каждый замер.
/// Из пятиминуток за неделю считаются нормы (медиана и p95).
/// Границы — по абсолютному времени (…:00, …:05), одинаковые после перезапуска.
public struct UsageBucketer: Sendable {
    public let length: TimeInterval
    private var start: Date?
    private var sums: [String: Accumulator] = [:]

    private struct Accumulator: Sendable {
        var app: AppIdentity
        var cpu = 0.0
        var cpuMax = 0.0
        var memory = 0.0
        var memoryMax = 0.0
        var power = 0.0
        var count = 0
    }

    public init(length: TimeInterval = 300) {
        self.length = length
    }

    /// Добавить замер. Если он уже из новой пятиминутки — вернуть законченную.
    public mutating func add(_ usage: [AppUsage], at date: Date) -> [AppUsageBucket] {
        let bucketStart = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / length).rounded(.down) * length)
        var finished: [AppUsageBucket] = []
        if let start, start != bucketStart {
            finished = flush()
        }
        start = bucketStart
        for item in usage {
            var sum = sums[item.app.key] ?? Accumulator(app: item.app)
            let memory = Double(item.memoryBytes)
            sum.app = item.app
            sum.cpu += item.cpuPercent
            sum.cpuMax = max(sum.cpuMax, item.cpuPercent)
            sum.memory += memory
            sum.memoryMax = max(sum.memoryMax, memory)
            sum.power += item.powerWatts
            sum.count += 1
            sums[item.app.key] = sum
        }
        return finished
    }

    /// Отдать незаконченную пятиминутку (перед сном мака или выходом).
    public mutating func flush() -> [AppUsageBucket] {
        defer {
            sums.removeAll()
            start = nil
        }
        guard let start else { return [] }
        return sums.values.filter { $0.count > 0 }.sorted { $0.app.key < $1.app.key }.map { sum in
            let count = Double(sum.count)
            return AppUsageBucket(
                start: start, app: sum.app, cpuAvg: sum.cpu / count, cpuMax: sum.cpuMax,
                memoryAvg: sum.memory / count, memoryMax: sum.memoryMax, powerAvg: sum.power / count, samples: sum.count
            )
        }
    }
}

/// Копит замеры мака целиком в минуты: точки графика за час и норма разряда.
/// Давление памяти и нагрев за минуту — худшие, остальное — среднее.
public struct SystemMinuteBucketer: Sendable {
    private var start: Date?
    private var snapshots: [SystemSnapshot] = []

    public init() {}

    /// Добавить замер. Если началась новая минута — вернуть законченную.
    public mutating func add(_ snapshot: SystemSnapshot) -> SystemMinute? {
        let minuteStart = Date(timeIntervalSince1970: (snapshot.at.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: SystemMinute?
        if let start, start != minuteStart {
            finished = Self.summarize(snapshots, start: start)
            snapshots.removeAll()
        }
        start = minuteStart
        snapshots.append(snapshot)
        return finished
    }

    /// Текущая, ещё не законченная минута — последняя точка графика.
    public var current: SystemMinute? {
        start.flatMap { Self.summarize(snapshots, start: $0) }
    }

    public mutating func flush() -> SystemMinute? {
        defer {
            snapshots.removeAll()
            start = nil
        }
        return current
    }

    private static func summarize(_ snapshots: [SystemSnapshot], start: Date) -> SystemMinute? {
        guard let last = snapshots.last else { return nil }
        let used = snapshots.compactMap { $0.memory.map { Double($0.usedBytes) } }
        let drains = snapshots.compactMap(\.drainRate)
        let temperatures = snapshots.compactMap(\.temperature)
        return SystemMinute(
            start: start,
            cpu: average(snapshots.map(\.cpuPercent)) ?? 0,
            memoryUsed: average(used),
            pressure: snapshots.compactMap { $0.memory?.pressure }.max() ?? .normal,
            batteryLevel: last.battery?.level,
            onBattery: snapshots.allSatisfy { $0.battery.map { !$0.onAC } ?? false },
            drainRate: average(drains),
            temperature: average(temperatures),
            thermal: snapshots.map(\.thermal).max() ?? .nominal
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
