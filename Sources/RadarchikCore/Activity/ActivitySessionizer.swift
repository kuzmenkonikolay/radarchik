import Foundation

/// Режет поток снимков экрана на сессии. Новая сессия начинается, когда
/// сменились приложение, окно или страница. Простой, сон и блокировка
/// закрывают текущую (`pause`). Взгляды короче секунды сессиями не считаются.
public struct ActivitySessionizer: Sendable {
    public private(set) var current: ActivitySession?
    public var minimumDuration: TimeInterval = 1
    /// Растёт, когда текущая сессия закрылась или началась новая. По нему
    /// `ActivityRecorder` понимает, что пора дописать прошлую сессию в базу.
    public private(set) var generation = 0

    public init() {}

    /// Новый снимок в момент `moment`; nil — смотреть не на что (приложение из исключений).
    /// Возвращает закрытую сессию, если она была достаточно длинной.
    public mutating func observe(_ snapshot: FocusSnapshot?, at moment: Date) -> ActivitySession? {
        if var session = current, let snapshot, session.matches(snapshot) {
            session.endedAt = max(session.endedAt, moment)
            current = session
            return nil
        }
        let closed = close(at: moment)
        if let snapshot {
            current = ActivitySession(snapshot: snapshot, at: moment)
            generation += 1
        }
        return closed
    }

    /// Простой, сон или блокировка начались в `moment`.
    public mutating func pause(at moment: Date) -> ActivitySession? {
        close(at: moment)
    }

    private mutating func close(at moment: Date) -> ActivitySession? {
        guard var session = current else { return nil }
        current = nil
        generation += 1
        session.endedAt = max(session.startedAt, moment)
        return session.duration >= minimumDuration ? session : nil
    }
}

/// Пишет сессии в базу так, чтобы не дёргать её на каждый взгляд и не
/// терять много при падении:
/// - сессия короче секунды не пишется вовсе;
/// - сессия старше 2 секунд сохраняется сразу;
/// - конец сохранённой сессии обновляется раз в 30 секунд, при падении теряется не больше полуминуты.
public final class ActivityRecorder {
    public static let saveAfter: TimeInterval = 2
    public static let checkpointEvery: TimeInterval = 30

    private var sessionizer = ActivitySessionizer()
    private let repository: ActivityRepository
    /// rowid текущей сессии; nil — она пока только в памяти.
    private var savedId: Int64?
    private var lastSave: Date?

    public init(repository: ActivityRepository) {
        self.repository = repository
    }

    public var current: ActivitySession? { sessionizer.current }

    public func observe(_ snapshot: FocusSnapshot?, at moment: Date) throws {
        let generation = sessionizer.generation
        let closed = sessionizer.observe(snapshot, at: moment)
        if sessionizer.generation != generation {
            try finish(closed)
        }
        try saveCurrentIfNeeded(at: moment)
    }

    public func pause(at moment: Date) throws {
        let generation = sessionizer.generation
        let closed = sessionizer.pause(at: moment)
        if sessionizer.generation != generation {
            try finish(closed)
        }
    }

    /// Прошлая сессия закончилась: дописать конец или сохранить целиком.
    private func finish(_ closed: ActivitySession?) throws {
        defer {
            savedId = nil
            lastSave = nil
        }
        guard let closed else { return }
        if let savedId {
            try repository.updateEnd(sessionId: savedId, endedAt: closed.endedAt)
        } else {
            try repository.insert(closed)
        }
    }

    private func saveCurrentIfNeeded(at moment: Date) throws {
        guard let session = sessionizer.current else { return }
        if let savedId {
            if let lastSave, moment.timeIntervalSince(lastSave) >= Self.checkpointEvery {
                try repository.updateEnd(sessionId: savedId, endedAt: moment)
                self.lastSave = moment
            }
        } else if moment.timeIntervalSince(session.startedAt) >= Self.saveAfter {
            savedId = try repository.insert(session)
            lastSave = moment
        }
    }
}
