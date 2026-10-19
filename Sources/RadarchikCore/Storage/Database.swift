import Foundation
import SQLite3

/// Тонкая обёртка над системным SQLite — без сторонних библиотек.
///
/// Одно соединение — с одного потока: деньги, наблюдение и советы работают
/// с главного (`@MainActor`), ресурсы мака — из фонового актора (`ResourceWorker`),
/// у каждого своё соединение с той же базой. Писать одновременно SQLite не даёт,
/// поэтому соединение ждёт до 3 секунд, пока другое допишет (`busy_timeout`),
/// а не падает сразу с «database is locked». Записи короткие — ждать приходится миллисекунды.
public final class Database {
    /// Значение для параметра `?` в запросе.
    public enum Value {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    private var handle: OpaquePointer?

    /// `path` — файл базы или ":memory:" для тестов.
    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw Failure(message: L("Не удалось открыть базу \(path): \(message)", "Couldn’t open the database \(path): \(message)"))
        }
        // Внешние ключи в SQLite по умолчанию выключены — без них не работает
        // каскадное удаление трат вместе с проектом.
        try execute("PRAGMA foreign_keys = ON")
        // Другое соединение пишет — подождать, а не упасть (см. описание класса).
        sqlite3_busy_timeout(handle, 3_000)
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Одна или несколько SQL-команд без параметров (схема, PRAGMA).
    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// Одна команда с параметрами `?` (INSERT, UPDATE, DELETE).
    public func run(_ sql: String, _ parameters: [Value] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw Failure(message: "\(lastErrorMessage) — \(sql)")
        }
    }

    /// Запрос: каждая строка превращается в `T` через `map`.
    public func query<T>(_ sql: String, _ parameters: [Value] = [], map: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try map(Row(statement: statement)))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw Failure(message: "\(lastErrorMessage) — \(sql)")
            }
        }
    }

    /// Всё или ничего: при ошибке внутри `body` изменения откатываются.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// rowid последней вставленной строки (для таблиц с INTEGER PRIMARY KEY).
    public var lastInsertRowId: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Номер версии схемы (PRAGMA user_version) — по нему идут миграции.
    public func userVersion() throws -> Int {
        try query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Внутреннее

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: "\(lastErrorMessage) — \(sql)")
        }
        // SQLITE_TRANSIENT: SQLite сам копирует строку, Swift-строку можно отпустить.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch parameter {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transient)
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw Failure(message: "\(lastErrorMessage) — \(sql)")
            }
        }
        return statement
    }
}

/// Строка результата. Живёт только внутри `query { ... }`.
public struct Row {
    fileprivate let statement: OpaquePointer

    public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    public func text(_ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
    public func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
}
