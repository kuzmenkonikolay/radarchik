import Foundation

/// Лог наблюдения в SQLite: та же база, что у денег, свои таблицы (схема v2).
/// Отдельное соединение, но тоже с главного потока. Пишется редко (на
/// переключениях и раз в 30 секунд), так что база не мешает интерфейсу.
public final class ActivityRepository {
    /// Сколько дней хранится лог (SPEC §3).
    public static let retentionDays = 30

    private let db: Database

    public init(database: Database) throws {
        self.db = database
        try DatabaseSchema.migrate(database)
    }

    // MARK: - Сессии

    @discardableResult
    public func insert(_ session: ActivitySession) throws -> Int64 {
        try db.run(
            """
            INSERT INTO activity_sessions (bundle_id, app_name, window_title, url, is_private, started_at, ended_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(session.bundleId), .text(session.appName), Self.optional(session.windowTitle),
                Self.optional(session.url), .integer(session.isPrivate ? 1 : 0),
                .real(session.startedAt.timeIntervalSince1970), .real(session.endedAt.timeIntervalSince1970),
            ]
        )
        return db.lastInsertRowId
    }

    public func updateEnd(sessionId: Int64, endedAt: Date) throws {
        try db.run("UPDATE activity_sessions SET ended_at = ? WHERE id = ?", [.real(endedAt.timeIntervalSince1970), .integer(sessionId)])
    }

    /// Сессии, начавшиеся в интервале.
    public func sessions(in range: ClosedRange<Date>) throws -> [ActivitySession] {
        try db.query(
            """
            SELECT id, bundle_id, app_name, window_title, url, is_private, started_at, ended_at
            FROM activity_sessions WHERE started_at BETWEEN ? AND ? ORDER BY started_at
            """,
            Self.bounds(range)
        ) { row in
            ActivitySession(
                id: row.int(0), bundleId: row.text(1) ?? "", appName: row.text(2) ?? "",
                windowTitle: row.text(3), url: row.text(4), isPrivate: row.int(5) != 0,
                startedAt: Date(timeIntervalSince1970: row.double(6)), endedAt: Date(timeIntervalSince1970: row.double(7))
            )
        }
    }

    // MARK: - Команды терминала

    @discardableResult
    public func insert(_ command: ShellCommand) throws -> Int64 {
        try db.run(
            "INSERT INTO shell_commands (command, template, cwd, started_at, duration_ms, exit_code) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(command.command), .text(command.template), Self.optional(command.cwd),
                .real(command.startedAt.timeIntervalSince1970), .integer(command.durationMs), .integer(Int64(command.exitCode)),
            ]
        )
        return db.lastInsertRowId
    }

    public func commands(in range: ClosedRange<Date>) throws -> [ShellCommand] {
        try db.query(
            "SELECT id, command, template, cwd, started_at, duration_ms, exit_code FROM shell_commands WHERE started_at BETWEEN ? AND ? ORDER BY started_at",
            Self.bounds(range)
        ) { row in
            ShellCommand(
                id: row.int(0), command: row.text(1) ?? "", template: row.text(2) ?? "", cwd: row.text(3),
                startedAt: Date(timeIntervalSince1970: row.double(4)), durationMs: row.int(5), exitCode: Int32(truncatingIfNeeded: row.int(6))
            )
        }
    }

    /// Когда пришла последняя команда — на экране настроек видно, что хук работает.
    public func lastCommandDate() throws -> Date? {
        try db.query("SELECT MAX(started_at) FROM shell_commands") { row in
            row.isNull(0) ? nil : Date(timeIntervalSince1970: row.double(0))
        }.first ?? nil
    }

    // MARK: - Копирование

    public func insert(_ paste: PasteEvent) throws -> Int64 {
        try db.run(
            "INSERT INTO paste_events (from_bundle_id, to_bundle_id, at) VALUES (?, ?, ?)",
            [Self.optional(paste.fromBundleId), Self.optional(paste.toBundleId), .real(paste.at.timeIntervalSince1970)]
        )
        return db.lastInsertRowId
    }

    public func updatePasteTarget(id: Int64, toBundleId: String) throws {
        try db.run("UPDATE paste_events SET to_bundle_id = ? WHERE id = ?", [.text(toBundleId), .integer(id)])
    }

    public func pastes(in range: ClosedRange<Date>) throws -> [PasteEvent] {
        try db.query(
            "SELECT id, from_bundle_id, to_bundle_id, at FROM paste_events WHERE at BETWEEN ? AND ? ORDER BY at",
            Self.bounds(range)
        ) { row in
            PasteEvent(id: row.int(0), fromBundleId: row.text(1), toBundleId: row.text(2), at: Date(timeIntervalSince1970: row.double(3)))
        }
    }

    // MARK: - Звонки

    public func insert(_ call: CallSession) throws -> Int64 {
        try db.run(
            "INSERT INTO call_sessions (bundle_id, service, uses_camera, started_at, ended_at) VALUES (?, ?, ?, ?, ?)",
            [
                Self.optional(call.bundleId), Self.optional(call.service), .integer(call.usesCamera ? 1 : 0),
                .real(call.startedAt.timeIntervalSince1970), call.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            ]
        )
        return db.lastInsertRowId
    }

    public func endCall(id: Int64, at moment: Date, usesCamera: Bool? = nil) throws {
        if let usesCamera {
            try db.run("UPDATE call_sessions SET ended_at = ?, uses_camera = ? WHERE id = ?",
                       [.real(moment.timeIntervalSince1970), .integer(usesCamera ? 1 : 0), .integer(id)])
        } else {
            try db.run("UPDATE call_sessions SET ended_at = ? WHERE id = ?", [.real(moment.timeIntervalSince1970), .integer(id)])
        }
    }

    /// Короткое срабатывание микрофона (Siri, диктовка) — не звонок.
    public func deleteCall(id: Int64) throws {
        try db.run("DELETE FROM call_sessions WHERE id = ?", [.integer(id)])
    }

    /// Звонки без конца — от запуска, который убили посреди звонка, когда конец
    /// писался только в самом конце (до 2026-10-19). Сколько они шли, не узнать,
    /// а сводка считала бы их «до сих пор», поэтому при запуске их удаляем.
    /// Теперь идущий звонок раз в минуту отмечает «ещё идёт» в `ended_at`.
    public func deleteDanglingCalls() throws {
        try db.run("DELETE FROM call_sessions WHERE ended_at IS NULL", [])
    }

    public func calls(in range: ClosedRange<Date>) throws -> [CallSession] {
        try db.query(
            "SELECT id, bundle_id, service, uses_camera, started_at, ended_at FROM call_sessions WHERE started_at BETWEEN ? AND ? ORDER BY started_at",
            Self.bounds(range)
        ) { row in
            CallSession(
                id: row.int(0), bundleId: row.text(1), service: row.text(2), usesCamera: row.int(3) != 0,
                startedAt: Date(timeIntervalSince1970: row.double(4)),
                endedAt: row.isNull(5) ? nil : Date(timeIntervalSince1970: row.double(5))
            )
        }
    }

    // MARK: - Запуск и закрытие приложений

    @discardableResult
    public func insert(_ event: AppLifecycleEvent) throws -> Int64 {
        try db.run(
            "INSERT INTO app_events (bundle_id, app_name, kind, at) VALUES (?, ?, ?, ?)",
            [.text(event.bundleId), .text(event.appName), .text(event.kind.rawValue), .real(event.at.timeIntervalSince1970)]
        )
        return db.lastInsertRowId
    }

    public func appEvents(in range: ClosedRange<Date>) throws -> [AppLifecycleEvent] {
        try db.query(
            "SELECT id, bundle_id, app_name, kind, at FROM app_events WHERE at BETWEEN ? AND ? ORDER BY at",
            Self.bounds(range)
        ) { row in
            AppLifecycleEvent(
                id: row.int(0), bundleId: row.text(1) ?? "", appName: row.text(2) ?? "",
                kind: AppLifecycleEvent.Kind(rawValue: row.text(3) ?? "") ?? .running,
                at: Date(timeIntervalSince1970: row.double(4))
            )
        }
    }

    // MARK: - Срок хранения

    /// Удаляет всё старше `date` — запускается при старте и раз в день.
    public func deleteOlderThan(_ date: Date) throws {
        let cutoff = Database.Value.real(date.timeIntervalSince1970)
        try db.transaction {
            try db.run("DELETE FROM activity_sessions WHERE started_at < ?", [cutoff])
            try db.run("DELETE FROM shell_commands WHERE started_at < ?", [cutoff])
            try db.run("DELETE FROM paste_events WHERE at < ?", [cutoff])
            try db.run("DELETE FROM call_sessions WHERE started_at < ?", [cutoff])
            try db.run("DELETE FROM app_events WHERE at < ?", [cutoff])
        }
    }

    // MARK: - Внутреннее

    private static func optional(_ text: String?) -> Database.Value {
        text.map(Database.Value.text) ?? .null
    }

    private static func bounds(_ range: ClosedRange<Date>) -> [Database.Value] {
        [.real(range.lowerBound.timeIntervalSince1970), .real(range.upperBound.timeIntervalSince1970)]
    }
}
