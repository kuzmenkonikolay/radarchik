import Foundation

/// Ресурсы мака в SQLite (схема v4): пятиминутки приложений, минуты мака,
/// тревоги и «это нормально». Своё соединение; в приложении живёт внутри
/// фонового актора (`ResourceWorker`), чтобы подсчёт норм не тормозил интерфейс.
public final class ResourceRepository {
    /// Сводки живут 8 дней: нормы считаются за 7.
    public static let usageRetentionDays = 8
    /// Тревоги — 60 дней: по ним видно, что уже было и что ты ответил.
    public static let alertRetentionDays = 60

    private let db: Database

    public init(database: Database) throws {
        self.db = database
        try DatabaseSchema.migrate(database)
    }

    // MARK: - Сводки

    /// Пятиминутки приложений. Та же пятиминутка ещё раз (после перезапуска) заменяет прежнюю.
    public func save(_ buckets: [AppUsageBucket]) throws {
        guard !buckets.isEmpty else { return }
        try db.transaction {
            for bucket in buckets {
                try db.run(
                    """
                    INSERT OR REPLACE INTO app_usage
                        (bucket_start, app_key, app_name, cpu_avg, cpu_max, memory_avg, memory_max, power_avg, samples)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .real(bucket.start.timeIntervalSince1970), .text(bucket.app.key), .text(bucket.app.name),
                        .real(bucket.cpuAvg), .real(bucket.cpuMax), .real(bucket.memoryAvg), .real(bucket.memoryMax),
                        .real(bucket.powerAvg), .integer(Int64(bucket.samples)),
                    ]
                )
            }
        }
    }

    public func save(_ minute: SystemMinute) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO system_usage
                (minute_start, cpu, memory_used, memory_pressure, battery_level, on_battery, drain_rate, temperature, thermal_state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .real(minute.start.timeIntervalSince1970), .real(minute.cpu), Self.optional(minute.memoryUsed),
                .integer(Int64(minute.pressure.rawValue)), Self.optional(minute.batteryLevel), .integer(minute.onBattery ? 1 : 0),
                Self.optional(minute.drainRate), Self.optional(minute.temperature), .integer(Int64(minute.thermal.rawValue)),
            ]
        )
    }

    /// Минуты мака начиная с `date` — график за час после перезапуска.
    public func minutes(since date: Date) throws -> [SystemMinute] {
        try db.query(
            """
            SELECT minute_start, cpu, memory_used, memory_pressure, battery_level, on_battery, drain_rate, temperature, thermal_state
            FROM system_usage WHERE minute_start >= ? ORDER BY minute_start
            """,
            [.real(date.timeIntervalSince1970)]
        ) { row in
            SystemMinute(
                start: Date(timeIntervalSince1970: row.double(0)), cpu: row.double(1),
                memoryUsed: row.isNull(2) ? nil : row.double(2),
                pressure: MemoryPressure(rawValue: Int(row.int(3))) ?? .normal,
                batteryLevel: row.isNull(4) ? nil : row.double(4), onBattery: row.int(5) != 0,
                drainRate: row.isNull(6) ? nil : row.double(6), temperature: row.isNull(7) ? nil : row.double(7),
                thermal: ThermalLevel(rawValue: Int(row.int(8))) ?? .nominal
            )
        }
    }

    // MARK: - Нормы

    /// Нормы приложений: медиана и p95 по пятиминуткам начиная с `date`.
    /// Дни считаются по UTC: здесь важно лишь, что данные не из одного дня.
    public func appNorms(since date: Date, minimumSamples: Int, minimumDays: Int) throws -> [String: AppNorms] {
        let rows = try db.query(
            "SELECT app_key, bucket_start, cpu_avg, memory_avg, power_avg FROM app_usage WHERE bucket_start >= ?",
            [.real(date.timeIntervalSince1970)]
        ) { row in
            (key: row.text(0) ?? "", start: row.double(1), cpu: row.double(2), memory: row.double(3), power: row.double(4))
        }
        var grouped: [String: (cpu: [Double], memory: [Double], power: [Double], days: Set<Int>)] = [:]
        for row in rows {
            var entry = grouped[row.key] ?? ([], [], [], [])
            entry.cpu.append(row.cpu)
            entry.memory.append(row.memory)
            entry.power.append(row.power)
            entry.days.insert(Int(row.start / 86_400))
            grouped[row.key] = entry
        }
        var norms: [String: AppNorms] = [:]
        for (key, entry) in grouped {
            let days = entry.days.count
            guard let cpu = UsageNorm(values: entry.cpu, days: days, minimumSamples: minimumSamples, minimumDays: minimumDays),
                  let memory = UsageNorm(values: entry.memory, days: days, minimumSamples: minimumSamples, minimumDays: minimumDays),
                  let power = UsageNorm(values: entry.power, days: days, minimumSamples: minimumSamples, minimumDays: minimumDays)
            else { continue }
            norms[key] = AppNorms(cpu: cpu, memory: memory, power: power)
        }
        return norms
    }

    /// Обычная скорость разряда: минуты на батарее начиная с `date`.
    public func drainNorm(since date: Date, minimumSamples: Int, minimumDays: Int) throws -> UsageNorm? {
        let rows = try db.query(
            "SELECT minute_start, drain_rate FROM system_usage WHERE minute_start >= ? AND on_battery = 1 AND drain_rate IS NOT NULL",
            [.real(date.timeIntervalSince1970)]
        ) { row in (start: row.double(0), rate: row.double(1)) }
        let days = Set(rows.map { Int($0.start / 86_400) }).count
        return UsageNorm(values: rows.map(\.rate), days: days, minimumSamples: minimumSamples, minimumDays: minimumDays)
    }

    // MARK: - Тревоги

    /// Сохраняет тревогу и возвращает её с настоящим id.
    public func insert(_ alert: ResourceAlert) throws -> ResourceAlert {
        try db.run(
            """
            INSERT INTO resource_alerts (kind, app_key, app_name, value, usual, started_at, created_at, title, detail, status, status_changed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(alert.kind.rawValue), Self.optional(alert.app?.key), Self.optional(alert.app?.name),
                .real(alert.value), Self.optional(alert.usual), .real(alert.startedAt.timeIntervalSince1970),
                .real(alert.createdAt.timeIntervalSince1970), .text(alert.title), Self.optional(alert.detail),
                .text(alert.status.rawValue), Self.optional(alert.statusChangedAt?.timeIntervalSince1970),
            ]
        )
        return ResourceAlert(
            id: db.lastInsertRowId, kind: alert.kind, app: alert.app, value: alert.value, usual: alert.usual,
            startedAt: alert.startedAt, createdAt: alert.createdAt, title: alert.title, detail: alert.detail,
            status: alert.status, statusChangedAt: alert.statusChangedAt
        )
    }

    public func setStatus(_ status: AlertStatus, alertId: Int64, at moment: Date) throws {
        try db.run(
            "UPDATE resource_alerts SET status = ?, status_changed_at = ? WHERE id = ?",
            [.text(status.rawValue), .real(moment.timeIntervalSince1970), .integer(alertId)]
        )
    }

    /// Закрыть забытые активные тревоги (приложение перезапускали, мак спал).
    public func closeActiveAlerts(olderThan date: Date, at moment: Date) throws {
        try db.run(
            "UPDATE resource_alerts SET status = ?, status_changed_at = ? WHERE status = ? AND created_at < ?",
            [.text(AlertStatus.resolved.rawValue), .real(moment.timeIntervalSince1970), .text(AlertStatus.active.rawValue), .real(date.timeIntervalSince1970)]
        )
    }

    /// Тревоги начиная с `date`, старые первыми.
    public func alerts(since date: Date) throws -> [ResourceAlert] {
        try db.query(
            """
            SELECT id, kind, app_key, app_name, value, usual, started_at, created_at, title, detail, status, status_changed_at
            FROM resource_alerts WHERE created_at >= ? ORDER BY created_at, id
            """,
            [.real(date.timeIntervalSince1970)]
        ) { row in
            let app = row.text(2).map { AppIdentity(key: $0, name: row.text(3) ?? $0) }
            return ResourceAlert(
                id: row.int(0), kind: ResourceKind(rawValue: row.text(1) ?? "") ?? .cpu, app: app,
                value: row.double(4), usual: row.isNull(5) ? nil : row.double(5),
                startedAt: Date(timeIntervalSince1970: row.double(6)), createdAt: Date(timeIntervalSince1970: row.double(7)),
                title: row.text(8) ?? "", detail: row.text(9), status: AlertStatus(rawValue: row.text(10) ?? "") ?? .resolved,
                statusChangedAt: row.isNull(11) ? nil : Date(timeIntervalSince1970: row.double(11))
            )
        }
    }

    // MARK: - «Это нормально»

    /// Поднимает уровень, ниже которого не тревожим. Опустить его этим нельзя.
    public func setOverride(kind: ResourceKind, appKey: String?, level: Double, at moment: Date) throws {
        try db.run(
            """
            INSERT INTO resource_overrides (kind, app_key, level, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(kind, app_key) DO UPDATE SET level = MAX(level, excluded.level), created_at = excluded.created_at
            """,
            [.text(kind.rawValue), .text(appKey ?? ""), .real(level), .real(moment.timeIntervalSince1970)]
        )
    }

    public func overrides() throws -> [AlertKey: Double] {
        let rows = try db.query("SELECT kind, app_key, level FROM resource_overrides") { row in
            (kind: ResourceKind(rawValue: row.text(0) ?? ""), appKey: row.text(1) ?? "", level: row.double(2))
        }
        var result: [AlertKey: Double] = [:]
        for row in rows {
            guard let kind = row.kind else { continue }
            result[AlertKey(kind: kind, appKey: row.appKey.isEmpty ? nil : row.appKey)] = row.level
        }
        return result
    }

    // MARK: - Срок хранения

    public func deleteOlderThan(usage: Date, alerts: Date) throws {
        try db.transaction {
            try db.run("DELETE FROM app_usage WHERE bucket_start < ?", [.real(usage.timeIntervalSince1970)])
            try db.run("DELETE FROM system_usage WHERE minute_start < ?", [.real(usage.timeIntervalSince1970)])
            try db.run("DELETE FROM resource_alerts WHERE created_at < ?", [.real(alerts.timeIntervalSince1970)])
        }
    }

    private static func optional(_ text: String?) -> Database.Value {
        text.map(Database.Value.text) ?? .null
    }

    private static func optional(_ number: Double?) -> Database.Value {
        number.map(Database.Value.real) ?? .null
    }
}
