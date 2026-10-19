import Foundation

/// Деньги в SQLite: загрузка всего `Ledger` и запись изменений.
/// Каждая запись сразу уходит в базу, отдельной кнопки «сохранить» нет.
///
/// База: `~/Library/Application Support/Radarchik/radarchik.sqlite`. Схема и миграции —
/// в `DatabaseSchema` (там же таблицы наблюдения).
public final class LedgerRepository {
    private let db: Database

    public init(database: Database) throws {
        self.db = database
        try DatabaseSchema.migrate(database)
    }

    public static func defaultDatabaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = support.appendingPathComponent("Radarchik", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("radarchik.sqlite")
    }

    // MARK: - Чтение

    public func loadLedger() throws -> Ledger {
        let projects = try db.query(
            "SELECT id, name, color_hex, currency, created_at, is_archived FROM projects ORDER BY created_at, rowid"
        ) { row in
            Project(
                id: try Self.uuid(row, 0),
                name: row.text(1) ?? "",
                colorHex: row.text(2) ?? "#5AC8FA",
                currency: Currency(rawValue: row.text(3) ?? "") ?? .rub,
                createdAt: Date(timeIntervalSince1970: row.double(4)),
                isArchived: row.int(5) != 0
            )
        }

        var pricesByCost: [UUID: [PriceChange]] = [:]
        let prices = try db.query(
            "SELECT cost_id, effective_from, amount FROM recurring_cost_prices ORDER BY effective_from"
        ) { row in
            (costId: try Self.uuid(row, 0), price: PriceChange(effectiveFrom: try Self.month(row, 1), amount: row.int(2)))
        }
        for entry in prices {
            pricesByCost[entry.costId, default: []].append(entry.price)
        }

        let recurring = try db.query(
            """
            SELECT id, project_id, name, url, period, start_month, end_month, created_at
            FROM recurring_costs ORDER BY created_at, rowid
            """
        ) { row in
            let id = try Self.uuid(row, 0)
            return RecurringCost(
                id: id,
                projectId: try Self.uuid(row, 1),
                name: row.text(2) ?? "",
                url: row.text(3),
                period: CostPeriod(rawValue: row.text(4) ?? "") ?? .monthly,
                startMonth: try Self.month(row, 5),
                endMonth: row.text(6).flatMap(YearMonth.init(string:)),
                prices: pricesByCost[id] ?? [],
                createdAt: Date(timeIntervalSince1970: row.double(7))
            )
        }

        let oneOffs = try db.query(
            "SELECT id, project_id, name, url, amount, date, created_at FROM one_off_costs ORDER BY date, created_at, rowid"
        ) { row in
            OneOffCost(
                id: try Self.uuid(row, 0),
                projectId: try Self.uuid(row, 1),
                name: row.text(2) ?? "",
                url: row.text(3),
                amount: row.int(4),
                date: try Self.localDate(row, 5),
                createdAt: Date(timeIntervalSince1970: row.double(6))
            )
        }

        let incomes = try db.query(
            "SELECT id, project_id, name, amount, date, created_at FROM incomes ORDER BY date, created_at, rowid"
        ) { row in
            Income(
                id: try Self.uuid(row, 0),
                projectId: try Self.uuid(row, 1),
                name: row.text(2) ?? "",
                amount: row.int(3),
                date: try Self.localDate(row, 4),
                createdAt: Date(timeIntervalSince1970: row.double(5))
            )
        }

        return Ledger(projects: projects, recurringCosts: recurring, oneOffCosts: oneOffs, incomes: incomes)
    }

    // MARK: - Запись
    //
    // Везде upsert (ON CONFLICT DO UPDATE), а не INSERT OR REPLACE: REPLACE
    // удаляет старую строку, и каскад снёс бы все траты проекта.

    public func save(_ project: Project) throws {
        try db.run(
            """
            INSERT INTO projects (id, name, color_hex, currency, created_at, is_archived) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, color_hex = excluded.color_hex, currency = excluded.currency,
                created_at = excluded.created_at, is_archived = excluded.is_archived
            """,
            [
                .text(project.id.uuidString), .text(project.name), .text(project.colorHex),
                .text(project.currency.rawValue), .real(project.createdAt.timeIntervalSince1970),
                .integer(project.isArchived ? 1 : 0),
            ]
        )
    }

    /// Трата и все её цены — одной транзакцией: цены перезаписываются целиком.
    public func save(_ cost: RecurringCost) throws {
        try db.transaction {
            try db.run(
                """
                INSERT INTO recurring_costs (id, project_id, name, url, period, start_month, end_month, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    project_id = excluded.project_id, name = excluded.name, url = excluded.url,
                    period = excluded.period, start_month = excluded.start_month,
                    end_month = excluded.end_month, created_at = excluded.created_at
                """,
                [
                    .text(cost.id.uuidString), .text(cost.projectId.uuidString), .text(cost.name),
                    Self.optionalText(cost.url), .text(cost.period.rawValue), .text(cost.startMonth.stringValue),
                    Self.optionalText(cost.endMonth?.stringValue), .real(cost.createdAt.timeIntervalSince1970),
                ]
            )
            try db.run("DELETE FROM recurring_cost_prices WHERE cost_id = ?", [.text(cost.id.uuidString)])
            for price in cost.prices {
                try db.run(
                    "INSERT INTO recurring_cost_prices (cost_id, effective_from, amount) VALUES (?, ?, ?)",
                    [.text(cost.id.uuidString), .text(price.effectiveFrom.stringValue), .integer(price.amount)]
                )
            }
        }
    }

    public func save(_ cost: OneOffCost) throws {
        try db.run(
            """
            INSERT INTO one_off_costs (id, project_id, name, url, amount, date, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id, name = excluded.name, url = excluded.url,
                amount = excluded.amount, date = excluded.date, created_at = excluded.created_at
            """,
            [
                .text(cost.id.uuidString), .text(cost.projectId.uuidString), .text(cost.name),
                Self.optionalText(cost.url), .integer(cost.amount), .text(cost.date.stringValue),
                .real(cost.createdAt.timeIntervalSince1970),
            ]
        )
    }

    public func save(_ income: Income) throws {
        try db.run(
            """
            INSERT INTO incomes (id, project_id, name, amount, date, created_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id, name = excluded.name, amount = excluded.amount,
                date = excluded.date, created_at = excluded.created_at
            """,
            [
                .text(income.id.uuidString), .text(income.projectId.uuidString), .text(income.name),
                .integer(income.amount), .text(income.date.stringValue), .real(income.createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// Удаляет проект вместе со всеми его тратами и доходами (каскад).
    public func deleteProject(id: UUID) throws {
        try db.run("DELETE FROM projects WHERE id = ?", [.text(id.uuidString)])
    }

    public func deleteRecurringCost(id: UUID) throws {
        try db.run("DELETE FROM recurring_costs WHERE id = ?", [.text(id.uuidString)])
    }

    public func deleteOneOffCost(id: UUID) throws {
        try db.run("DELETE FROM one_off_costs WHERE id = ?", [.text(id.uuidString)])
    }

    public func deleteIncome(id: UUID) throws {
        try db.run("DELETE FROM incomes WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - Разбор значений

    private static func optionalText(_ value: String?) -> Database.Value {
        value.map(Database.Value.text) ?? .null
    }

    private static func uuid(_ row: Row, _ column: Int32) throws -> UUID {
        guard let text = row.text(column), let id = UUID(uuidString: text) else {
            throw Database.Failure(message: L("В базе битый id: ", "Broken id in the database: ") + (row.text(column) ?? "NULL"))
        }
        return id
    }

    private static func month(_ row: Row, _ column: Int32) throws -> YearMonth {
        guard let text = row.text(column), let month = YearMonth(string: text) else {
            throw Database.Failure(message: L("В базе битый месяц: ", "Broken month in the database: ") + (row.text(column) ?? "NULL"))
        }
        return month
    }

    private static func localDate(_ row: Row, _ column: Int32) throws -> LocalDate {
        guard let text = row.text(column), let date = LocalDate(string: text) else {
            throw Database.Failure(message: L("В базе битая дата: ", "Broken date in the database: ") + (row.text(column) ?? "NULL"))
        }
        return date
    }
}
