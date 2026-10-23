import Darwin
import Foundation
import Testing
@testable import RadarchikCore

/// «Защита», этап 1 (SPEC §3б): что защищаем, что сейчас открыто и сколько
/// осталось до автозакрытия. Закрывает и открывает пока старый guard —
/// Радарчик только смотрит.
@Suite("Защита: ключи и таймер")
struct GuardKeysTests {
    // MARK: - Список того, что защищаем

    @Test func parsesGuardConfigLikeTheOldScript() {
        let text = """
            # FileGuard — список защищаемых файлов
            ssh|~/.ssh/id_*
              env | ~/work/*/config/master.key
            # ssh|~/.ssh/known_hosts
            weird|~/secret.txt
            строка без разделителя
            aws|
            """
        #expect(GuardRules.parse(text) == [
            GuardRule(.ssh, "~/.ssh/id_*"),
            GuardRule(.env, "~/work/*/config/master.key"),
            // Неизвестная категория не теряется — уходит в «Другое».
            GuardRule(.custom, "~/secret.txt"),
        ])
    }

    @Test func homeIsExpandedOnlyAtTheStart() {
        #expect(GuardRules.expandHome("~/.ssh/id_*", home: "/Users/me") == "/Users/me/.ssh/id_*")
        #expect(GuardRules.expandHome("~", home: "/Users/me") == "/Users/me")
        #expect(GuardRules.expandHome("/etc/~x", home: "/Users/me") == "/etc/~x")
    }

    @Test func publicKeysAreNotSecrets() {
        #expect(GuardRules.isPublicKey("/Users/me/.ssh/id_ed25519.pub"))
        #expect(!GuardRules.isPublicKey("/Users/me/.ssh/id_ed25519"))
        #expect(!GuardRules.isPublicKey("/Users/me/work/app/config/master.key"))
    }

    @Test func defaultsCoverSshAndCloudKeys() {
        let patterns = GuardRules.defaults.map(\.pattern)
        #expect(patterns.contains("~/.ssh/id_*"))
        #expect(patterns.contains("~/.aws/credentials"))
        #expect(GuardRules.defaults.allSatisfy { $0.category != .custom })
    }

    // MARK: - Кто владеет файлом

    @Test func ownerDecidesLockState() {
        #expect(LockProbe.state(ownerUID: 0, userUID: 501) == .locked)
        #expect(LockProbe.state(ownerUID: 501, userUID: 501) == .open)
        #expect(LockProbe.state(ownerUID: 502, userUID: 501) == .foreign)
    }

    @Test func probeExpandsGlobsAndSkipsLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keys/nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["keys/a.key", "keys/b.key", "keys/notes.txt", "keys/nested/c.key"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        // Ссылка под видом ключа: guard прошёл бы по ней и отдал бы чужой файл тебе.
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("keys/z.key"), withDestinationURL: folder.appendingPathComponent("keys/notes.txt")
        )

        let keys = LockProbe.files(matching: folder.path + "/keys/*.key")
        #expect(keys.map { ($0 as NSString).lastPathComponent } == ["a.key", "b.key"])
        // Папка целиком — все файлы внутри, тоже без ссылок.
        let all = LockProbe.files(matching: folder.path + "/keys")
        #expect(all.count == 4)
        #expect(LockProbe.owner(of: keys[0]) == getuid())
        #expect(LockProbe.owner(of: folder.path + "/keys/z.key") == nil)
        #expect(LockProbe.owner(of: folder.path + "/keys/missing.key") == nil)
    }

    // MARK: - Журнал старого guard

    private let log = """
        2026-10-20 09:00:00 [ALLOW] unlock ssh for user me (timeout: 300s)
        2026-10-20 09:05:00 [AUTO] auto-lock ssh after timeout
        2026-10-20 10:00:00 [ALLOW] unlock env for me (mode: timer, timeout: 300s)
        2026-10-20 10:01:00 [DENY] unlock ssh denied by user (mode: timer)
        2026-10-20 10:02:00 [ALLOW] unlock ssh for me (mode: manual)
        2026-10-20 10:02:30 [DAEMON] ALARM: /Users/me/.ssh/config owned by me (expected root), permissions 600 — restoring
        2026-10-20 10:03:00 [INFO] Integrity hashes regenerated
        мусор, а не строка журнала
        """

    private func at(_ time: String) -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 20
        let numbers = time.split(separator: ":").compactMap { Int($0) }
        parts.hour = numbers[0]
        parts.minute = numbers[1]
        parts.second = numbers.count > 2 ? numbers[2] : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar.date(from: parts)!
    }

    private var entries: [LegacyGuardLog.Entry] {
        LegacyGuardLog.parse(log, timeZone: TimeZone(identifier: "Europe/Moscow")!)
    }

    @Test func parsesUnlocksLocksAndAlarms() {
        #expect(entries == [
            .init(at: at("09:00"), action: .unlock(.timer, timeout: 300), category: "ssh"),
            .init(at: at("09:05"), action: .lock, category: "ssh"),
            .init(at: at("10:00"), action: .unlock(.timer, timeout: 300), category: "env"),
            .init(at: at("10:01"), action: .deny, category: "ssh"),
            .init(at: at("10:02"), action: .unlock(.manual, timeout: nil), category: "ssh"),
            .init(at: at("10:02:30"), action: .alarm, category: nil),
        ])
    }

    @Test func openWindowIsTheLastUnlockWithoutLockAfterIt() {
        let windows = LegacyGuardLog.windows(entries)
        // env открыли на 5 минут и не закрыли — закроется в 10:05.
        #expect(windows[.env] == UnlockWindow(openedAt: at("10:00"), mode: .timer, closesAt: at("10:05")))
        // ssh открыли вручную — до ручной блокировки.
        #expect(windows[.ssh] == UnlockWindow(openedAt: at("10:02"), mode: .manual, closesAt: nil))
        #expect(windows[.aws] == nil)
    }

    @Test func lockAllClosesEveryWindow() {
        let all = entries + LegacyGuardLog.parse("2026-10-20 10:10:00 [LOCK] locked all", timeZone: TimeZone(identifier: "Europe/Moscow")!)
        #expect(LegacyGuardLog.windows(all).isEmpty)
        let unlockAll = LegacyGuardLog.parse(
            "2026-10-20 11:00:00 [ALLOW] unlock all for me (mode: timer, timeout: 300s)", timeZone: TimeZone(identifier: "Europe/Moscow")!
        )
        #expect(LegacyGuardLog.windows(all + unlockAll)[.gpg]?.closesAt == at("11:05"))
    }

    @Test func countsUnlocksSinceMorning() {
        #expect(LegacyGuardLog.unlockCounts(entries, since: at("09:30")) == [.env: 1, .ssh: 1])
        #expect(LegacyGuardLog.unlockCounts(entries, since: at("00:00")) == [.env: 1, .ssh: 2])
    }

    // MARK: - Что открыто

    private func file(_ path: String, _ category: GuardCategory, _ state: LockState, inGit: Bool = false) -> ProtectedFile {
        ProtectedFile(path: path, category: category, state: state, inGit: inGit)
    }

    @Test func categoriesGroupFilesInFixedOrder() {
        let files = [
            file("/w/app/config/credentials/test.key", .env, .locked, inGit: true),
            file("/u/.ssh/id_ed25519", .ssh, .open),
            file("/w/app/config/credentials/production.key", .env, .locked),
            file("/u/.ssh/config", .ssh, .locked),
        ]
        let categories = GuardStatus.categories(files, windows: [:])
        #expect(categories.map(\.category) == [.ssh, .env])
        #expect(categories[0].openFiles.map(\.path) == ["/u/.ssh/id_ed25519"])
        #expect(categories[0].isOpen)
        // test.key в git: закрывать бессмысленно, открытым он не считается.
        #expect(!categories[1].isOpen)
        #expect(categories[1].guarded.count == 1)
    }

    @Test func wingCountsDownWhileTimerRuns() {
        let window = UnlockWindow(openedAt: at("10:00"), mode: .timer, closesAt: at("10:05"))
        let categories = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .open)], windows: [.ssh: window])
        let wing = GuardStatus.wing(categories, now: at("10:00:48"))
        #expect(wing == GuardWing(categories: [.ssh], remaining: 252, isOverdue: false))
        #expect(wing?.text == "ssh 4:12")
    }

    @Test func wingWarnsWhenOpenTooLong() throws {
        // Таймер давно прошёл, а ключ открыт: перезагрузка посреди разблокировки или ручной режим.
        let window = UnlockWindow(openedAt: at("09:00"), mode: .timer, closesAt: at("09:05"))
        let categories = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .open)], windows: [.ssh: window])
        let wing = try #require(GuardStatus.wing(categories, now: at("10:00")))
        #expect(wing.isOverdue)
        #expect(wing.remaining == nil)
        #expect(wing.text == "ssh")
    }

    @Test func wingIsQuietWhenEverythingIsLocked() {
        let categories = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .locked)], windows: [:])
        #expect(GuardStatus.wing(categories, now: at("10:00")) == nil)
    }

    @Test func neverLockedFileIsNotATimer() {
        // Новый ключ, который guard ещё не закрывал: это видно на экране «Защита»,
        // но крыло о нём не тикает — таймера у него нет и не было.
        let categories = GuardStatus.categories([file("/w/app/config/master.key", .env, .open)], windows: [:])
        #expect(categories[0].isOpen)
        #expect(categories[0].window == nil)
        #expect(GuardStatus.wing(categories, now: at("10:00")) == nil)
    }

    // MARK: - Фраза на экране «Защита»

    @Test func phraseWhenEverythingIsLocked() {
        let categories = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .locked), file("/w/a/.env", .env, .locked)], windows: [:])
        #expect(GuardPhrase.keys(categories, now: at("10:00"), unlocksToday: [:]) == "Все ключи закрыты")
        #expect(GuardPhrase.keys(categories, now: at("10:00"), unlocksToday: [.ssh: 6, .env: 2])
            == "Все ключи закрыты. Сегодня открывал: ssh — 6 раз, env — 2 раза")
        english {
            #expect(GuardPhrase.keys(categories, now: at("10:00"), unlocksToday: [.ssh: 1]) == "All keys are locked. Opened today: ssh once")
        }
    }

    @Test func shortLineForTheSummary() {
        let locked = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .locked)], windows: [:])
        #expect(GuardPhrase.keysLine(locked, now: at("10:00"), unlocksToday: [.ssh: 6, .env: 2]) == "Все ключи закрыты · сегодня открывал 8 раз")
        #expect(GuardPhrase.keysLine(locked, now: at("10:00"), unlocksToday: [:]) == "Все ключи закрыты")
        // Пока что-то открыто, строка — о нём, без счётчиков.
        let window = UnlockWindow(openedAt: at("10:00"), mode: .timer, closesAt: at("10:05"))
        let open = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .open)], windows: [.ssh: window])
        #expect(GuardPhrase.keysLine(open, now: at("10:01"), unlocksToday: [.ssh: 6]) == "Открыто: SSH-ключи — закроются через 4:00")
        english {
            #expect(GuardPhrase.keysLine(locked, now: at("10:00"), unlocksToday: [.ssh: 1]) == "All keys are locked · opened once today")
        }
    }

    @Test func phraseWhileTimerRuns() {
        let window = UnlockWindow(openedAt: at("10:00"), mode: .timer, closesAt: at("10:05"))
        let categories = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .open)], windows: [.ssh: window])
        #expect(GuardPhrase.keys(categories, now: at("10:00:48"), unlocksToday: [.ssh: 1]) == "Открыто: SSH-ключи — закроются через 4:12")
    }

    @Test func phraseWhenOpenTooLongTellsHowToLock() {
        let window = UnlockWindow(openedAt: at("09:00"), mode: .timer, closesAt: at("09:05"))
        let categories = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .open)], windows: [.ssh: window])
        #expect(GuardPhrase.keys(categories, now: at("10:00"), unlocksToday: [:]) == "Открыто уже 1 ч: SSH-ключи. Закрой: sudo guard lock ssh")
    }

    @Test func phraseForManualAndNeverLocked() {
        let manual = UnlockWindow(openedAt: at("09:00"), mode: .manual, closesAt: nil)
        let open = GuardStatus.categories([file("/u/.ssh/id_ed25519", .ssh, .open)], windows: [.ssh: manual])
        #expect(GuardPhrase.keys(open, now: at("10:00"), unlocksToday: [:]) == "Открыто до ручной блокировки: SSH-ключи")
        let fresh = GuardStatus.categories([file("/Users/me/work/app/config/master.key", .env, .open)], windows: [:])
        #expect(GuardPhrase.keys(fresh, now: at("10:00"), unlocksToday: [:], home: "/Users/me")
            == "Не закрыт ключ ~/work/app/config/master.key — его закроет sudo guard init")
    }

    @Test func severalOpenCategoriesShareTheShortestTimer() {
        let ssh = UnlockWindow(openedAt: at("10:00"), mode: .timer, closesAt: at("10:05"))
        let env = UnlockWindow(openedAt: at("10:02"), mode: .timer, closesAt: at("10:07"))
        let categories = GuardStatus.categories(
            [file("/u/.ssh/id_ed25519", .ssh, .open), file("/w/app/.env", .env, .open)], windows: [.ssh: ssh, .env: env]
        )
        let wing = GuardStatus.wing(categories, now: at("10:04"))
        #expect(wing?.text == "ssh+env 1:00")
    }
}
