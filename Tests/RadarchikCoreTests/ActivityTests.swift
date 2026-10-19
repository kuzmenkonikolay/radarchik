import Foundation
import Testing
@testable import RadarchikCore

let t0 = Date(timeIntervalSince1970: 1_760_000_000)

func snap(_ app: String, title: String? = nil, url: String? = nil) -> FocusSnapshot {
    FocusSnapshot(bundleId: "com.test.\(app)", appName: app, windowTitle: title, url: url, isPrivate: false)
}

@Suite("Наблюдение: адреса, заголовки, исключения")
struct ActivityNormalizationTests {
    @Test func urlsLoseQueryFragmentAndIdentifiers() {
        #expect(URLNormalizer.normalize("https://github.com/acme/app/pull/123?tab=files#diff") == "github.com/acme/app/pull/:id")
        #expect(URLNormalizer.normalize("https://www.Mail.ru/inbox/") == "mail.ru/inbox")
        #expect(URLNormalizer.normalize("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit")
            == "docs.google.com/document/d/:token/edit")
        #expect(URLNormalizer.normalize("https://app.site/orders/123e4567-e89b-12d3-a456-426614174000") == "app.site/orders/:uuid")
        #expect(URLNormalizer.normalize("chrome://newtab/") == "chrome://newtab")
        #expect(URLNormalizer.normalize("file:///Users/me/secret.pdf") == "file")
        #expect(URLNormalizer.normalize("about:blank") == nil)
        #expect(URLNormalizer.normalize("not a url") == nil)
    }

    @Test func excludedDomainsMatchSubdomainsOnly() {
        #expect(URLNormalizer.host(of: "online.sberbank.ru/CSAFront/index.do") == "online.sberbank.ru")
        #expect(ObservationRules.isExcluded(host: "online.sberbank.ru", domains: ["sberbank.ru"]))
        #expect(ObservationRules.isExcluded(host: "sberbank.ru", domains: ["sberbank.ru"]))
        #expect(!ObservationRules.isExcluded(host: "notsberbank.ru", domains: ["sberbank.ru"]))
        #expect(ObservationRules.defaultExcludedApps.contains("com.1password.1password"))
    }

    @Test func excludedAppsHaveHumanNamesEvenWhenNotInstalled() {
        // Список исключений показывает имена, а не bundle id (скриншот 2026-10-18).
        #expect(ObservationRules.knownName(of: "com.bitwarden.desktop") == "Bitwarden")
        #expect(ObservationRules.knownName(of: "com.agilebits.onepassword7") == "1Password 7")
        #expect(ObservationRules.defaultExcludedApps.allSatisfy { ObservationRules.knownName(of: $0) != nil })
        #expect(ObservationRules.knownName(of: "com.example.unknown") == nil)
    }

    @Test func titlesLoseSpinnersAndCounters() {
        #expect(TitleNormalizer.normalize("✳ Radarchik-notch-app маскот") == "Radarchik-notch-app маскот")
        #expect(TitleNormalizer.normalize("⠋ claude — ~/work") == "claude — ~/work")
        #expect(TitleNormalizer.normalize("Входящие (12) — Почта") == "Входящие — Почта")
        #expect(TitleNormalizer.normalize("C++ notes") == "C++ notes")
        #expect(TitleNormalizer.normalize("   ") == nil)
        #expect(TitleNormalizer.normalize(nil) == nil)
    }

    @Test func browsersAndCallServices() {
        #expect(Browsers.kind(of: "com.google.Chrome") == .chromium)
        #expect(Browsers.kind(of: "company.thebrowser.Browser") == .chromium)
        #expect(Browsers.kind(of: "com.apple.Safari") == .safari)
        #expect(Browsers.kind(of: "org.mozilla.firefox") == .firefox)
        #expect(Browsers.kind(of: "com.apple.Terminal") == nil)

        #expect(CallService.name(holderBundleId: "com.google.Chrome.helper", holderName: "Google Chrome Helper", browserHost: "meet.google.com") == "meet.google.com")
        #expect(CallService.name(holderBundleId: "com.google.Chrome.helper", holderName: "Google Chrome Helper", browserHost: nil) == "Браузер")
        #expect(CallService.name(holderBundleId: "us.zoom.xos", holderName: "zoom.us", browserHost: nil) == "Zoom")
        #expect(CallService.name(holderBundleId: "ru.keepcoder.Telegram", holderName: "Telegram", browserHost: nil) == "Telegram")
        #expect(CallService.name(holderBundleId: "com.example.app", holderName: "Пример", browserHost: nil) == "Пример")
        #expect(CallService.name(holderBundleId: nil, holderName: nil, browserHost: nil) == nil)
    }

    @Test func pasteTargetIsNextAppWithinAMinute() {
        #expect(PasteHeuristic.target(copiedIn: "com.apple.mail", copiedAt: t0, activated: "com.google.Chrome", at: t0 + 20) == "com.google.Chrome")
        #expect(PasteHeuristic.target(copiedIn: "com.apple.mail", copiedAt: t0, activated: "com.google.Chrome", at: t0 + 90) == nil)
        #expect(PasteHeuristic.target(copiedIn: "com.apple.mail", copiedAt: t0, activated: "com.apple.mail", at: t0 + 5) == nil)
    }
}

@Suite("Наблюдение: сессии")
struct ActivitySessionizerTests {
    @Test func sameFocusExtendsSessionAndChangeClosesIt() {
        var sessionizer = ActivitySessionizer()
        #expect(sessionizer.observe(snap("Chrome", url: "github.com"), at: t0) == nil)
        #expect(sessionizer.observe(snap("Chrome", url: "github.com"), at: t0 + 10) == nil)
        let closed = sessionizer.observe(snap("Terminal"), at: t0 + 30)
        #expect(closed?.appName == "Chrome")
        #expect(closed?.startedAt == t0)
        #expect(closed?.endedAt == t0 + 30)
        #expect(sessionizer.current?.appName == "Terminal")
    }

    @Test func pauseClosesAtGivenMomentAndNextSnapshotStartsFresh() {
        var sessionizer = ActivitySessionizer()
        _ = sessionizer.observe(snap("Xcode"), at: t0)
        #expect(sessionizer.pause(at: t0 + 100)?.duration == 100)
        #expect(sessionizer.current == nil)
        #expect(sessionizer.observe(snap("Xcode"), at: t0 + 500) == nil)
        #expect(sessionizer.current?.startedAt == t0 + 500)
    }

    @Test func excludedAppClosesSessionWithoutStartingNew() {
        var sessionizer = ActivitySessionizer()
        _ = sessionizer.observe(snap("Chrome"), at: t0)
        #expect(sessionizer.observe(nil, at: t0 + 5)?.appName == "Chrome")
        #expect(sessionizer.current == nil)
    }

    @Test func glancesShorterThanASecondAreDropped() {
        var sessionizer = ActivitySessionizer()
        _ = sessionizer.observe(snap("Chrome"), at: t0)
        #expect(sessionizer.observe(snap("Finder"), at: t0 + 0.4) == nil)
        #expect(sessionizer.current?.appName == "Finder")
    }
}

@Suite("Наблюдение: запись в базу")
struct ActivityStorageTests {
    func makeRepository() throws -> ActivityRepository {
        try ActivityRepository(database: Database(path: ":memory:"))
    }

    @Test func longSessionIsSavedEarlyAndCheckpointed() throws {
        let repository = try makeRepository()
        let recorder = ActivityRecorder(repository: repository)
        let range = (t0 - 1)...(t0 + 1000)

        try recorder.observe(snap("Xcode"), at: t0)
        #expect(try repository.sessions(in: range).isEmpty)          // пока моложе 2 секунд — только в памяти
        try recorder.observe(snap("Xcode"), at: t0 + 3)
        #expect(try repository.sessions(in: range).count == 1)       // сохранена
        try recorder.observe(snap("Xcode"), at: t0 + 40)             // чекпоинт раз в 30 секунд
        #expect(try repository.sessions(in: range).first?.endedAt == t0 + 40)
        try recorder.observe(snap("Chrome"), at: t0 + 50)
        let sessions = try repository.sessions(in: range)
        #expect(sessions.map(\.appName) == ["Xcode"])                // Chrome ещё слишком свежий
        #expect(sessions.first?.endedAt == t0 + 50)
    }

    @Test func shortSessionsNeverHitTheDatabase() throws {
        let repository = try makeRepository()
        let recorder = ActivityRecorder(repository: repository)
        try recorder.observe(snap("Finder"), at: t0)
        try recorder.observe(snap("Xcode"), at: t0 + 0.5)
        try recorder.pause(at: t0 + 0.9)
        #expect(try repository.sessions(in: (t0 - 1)...(t0 + 10)).isEmpty)
    }

    @Test func sessionClosedBeforeFirstSaveIsInsertedWhole() throws {
        let repository = try makeRepository()
        let recorder = ActivityRecorder(repository: repository)
        try recorder.observe(snap("Finder", title: "Загрузки"), at: t0)
        try recorder.observe(snap("Xcode"), at: t0 + 1.5)
        let sessions = try repository.sessions(in: (t0 - 1)...(t0 + 10))
        #expect(sessions.map(\.appName) == ["Finder"])
        #expect(sessions.first?.duration == 1.5)
        #expect(sessions.first?.windowTitle == "Загрузки")
    }

    @Test func storesCommandsPastesCallsAndAppEvents() throws {
        let repository = try makeRepository()
        let range = (t0 - 1)...(t0 + 1000)
        try repository.insert(ShellCommand(command: "make test", template: "make test", cwd: "~/work", startedAt: t0, durationMs: 1200, exitCode: 0))
        let pasteId = try repository.insert(PasteEvent(fromBundleId: "com.apple.mail", toBundleId: nil, at: t0))
        try repository.updatePasteTarget(id: pasteId, toBundleId: "com.google.Chrome")
        let callId = try repository.insert(CallSession(bundleId: "us.zoom.xos", service: "Zoom", usesCamera: true, startedAt: t0, endedAt: nil))
        try repository.endCall(id: callId, at: t0 + 600)
        try repository.insert(AppLifecycleEvent(bundleId: "com.tinyspeck.slackmacgap", appName: "Slack", kind: .launched, at: t0))

        #expect(try repository.commands(in: range).map(\.command) == ["make test"])
        #expect(try repository.pastes(in: range).first?.toBundleId == "com.google.Chrome")
        #expect(try repository.calls(in: range).first?.endedAt == t0 + 600)
        #expect(try repository.calls(in: range).first?.usesCamera == true)
        #expect(try repository.appEvents(in: range).first?.kind == .launched)
    }

    @Test func retentionDeletesOldRowsEverywhere() throws {
        let repository = try makeRepository()
        let old = t0 - 31 * 86_400
        try repository.insert(ActivitySession(bundleId: "a", appName: "A", startedAt: old, endedAt: old + 10))
        try repository.insert(ActivitySession(bundleId: "b", appName: "B", startedAt: t0, endedAt: t0 + 10))
        try repository.insert(ShellCommand(command: "ls", template: "ls", cwd: nil, startedAt: old, durationMs: 1, exitCode: 0))
        _ = try repository.insert(PasteEvent(fromBundleId: "a", toBundleId: nil, at: old))
        _ = try repository.insert(CallSession(bundleId: nil, service: nil, usesCamera: false, startedAt: old, endedAt: old + 60))
        try repository.insert(AppLifecycleEvent(bundleId: "a", appName: "A", kind: .terminated, at: old))

        try repository.deleteOlderThan(t0 - 30 * 86_400)

        let everything = (old - 1)...(t0 + 100)
        #expect(try repository.sessions(in: everything).map(\.appName) == ["B"])
        #expect(try repository.commands(in: everything).isEmpty)
        #expect(try repository.pastes(in: everything).isEmpty)
        #expect(try repository.calls(in: everything).isEmpty)
        #expect(try repository.appEvents(in: everything).isEmpty)
    }

    @Test func activityTablesAreAddedToExistingMoneyDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("radarchik-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("radarchik.sqlite").path
        let project = Fixture.project()

        // Так выглядит база после этапов 1–2: только деньги, версия схемы 1.
        do {
            let db = try Database(path: path)
            try DatabaseSchema.migrate(db, upTo: 1)
            try db.run(
                "INSERT INTO projects (id, name, color_hex, currency, created_at, is_archived) VALUES (?, ?, ?, ?, ?, 0)",
                [.text(project.id.uuidString), .text(project.name), .text(project.colorHex),
                 .text(project.currency.rawValue), .real(project.createdAt.timeIntervalSince1970)]
            )
            #expect(try db.userVersion() == 1)
        }
        let activity = try ActivityRepository(database: Database(path: path))
        try activity.insert(ActivitySession(bundleId: "a", appName: "A", startedAt: t0, endedAt: t0 + 5))

        #expect(try LedgerRepository(database: Database(path: path)).loadLedger().projects == [project])
        #expect(try activity.sessions(in: (t0 - 1)...(t0 + 10)).count == 1)
    }
}

@Suite("Наблюдение: сводка дня")
struct DaySummaryTests {
    @Test func aggregatesAppsSitesCommandsPastesCallsAndSwitches() {
        let chrome = "com.google.Chrome", terminal = "com.apple.Terminal", xcode = "com.apple.dt.Xcode"
        let sessions = [
            ActivitySession(bundleId: chrome, appName: "Chrome", url: "github.com/acme", startedAt: t0, endedAt: t0 + 600),
            ActivitySession(bundleId: terminal, appName: "Терминал", startedAt: t0 + 600, endedAt: t0 + 900),
            ActivitySession(bundleId: chrome, appName: "Chrome", url: "github.com/acme/pulls", startedAt: t0 + 900, endedAt: t0 + 1200),
            ActivitySession(bundleId: chrome, appName: "Chrome", url: "mail.ru/inbox", startedAt: t0 + 1200, endedAt: t0 + 1300),
            ActivitySession(bundleId: xcode, appName: "Xcode", startedAt: t0 + 1300, endedAt: t0 + 2000),
        ]
        let commands = [
            ShellCommand(command: "make test", template: "make test", cwd: "~", startedAt: t0, durationMs: 1000, exitCode: 0),
            ShellCommand(command: "make test", template: "make test", cwd: "~", startedAt: t0 + 10, durationMs: 2000, exitCode: 2),
            ShellCommand(command: "make test", template: "make test", cwd: "~", startedAt: t0 + 20, durationMs: 3000, exitCode: 0),
            ShellCommand(command: "git status", template: "git status", cwd: "~", startedAt: t0 + 30, durationMs: 50, exitCode: 0),
        ]
        let pastes = [
            PasteEvent(fromBundleId: "com.apple.mail", toBundleId: chrome, at: t0),
            PasteEvent(fromBundleId: "com.apple.mail", toBundleId: chrome, at: t0 + 5),
            PasteEvent(fromBundleId: terminal, toBundleId: xcode, at: t0 + 9),
        ]
        let calls = [CallSession(bundleId: "us.zoom.xos", service: "Zoom", usesCamera: true, startedAt: t0, endedAt: t0 + 1800)]

        let summary = DaySummaryBuilder.build(sessions: sessions, commands: commands, pastes: pastes, calls: calls)

        #expect(summary.apps.map(\.appName) == ["Chrome", "Xcode", "Терминал"])
        #expect(summary.apps.first?.seconds == 1000)
        #expect(summary.sites.map(\.host) == ["github.com", "mail.ru"])
        #expect(summary.sites.first?.visits == 2)
        #expect(summary.sites.first?.seconds == 900)
        #expect(summary.commands.first == DaySummary.CommandCount(template: "make test", count: 3, totalDurationMs: 6000, failures: 1))
        #expect(summary.pastes.first == DaySummary.PasteFlow(fromApp: "com.apple.mail", toApp: "Chrome", count: 2))
        #expect(summary.switches.first == DaySummary.SwitchPair(first: "Chrome", second: "Терминал", count: 2))
        #expect(summary.callSeconds == 1800)
        #expect(summary.callCount == 1)
        #expect(summary.activeSeconds == 2000)
    }

    @Test func emptyDayIsEmpty() {
        let summary = DaySummaryBuilder.build(sessions: [], commands: [], pastes: [], calls: [])
        #expect(summary.apps.isEmpty && summary.sites.isEmpty && summary.commands.isEmpty)
        #expect(summary.activeSeconds == 0)
    }
}

@Suite("Наблюдение: длительности и «назад»")
struct DurationFormatTests {
    @Test func shortDurations() {
        #expect(DurationFormat.short(30) == "меньше минуты")
        #expect(DurationFormat.short(60) == "1 мин")
        #expect(DurationFormat.short(754) == "12 мин")
        #expect(DurationFormat.short(3_900) == "1 ч 05 мин")
        #expect(DurationFormat.short(7_200) == "2 ч")
    }

    @Test func relativeTime() {
        #expect(DurationFormat.ago(t0 - 20, now: t0) == "только что")
        #expect(DurationFormat.ago(t0 - 300, now: t0) == "5 мин назад")
        #expect(DurationFormat.ago(t0 - 7_300, now: t0) == "2 ч назад")
        #expect(DurationFormat.ago(t0 - 3 * 86_400, now: t0) == "3 дн. назад")
    }

    /// По-английски — как «Экранное время» в macOS: «1h 5m».
    @Test func englishDurations() {
        english {
            #expect(DurationFormat.short(30) == "under a minute")
            #expect(DurationFormat.short(754) == "12m")
            #expect(DurationFormat.short(3_900) == "1h 5m")
            #expect(DurationFormat.short(7_200) == "2h")
            #expect(DurationFormat.ago(t0 - 20, now: t0) == "just now")
            #expect(DurationFormat.ago(t0 - 300, now: t0) == "5m ago")
            #expect(DurationFormat.ago(t0 - 7_300, now: t0) == "2h ago")
            #expect(DurationFormat.ago(t0 - 3 * 86_400, now: t0) == "3d ago")
        }
    }

    @Test func falseCallsCanBeDeleted() throws {
        // Siri или диктовка на пару секунд — не звонок, такую запись удаляем.
        let repository = try ActivityRepository(database: Database(path: ":memory:"))
        let id = try repository.insert(CallSession(bundleId: nil, service: nil, usesCamera: false, startedAt: t0, endedAt: nil))
        try repository.deleteCall(id: id)
        #expect(try repository.calls(in: (t0 - 1)...(t0 + 1)).isEmpty)
    }

    /// Звонок без конца остаётся, если Радарчик убили посреди звонка (`make run`
    /// делает pkill). Сводка считала бы его «до сих пор» (2026-10-19), поэтому
    /// при запуске такие записи удаляются: сколько он шёл, не узнать.
    @Test func danglingCallsAreDeletedOnLaunch() throws {
        let repository = try ActivityRepository(database: Database(path: ":memory:"))
        _ = try repository.insert(CallSession(bundleId: "us.zoom.xos", service: "Zoom", usesCamera: false, startedAt: t0, endedAt: nil))
        _ = try repository.insert(CallSession(bundleId: "us.zoom.xos", service: "Zoom", usesCamera: true, startedAt: t0 + 60, endedAt: t0 + 1_860))
        try repository.deleteDanglingCalls()
        let calls = try repository.calls(in: (t0 - 1)...(t0 + 3_600))
        #expect(calls.count == 1)
        #expect(calls.first?.endedAt == t0 + 1_860)
    }
}
