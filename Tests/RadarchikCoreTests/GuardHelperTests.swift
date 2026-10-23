import Darwin
import Foundation
import Testing
@testable import RadarchikCore

/// Root-часть «Защиты» (SPEC §3б, этап 2): то, что можно проверить без root.
/// Главное здесь — смена владельца: root-часть не должна дать увести себя
/// ссылкой или жёсткой ссылкой на чужой файл. В тестах «владелец» — мы сами,
/// поэтому chown ничего не меняет, но все проверки до него — настоящие.
@Suite("Защита: root-часть")
struct GuardHelperTests {
    /// Временная «домашняя папка» с файлами.
    private final class Home {
        let path: String

        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("guard-home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            path = url.path
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }

        @discardableResult
        func file(_ relative: String, mode: mode_t = 0o644) throws -> String {
            let full = path + "/" + relative
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: URL(fileURLWithPath: full))
            chmod(full, mode)
            return full
        }

        func mode(_ full: String) -> mode_t {
            var info = stat()
            lstat(full, &info)
            return info.st_mode & 0o777
        }
    }

    private func set(_ path: String, in home: Home, owners: Set<uid_t> = [0, getuid()]) -> SafeOwnership.Failure? {
        SafeOwnership.set(path, home: home.path, owner: getuid(), group: getgid(), mode: 0o600, allowedOwners: owners)
    }

    // MARK: - Смена владельца

    @Test func changesARegularFileInsideHome() throws {
        let home = try Home()
        let key = try home.file(".ssh/id_ed25519")
        #expect(set(key, in: home) == nil)
        #expect(home.mode(key) == 0o600)
    }

    @Test func refusesASymlinkedFile() throws {
        let home = try Home()
        let target = try home.file("notes.txt")
        let link = home.path + "/.ssh/id_x"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(set(link, in: home) == .symlink)
        // Файл, на который указывала ссылка, не тронут.
        #expect(home.mode(target) == 0o644)
    }

    @Test func refusesASymlinkedFolderOnTheWay() throws {
        let home = try Home()
        try home.file("real/config/master.key")
        // ~/work → ~/real: путь выглядит как внутри дома, но ведёт через ссылку.
        try FileManager.default.createSymbolicLink(atPath: home.path + "/work", withDestinationPath: home.path + "/real")
        #expect(set(home.path + "/work/config/master.key", in: home) == .symlink)
    }

    @Test func refusesHardLinks() throws {
        let home = try Home()
        let key = try home.file(".ssh/id_ed25519")
        // Жёсткая ссылка — тот же файл под другим именем: так подсовывают чужой файл.
        #expect(link(key, home.path + "/.ssh/id_copy") == 0)
        #expect(set(key, in: home) == .hardLinked)
    }

    @Test func refusesPathsOutsideHome() throws {
        let home = try Home()
        #expect(set("/etc/sudoers", in: home) == .outsideHome)
        #expect(set(home.path + "/../other/key", in: home) == .outsideHome)
        #expect(set(home.path + "x/key", in: home) == .outsideHome)
        #expect(set(home.path, in: home) == .outsideHome)
    }

    @Test func refusesFoldersMissingFilesAndStrangers() throws {
        let home = try Home()
        #expect(set(home.path + "/.ssh", in: home) == .notRegularFile)
        #expect(set(home.path + "/.ssh/missing", in: home) == .missing)
        // Файл чужого владельца (не root и не ты) не трогаем.
        let key = try home.file(".ssh/id_rsa")
        #expect(set(key, in: home, owners: [0]) == .foreignOwner(getuid()))
    }

    // MARK: - Список

    @Test func configKeepsRulesAndExclusions() {
        let text = """
            # Радарчик
            ssh|~/.ssh/id_*
            env|~/work/*/config/credentials/*.key
            exclude|/Users/me/work/storefront/config/credentials/test.key
            """
        let config = GuardConfig.parse(text)
        #expect(config.rules == [GuardRule(.ssh, "~/.ssh/id_*"), GuardRule(.env, "~/work/*/config/credentials/*.key")])
        #expect(config.excluded == ["/Users/me/work/storefront/config/credentials/test.key"])
        #expect(GuardConfig.parse(config.render()) == config)
        // Старый разбор (у guard исключений не было) не делает из них правило «Другое».
        #expect(GuardRules.parse(text).count == 2)
    }

    @Test func categoryNamesFromRequests() {
        #expect(GuardHelper.categories("ssh") == [.ssh])
        #expect(GuardHelper.categories("all") == GuardCategory.allCases)
        #expect(GuardHelper.categories("../etc") == nil)
        #expect(GuardHelper.categories("") == nil)
    }

    @Test func minutesAreClamped() {
        #expect(GuardHelper.minutes(0) == nil)
        #expect(GuardHelper.minutes(5) == 5)
        #expect(GuardHelper.minutes(-3) == 1)
        #expect(GuardHelper.minutes(10_000) == GuardHelper.maxMinutes)
    }

    // MARK: - Таймеры

    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func openAndDue() {
        var state = GuardHelperState()
        state.open([.ssh], minutes: 5, uid: 501, now: t0)
        state.open([.env], minutes: nil, uid: 501, now: t0)
        #expect(state.nextDeadline == t0 + 300)
        #expect(state.due(now: t0 + 299).isEmpty)
        #expect(state.due(now: t0 + 300).map(\.category) == [.ssh])
        state.close([.ssh])
        #expect(state.nextDeadline == nil)
        #expect(state.windows[.env]?.closesAt == nil)
    }

    @Test func reopeningExtendsFromNow() {
        var state = GuardHelperState()
        state.open([.ssh], minutes: 5, uid: 501, now: t0)
        state.open([.ssh], minutes: 5, uid: 501, now: t0 + 240)
        #expect(state.windows[.ssh]?.closesAt == t0 + 540)
        // Открыто с тех пор, как открыли впервые: журнал и экран считают от него.
        #expect(state.windows[.ssh]?.openedAt == t0)
    }

    @Test func atStartLocksOverdueAndEverythingFromBeforeReboot() {
        var state = GuardHelperState()
        state.open([.ssh], minutes: 5, uid: 501, now: t0)
        state.open([.env], minutes: nil, uid: 501, now: t0)
        state.open([.aws], minutes: 60, uid: 501, now: t0)
        // Root-часть перезапустилась через 10 минут без перезагрузки: ssh просрочен, остальное живёт.
        #expect(state.toLockAtStart(now: t0 + 600, bootTime: t0 - 3_600).map(\.category) == [.ssh])
        // Мак перезагрузился после открытия — закрываем всё, даже «до ручной блокировки».
        #expect(Set(state.toLockAtStart(now: t0 + 600, bootTime: t0 + 60).map(\.category)) == [.ssh, .env, .aws])
    }

    @Test func stateSurvivesRestart() throws {
        var state = GuardHelperState()
        state.open([.ssh], minutes: 5, uid: 501, now: t0)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(GuardHelperState.self, from: data) == state)
    }

    // MARK: - Журнал

    /// Журнал root-части пишется в формате guard: его читает тот же разбор,
    /// и таймер в крыле работает без изменений.
    @Test func journalLinesParseBack() {
        let zone = TimeZone(identifier: "Europe/Moscow")!
        let lines = [
            GuardJournal.line(.unlock(["ssh"], user: "me", minutes: 5), at: t0, timeZone: zone),
            GuardJournal.line(.unlock(["env"], user: "me", minutes: nil), at: t0 + 1, timeZone: zone),
            GuardJournal.line(.lock(["ssh"]), at: t0 + 2, timeZone: zone),
            GuardJournal.line(.autoLock(["env"], reason: .restart), at: t0 + 3, timeZone: zone),
            GuardJournal.line(.deny(["aws"], minutes: 5), at: t0 + 4, timeZone: zone),
        ]
        let entries = LegacyGuardLog.parse(lines.joined(separator: "\n"), timeZone: zone)
        #expect(entries.map(\.action) == [.unlock(.timer, timeout: 300), .unlock(.manual, timeout: nil), .lock, .lock, .deny])
        #expect(entries.map(\.category) == ["ssh", "env", "ssh", "env", "aws"])
        #expect(entries.first?.at == t0)
    }

    // MARK: - Окно Touch ID

    @Test func promptSaysExactlyWhatAndHowLong() {
        #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 5) == "Радарчик откроет SSH-ключи на 5 минут.")
        #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 1) == "Радарчик откроет SSH-ключи на 1 минуту.")
        #expect(GuardPhrase.unlockPrompt([.env], minutes: 60) == "Радарчик откроет ключи проектов на 1 час.")
        #expect(GuardPhrase.unlockPrompt([.ssh], minutes: nil) == "Радарчик откроет SSH-ключи до ручной блокировки.")
        #expect(GuardPhrase.unlockPrompt(GuardCategory.allCases, minutes: 15) == "Радарчик откроет все ключи на 15 минут.")
        english {
            #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 5) == "Radarchik will open SSH keys for 5 minutes.")
            #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 120) == "Radarchik will open SSH keys for 2 hours.")
        }
    }

    // MARK: - Кто просит (2026-10-20)

    /// Окно Touch ID может вызвать любая программа — в нём написано, кто попросил.
    @Test func promptSaysWhoAsks() {
        #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 10, command: "git push", requester: "zsh ← Terminal")
            == "Радарчик откроет SSH-ключи на время команды «git push». Просит: zsh ← Terminal.")
        #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 5, requester: "кнопка в чёлке") == "Радарчик откроет SSH-ключи на 5 минут. Просит: кнопка в чёлке.")
        english {
            #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 5, requester: "zsh ← Terminal") == "Radarchik will open SSH keys for 5 minutes. Requested by: zsh ← Terminal.")
        }
    }

    /// Окно для просьбы к ssh-agent (2026-10-21): что за ключ, зачем и кто просит.
    @Test func signPromptNamesKeyPurposeAndRequester() {
        #expect(GuardPhrase.signPrompt(key: "id_ed25519", action: .commit, place: "storefront", requester: "Claude Code ← zsh ← Terminal")
            == "Радарчик даст ключ id_ed25519 для подписи коммита в storefront. Просит: Claude Code ← zsh ← Terminal.")
        #expect(GuardPhrase.signPrompt(key: "id_ed25519", action: .login, place: "git@github.com", requester: "node install.js ← zsh ← Terminal")
            == "Радарчик даст ключ id_ed25519 для входа на git@github.com. Просит: node install.js ← zsh ← Terminal.")
        #expect(GuardPhrase.signPrompt(key: nil, action: .sign, place: nil, requester: nil) == "Радарчик даст SSH-ключ для подписи.")
        #expect(GuardPhrase.signPrompt(key: "k", action: .commit, place: nil, requester: nil) == "Радарчик даст ключ k для подписи коммита.")
        #expect(GuardPhrase.signPrompt(key: "k", action: .login, place: nil, requester: nil) == "Радарчик даст ключ k для входа по SSH.")
        english {
            #expect(GuardPhrase.signPrompt(key: "id_ed25519", action: .commit, place: "storefront", requester: "Claude Code ← zsh ← Terminal")
                == "Radarchik will hand over key id_ed25519 to sign a commit in storefront. Requested by: Claude Code ← zsh ← Terminal.")
            #expect(GuardPhrase.signPrompt(key: nil, action: .login, place: "git@github.com", requester: nil) == "Radarchik will hand over the SSH key to log in to git@github.com.")
        }
        // Имя ключа в окне — только как имя файла; остальное root-часть не покажет.
        #expect(GuardHelper.safeKeyName("id_ed25519") == "id_ed25519")
        #expect(GuardHelper.safeKeyName("work.key-2") == "work.key-2")
        #expect(GuardHelper.safeKeyName("жми ок") == nil)
        #expect(GuardHelper.safeKeyName("-rf") == nil)
        #expect(GuardHelper.safeKeyName(String(repeating: "a", count: 41)) == nil)
        #expect(GuardHelper.SignAction(rawValue: "evil") == nil)
    }

    /// Радарчику из чёлки (его запустила система, без флагов) верим: кто постучал в его
    /// сокет, он знает от ядра. Любой другой клиент — цепочку пишет сама root-часть,
    /// что бы он ни прислал.
    @Test func strangersCannotNameThemselves() {
        let app = ["/Applications/Radarchik.app/Contents/MacOS/Radarchik"]
        #expect(GuardHelper.requester(supplied: GuardHelper.notchButton, clientArguments: app, clientParent: 1, parentChain: "") == "кнопка в чёлке")
        #expect(GuardHelper.requester(supplied: "zsh ← Terminal", clientArguments: app, clientParent: 1, parentChain: "") == "zsh ← Terminal")
        #expect(GuardHelper.requester(supplied: "", clientArguments: app, clientParent: 1, parentChain: "") == "неизвестно кто")
        // `Radarchik --guard unlock ssh` из терминала: назваться кнопкой не выйдет.
        let cli = app + ["--guard", "unlock", "ssh"]
        #expect(GuardHelper.requester(supplied: GuardHelper.notchButton, clientArguments: cli, clientParent: 500, parentChain: "zsh ← Terminal")
            == "Radarchik --guard ← zsh ← Terminal")
        // Тот же бинарник без флагов, но запущенный скриптом, а не системой, — тоже не верим.
        #expect(GuardHelper.requester(supplied: "кнопка в чёлке", clientArguments: app, clientParent: 700, parentChain: "node install.js ← zsh ← Terminal")
            == "Radarchik ← node install.js ← zsh ← Terminal")
        // Клиент уже завершился — так и пишем.
        #expect(GuardHelper.requester(supplied: "zsh ← Terminal", clientArguments: [], clientParent: 0, parentChain: "") == "неизвестно кто")
    }

    /// В окне — только буквы, цифры, стрелки и немного знаков: ни кавычек, ни переводов
    /// строки. Программа с хитрым именем не допишет в окно «это безопасно, жми».
    @Test func requesterTextIsCleaned() {
        #expect(GuardHelper.safeRequester("evil «жми»\n← zsh") == "evil жми ← zsh")
        #expect(GuardHelper.safeRequester("   ") == nil)
        let cleaned = GuardHelper.safeRequester(String(repeating: "node ← ", count: 20))
        #expect((cleaned?.count ?? 0) <= 60)
        #expect(cleaned?.hasSuffix("…") == true)
    }
}
