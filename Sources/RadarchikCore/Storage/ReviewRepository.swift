import Foundation

/// Сохранённый разбор: когда, за какой период, какая модель, что ушло в Claude, сколько стоило.
public struct StoredReview: Hashable, Sendable {
    public let id: Int64
    public let periodStart: Date
    public let periodEnd: Date
    public let createdAt: Date
    public let model: String
    /// Ровно тот текст, что ушёл в Claude, — его видно на экране советов.
    public let prompt: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
}

public struct Tip: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let reviewId: Int64
    public let title: String
    public let observation: String
    public let suggestion: String
    public let effort: String
    public let timeSavedPerWeekMin: Int
    public let toolHint: String?
    public var status: TipStatus
    public let createdAt: Date
}

/// Разборы и советы в SQLite (схема v3). Лог наблюдения живёт 30 дней,
/// а разборы и советы хранятся дольше: по ним Радарчик помнит, от чего ты отказался.
public final class ReviewRepository {
    private let db: Database

    public init(database: Database) throws {
        self.db = database
        try DatabaseSchema.migrate(database)
    }

    /// Разбор и его советы — одной транзакцией.
    public func save(periodStart: Date, periodEnd: Date, createdAt: Date, prompt: String, result: ReviewResult) throws -> (StoredReview, [Tip]) {
        var review: StoredReview?
        var tips: [Tip] = []
        try db.transaction {
            try db.run(
                """
                INSERT INTO daily_reviews (period_start, period_end, created_at, model, prompt, input_tokens, output_tokens, cost_usd)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .real(periodStart.timeIntervalSince1970), .real(periodEnd.timeIntervalSince1970), .real(createdAt.timeIntervalSince1970),
                    .text(result.model), .text(prompt), .integer(Int64(result.inputTokens)), .integer(Int64(result.outputTokens)), .real(result.costUSD),
                ]
            )
            let reviewId = db.lastInsertRowId
            review = StoredReview(
                id: reviewId, periodStart: periodStart, periodEnd: periodEnd, createdAt: createdAt, model: result.model,
                prompt: prompt, inputTokens: result.inputTokens, outputTokens: result.outputTokens, costUSD: result.costUSD
            )
            for tip in result.tips {
                try db.run(
                    """
                    INSERT INTO tips (review_id, title, observation, suggestion, effort, time_saved_per_week_min, tool_hint, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .integer(reviewId), .text(tip.title), .text(tip.observation), .text(tip.suggestion), .text(tip.effort),
                        .integer(Int64(tip.timeSavedPerWeekMin)), tip.toolHint.map(Database.Value.text) ?? .null,
                        .text(TipStatus.new.rawValue), .real(createdAt.timeIntervalSince1970),
                    ]
                )
                tips.append(Tip(
                    id: db.lastInsertRowId, reviewId: reviewId, title: tip.title, observation: tip.observation,
                    suggestion: tip.suggestion, effort: tip.effort, timeSavedPerWeekMin: tip.timeSavedPerWeekMin,
                    toolHint: tip.toolHint, status: .new, createdAt: createdAt
                ))
            }
        }
        return (review!, tips)
    }

    public func latestReview() throws -> StoredReview? {
        try db.query(
            """
            SELECT id, period_start, period_end, created_at, model, prompt, input_tokens, output_tokens, cost_usd
            FROM daily_reviews ORDER BY created_at DESC, id DESC LIMIT 1
            """
        ) { row in
            StoredReview(
                id: row.int(0), periodStart: Date(timeIntervalSince1970: row.double(1)), periodEnd: Date(timeIntervalSince1970: row.double(2)),
                createdAt: Date(timeIntervalSince1970: row.double(3)), model: row.text(4) ?? "", prompt: row.text(5) ?? "",
                inputTokens: Int(row.int(6)), outputTokens: Int(row.int(7)), costUSD: row.double(8)
            )
        }.first
    }

    /// Советы: свежие разборы первыми, внутри разбора — в порядке Claude.
    public func tips(limit: Int = 60) throws -> [Tip] {
        try db.query(
            """
            SELECT id, review_id, title, observation, suggestion, effort, time_saved_per_week_min, tool_hint, status, created_at
            FROM tips ORDER BY created_at DESC, id ASC LIMIT ?
            """,
            [.integer(Int64(limit))]
        ) { row in
            Tip(
                id: row.int(0), reviewId: row.int(1), title: row.text(2) ?? "", observation: row.text(3) ?? "",
                suggestion: row.text(4) ?? "", effort: row.text(5) ?? TipEffort.medium.word, timeSavedPerWeekMin: Int(row.int(6)),
                toolHint: row.text(7), status: TipStatus(rawValue: row.text(8) ?? "") ?? .new,
                createdAt: Date(timeIntervalSince1970: row.double(9))
            )
        }
    }

    public func setStatus(_ status: TipStatus, tipId: Int64, at moment: Date) throws {
        try db.run(
            "UPDATE tips SET status = ?, status_changed_at = ? WHERE id = ?",
            [.text(status.rawValue), .real(moment.timeIntervalSince1970), .integer(tipId)]
        )
    }

    /// Прошлые советы для текста запроса — чтобы Claude не повторялся.
    public func previousTips(since date: Date) throws -> [PreviousTip] {
        try db.query(
            "SELECT title, status FROM tips WHERE created_at >= ? ORDER BY created_at",
            [.real(date.timeIntervalSince1970)]
        ) { row in
            PreviousTip(title: row.text(0) ?? "", status: TipStatus(rawValue: row.text(1) ?? "") ?? .new)
        }
    }
}
