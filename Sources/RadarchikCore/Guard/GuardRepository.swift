import Foundation

/// О чём запись в журнале «Защиты».
public enum GuardEventKind: String, Sendable {
    /// Подозрительный процесс.
    case process
    /// Проверка кода после git pull.
    case code
    /// Настройки Claude Code.
    case audit
    /// Ключи: открыты слишком долго, новый незакрытый ключ.
    case keys
    /// SSH-ключом воспользовались через посредника: кто и для чего (`SSHAgentRelay`).
    case agent
    /// Скрипт или инструмент агента вышел в сеть на новый адрес (`NetworkRules`).
    case network
}

/// Что стало с записью.
public enum GuardEventStatus: String, Sendable {
    /// Висит в чёлке и ждёт ответа.
    case active
    /// «Убить».
    case killed
    /// «Один раз» — до следующего такого же запуска.
    case allowedOnce
    /// «Всегда» — ключ записан в список разрешённых.
    case allowedAlways
    /// «Понятно».
    case dismissed
    /// Прошло само: процесс завершился до ответа.
    case resolved
    /// Просто запись: тревожить не о чем (чистая проверка, мелочь).
    case logged
}

public struct GuardEvent: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let kind: GuardEventKind
    public let level: GuardLevel
    public let at: Date
    /// Фраза Радарчика, без секретов.
    public let title: String
    /// Командная строка или «файл:строка — кусок кода», без секретов.
    public let detail: String?
    /// Для «Разрешать всегда» (только у процессов).
    public let allowKey: String?
    public var status: GuardEventStatus
    public var statusChangedAt: Date?

    public init(
        id: Int64, kind: GuardEventKind, level: GuardLevel, at: Date, title: String, detail: String?, allowKey: String?,
        status: GuardEventStatus, statusChangedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.level = level
        self.at = at
        self.title = title
        self.detail = detail
        self.allowKey = allowKey
        self.status = status
        self.statusChangedAt = statusChangedAt
    }
}

/// Журнал «Защиты» в SQLite (схема v5): что заметил Радарчик и что ты ответил,
/// и список «разрешать всегда». Своё соединение; в приложении живёт внутри
/// фонового актора (`GuardWorker`), а проверка кода из git-хука пишет сюда же
/// из своего процесса — SQLite подождёт (`busy_timeout`).
public final class GuardRepository {
    /// Как у тревог ресурсов: видно, что было и что ты ответил.
    public static let retentionDays = 60

    private let db: Database

    public init(database: Database) throws {
        self.db = database
        try DatabaseSchema.migrate(database)
    }

    @discardableResult
    public func add(
        kind: GuardEventKind, level: GuardLevel, at: Date, title: String, detail: String?, allowKey: String?,
        status: GuardEventStatus = .active
    ) throws -> GuardEvent {
        try db.run(
            "INSERT INTO guard_events (kind, level, at, title, detail, allow_key, status) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [.text(kind.rawValue), .text(level.rawValue), .real(at.timeIntervalSince1970), .text(title), Self.text(detail), Self.text(allowKey), .text(status.rawValue)]
        )
        return GuardEvent(
            id: db.lastInsertRowId, kind: kind, level: level, at: at, title: title, detail: detail, allowKey: allowKey,
            status: status, statusChangedAt: nil
        )
    }

    public func setStatus(_ id: Int64, _ status: GuardEventStatus, at: Date) throws {
        try db.run(
            "UPDATE guard_events SET status = ?, status_changed_at = ? WHERE id = ?",
            [.text(status.rawValue), .real(at.timeIntervalSince1970), .integer(id)]
        )
    }

    public func event(_ id: Int64) throws -> GuardEvent? {
        try db.query("SELECT \(Self.columns) FROM guard_events WHERE id = ?", [.integer(id)], map: Self.event).first
    }

    /// Начиная с `date`, новые первыми — журнал на экране «Защита».
    public func events(since date: Date) throws -> [GuardEvent] {
        try db.query("SELECT \(Self.columns) FROM guard_events WHERE at >= ? ORDER BY at DESC, id DESC", [.real(date.timeIntervalSince1970)], map: Self.event)
    }

    /// Ждут ответа, старые первыми: показываем по одной.
    public func active() throws -> [GuardEvent] {
        try db.query("SELECT \(Self.columns) FROM guard_events WHERE status = 'active' ORDER BY at, id", map: Self.event)
    }

    /// Когда последний раз замечали то же самое — чтобы не повторять одно и то же.
    public func lastSeen(_ allowKey: String) throws -> Date? {
        try db.query("SELECT MAX(at) FROM guard_events WHERE allow_key = ?", [.text(allowKey)]) { row in
            row.isNull(0) ? nil : Date(timeIntervalSince1970: row.double(0))
        }.first ?? nil
    }

    // MARK: - «Разрешать всегда»

    public func allow(_ key: String, at: Date) throws {
        try db.run("INSERT OR IGNORE INTO guard_allowed (allow_key, created_at) VALUES (?, ?)", [.text(key), .real(at.timeIntervalSince1970)])
    }

    public func disallow(_ key: String) throws {
        try db.run("DELETE FROM guard_allowed WHERE allow_key = ?", [.text(key)])
    }

    public func isAllowed(_ key: String) throws -> Bool {
        try db.query("SELECT 1 FROM guard_allowed WHERE allow_key = ?", [.text(key)]) { _ in true }.first ?? false
    }

    public func allowedKeys() throws -> Set<String> {
        Set(try db.query("SELECT allow_key FROM guard_allowed") { $0.text(0) ?? "" })
    }

    /// Старше `retentionDays` — удалить.
    public func purge(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        try db.run("DELETE FROM guard_events WHERE at < ?", [.real(cutoff.timeIntervalSince1970)])
        try db.run("DELETE FROM network_seen WHERE last_seen < ?", [.real(cutoff.timeIntervalSince1970)])
    }

    // MARK: - Сеть: кто куда ходил (схема v7)

    /// Видели ли пару «источник → адрес»; nil — впервые.
    public func networkSeen(identity: String, host: String) throws -> NetworkSeen? {
        try db.query("SELECT \(Self.seenColumns) FROM network_seen WHERE identity = ? AND host = ?", [.text(identity), .text(host)], map: Self.seen).first
    }

    /// Отметить соединение: впервые — новая строка, иначе счётчик и время. `level` — как оценили в этот раз.
    public func touchNetworkSeen(identity: String, name: String, host: String, project: String?, level: GuardLevel, at: Date) throws {
        try db.run(
            "INSERT INTO network_seen (identity, name, host, project, first_seen, last_seen, count, level) VALUES (?, ?, ?, ?, ?, ?, 1, ?) "
                + "ON CONFLICT(identity, host) DO UPDATE SET last_seen = excluded.last_seen, count = count + 1, name = excluded.name, "
                + "project = COALESCE(excluded.project, project), level = excluded.level",
            [.text(identity), .text(name), .text(host), Self.text(project), .real(at.timeIntervalSince1970), .real(at.timeIntervalSince1970), .text(level.rawValue)]
        )
    }

    /// Что видели начиная с `date`, свежие первыми — экран «Сеть».
    public func networkSeen(since date: Date) throws -> [NetworkSeen] {
        try db.query("SELECT \(Self.seenColumns) FROM network_seen WHERE last_seen >= ? ORDER BY last_seen DESC", [.real(date.timeIntervalSince1970)], map: Self.seen)
    }

    private static let seenColumns = "identity, name, host, project, first_seen, last_seen, count, level"

    private static func seen(_ row: Row) -> NetworkSeen {
        NetworkSeen(
            identity: row.text(0) ?? "", name: row.text(1) ?? "", host: row.text(2) ?? "", project: row.text(3),
            firstSeen: Date(timeIntervalSince1970: row.double(4)), lastSeen: Date(timeIntervalSince1970: row.double(5)), count: Int(row.int(6)),
            level: GuardLevel(rawValue: row.text(7) ?? "") ?? .info
        )
    }

    // MARK: - Внутреннее

    private static let columns = "id, kind, level, at, title, detail, allow_key, status, status_changed_at"

    private static func event(_ row: Row) -> GuardEvent {
        GuardEvent(
            id: row.int(0),
            kind: GuardEventKind(rawValue: row.text(1) ?? "") ?? .process,
            level: GuardLevel(rawValue: row.text(2) ?? "") ?? .info,
            at: Date(timeIntervalSince1970: row.double(3)),
            title: row.text(4) ?? "",
            detail: row.text(5),
            allowKey: row.text(6),
            status: GuardEventStatus(rawValue: row.text(7) ?? "") ?? .logged,
            statusChangedAt: row.isNull(8) ? nil : Date(timeIntervalSince1970: row.double(8))
        )
    }

    private static func text(_ value: String?) -> Database.Value {
        value.map { .text($0) } ?? .null
    }
}
