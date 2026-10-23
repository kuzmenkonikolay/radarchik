import Foundation
import Testing
@testable import RadarchikCore

/// Журнал «Защиты» в SQLite (схема v5): что заметил Радарчик и что ты ответил,
/// и список «разрешать всегда».
@Suite("Защита: журнал")
struct GuardRepositoryTests {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func repository() throws -> GuardRepository {
        try GuardRepository(database: Database(path: ":memory:"))
    }

    @Test func schemaV5AddsGuardTablesWithoutTouchingMoney() throws {
        let db = try Database(path: ":memory:")
        try DatabaseSchema.migrate(db, upTo: 4)
        _ = try LedgerRepository(database: db)
        #expect(try db.userVersion() == DatabaseSchema.latestVersion)
        _ = try GuardRepository(database: db)
        #expect(try db.query("SELECT COUNT(*) FROM guard_events") { $0.int(0) } == [0])
    }

    @Test func eventsRoundTripAndAnswer() throws {
        let repo = try repository()
        let event = try repo.add(
            kind: .process, level: .critical, at: t0,
            title: "node -e — запустил Cursor", detail: "node -e const _$_1e42=…", allowKey: "inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app"
        )
        #expect(event.status == .active)
        #expect(try repo.active() == [event])

        try repo.setStatus(event.id, .killed, at: t0 + 5)
        let stored = try repo.events(since: t0 - 1)
        #expect(stored.count == 1)
        #expect(stored[0].status == .killed)
        #expect(stored[0].statusChangedAt == t0 + 5)
        #expect(try repo.active().isEmpty)
    }

    @Test func allowAlwaysIsRemembered() throws {
        let repo = try repository()
        #expect(try !repo.isAllowed("inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app"))
        try repo.allow("inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app", at: t0)
        try repo.allow("inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app", at: t0 + 1)
        #expect(try repo.isAllowed("inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app"))
        #expect(try repo.allowedKeys() == ["inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app"])
        try repo.disallow("inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app")
        #expect(try repo.allowedKeys().isEmpty)
    }

    @Test func newestFirstAndOldOnesPurged() throws {
        let repo = try repository()
        _ = try repo.add(kind: .code, level: .info, at: t0 - 70 * 86_400, title: "старое", detail: nil, allowKey: nil)
        _ = try repo.add(kind: .code, level: .info, at: t0, title: "Проверил 47 файлов", detail: nil, allowKey: nil)
        _ = try repo.add(kind: .audit, level: .warning, at: t0 + 60, title: "Claude", detail: nil, allowKey: nil)
        try repo.purge(now: t0 + 120)
        #expect(try repo.events(since: .distantPast).map(\.title) == ["Claude", "Проверил 47 файлов"])
    }

    @Test func recentByAllowKeyForQuietRepeats() throws {
        let repo = try repository()
        _ = try repo.add(kind: .process, level: .warning, at: t0, title: "python -c", detail: nil, allowKey: "inlinePython|/usr/bin/python3|/bin/zsh")
        #expect(try repo.lastSeen("inlinePython|/usr/bin/python3|/bin/zsh") == t0)
        #expect(try repo.lastSeen("другое") == nil)
    }
}
