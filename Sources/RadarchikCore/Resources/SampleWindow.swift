import Foundation

/// Недавние значения одной величины (CPU приложения, разряд батареи…):
/// по ним решается, **держится** ли превышение, а не мелькнуло на секунду.
///
/// «Держится» прощает короткие провалы: достаточно, чтобы 80% замеров за окно
/// были выше порога и среднее тоже. Но окно должно быть покрыто замерами:
/// если смотрим всего три минуты, «дольше пяти минут» ещё не наступило.
public struct SampleWindow: Sendable {
    public struct Point: Sendable, Equatable {
        public let at: Date
        public let value: Double
    }

    public private(set) var points: [Point] = []
    /// Сколько секунд истории хранить (чуть больше самого длинного окна).
    public let keep: TimeInterval
    /// Сколько замеров из окна должны быть выше порога.
    public static let requiredShare = 0.8

    public init(keep: TimeInterval) {
        self.keep = keep
    }

    public var latest: Double? { points.last?.value }

    public mutating func append(_ value: Double, at date: Date) {
        points.append(Point(at: date, value: value))
        let cutoff = date.addingTimeInterval(-keep)
        if let firstKept = points.firstIndex(where: { $0.at >= cutoff }), firstKept > 0 {
            points.removeFirst(firstKept)
        }
    }

    public mutating func removeAll() {
        points.removeAll()
    }

    /// Среднее за последние `duration` секунд; nil — замеров нет.
    public func average(last duration: TimeInterval, now: Date) -> Double? {
        let recent = points.filter { $0.at >= now.addingTimeInterval(-duration) }
        guard !recent.isEmpty else { return nil }
        return recent.map(\.value).reduce(0, +) / Double(recent.count)
    }

    /// Выше порога уже `duration` секунд. `slack` — допуск на шаг замеров.
    public func isSustained(above threshold: Double, for duration: TimeInterval, now: Date, slack: TimeInterval = 30) -> Bool {
        holds(for: duration, now: now, slack: slack) { $0 >= threshold }
    }

    /// Ниже порога уже `duration` секунд — превышение прошло.
    public func isSustained(below threshold: Double, for duration: TimeInterval, now: Date, slack: TimeInterval = 30) -> Bool {
        holds(for: duration, now: now, slack: slack) { $0 < threshold }
    }

    private func holds(for duration: TimeInterval, now: Date, slack: TimeInterval, _ passes: (Double) -> Bool) -> Bool {
        let windowStart = now.addingTimeInterval(-duration)
        // Окно покрыто, только если первый замер не позже его начала (с допуском).
        guard let first = points.first, first.at <= windowStart.addingTimeInterval(slack) else { return false }
        let recent = points.filter { $0.at >= windowStart && $0.at <= now }
        guard recent.count >= 3 else { return false }
        let passing = recent.filter { passes($0.value) }.count
        let average = recent.map(\.value).reduce(0, +) / Double(recent.count)
        return Double(passing) / Double(recent.count) >= Self.requiredShare && passes(average)
    }
}
