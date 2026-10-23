import Darwin
import Foundation
import RadarchikCore
import Security

/// Чей запрос: имя, группа и домашняя папка — из учётной записи macOS по uid
/// соединения, а не со слов клиента.
struct Account: Sendable {
    let uid: uid_t
    let gid: gid_t
    let name: String
    let home: String

    init?(uid: uid_t) {
        guard uid != 0 else { return nil }
        var entry = passwd()
        var buffer = [CChar](repeating: 0, count: 4_096)
        var result: UnsafeMutablePointer<passwd>?
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil,
              let name = entry.pw_name, let home = entry.pw_dir
        else { return nil }
        self.uid = uid
        self.gid = entry.pw_gid
        self.name = String(cString: name)
        self.home = String(cString: home)
    }

    init?(name: String) {
        guard let entry = getpwnam(name) else { return nil }
        self.init(uid: entry.pointee.pw_uid)
    }
}

/// Открыть, закрыть, таймеры, журнал. Всё состояние — только из одной очереди;
/// окно Touch ID ждёт палец вне её, чтобы таймеры автозакрытия шли и тогда.
final class HelperEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.kuzmenko.radarchik.guardd.engine")
    private var state = GuardHelperState()
    private var timer: DispatchSourceTimer?
    /// «Сетевой надзор»: захват идёт, пока Радарчик спрашивает.
    private let sniffer = NetworkSniffer()
    private var lastNetworkPoll: Date?
    private var networkIdleTimer: DispatchSourceTimer?
    private static let networkIdle: TimeInterval = 120

    /// При запуске: что просрочено или открыто до перезагрузки — закрыть сразу.
    func start() {
        queue.sync {
            state = Self.loadState()
            let boot = Self.bootTime()
            for window in state.toLockAtStart(now: Date(), bootTime: boot) {
                if let account = Account(uid: window.uid) { _ = setOwner([window.category], account: account, toUser: false) }
                state.close([window.category])
                journal(.autoLock([window.category.rawValue], reason: window.openedAt < boot ? .restart : .timeout))
            }
            saveState()
            schedule()
        }
    }

    // MARK: - Открыть и закрыть

    /// Открыть категорию (или только её файлы в папке проекта `scope`) после Touch ID.
    /// `command` — подпись команды терминала для окна; непохожую на команду не показываем.
    /// `requester` — кто просит, со слов клиента; верим ему, только если клиент —
    /// Радарчик из чёлки, иначе цепочку клиента читаем сами (`GuardHelper.requester`).
    func unlock(
        categoryName: String, scope rawScope: String, minutes rawMinutes: Int, command rawCommand: String, requester rawRequester: String,
        language: String, authorization: Data, uid: uid_t, clientPid: pid_t, reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        let language = Language(rawValue: language) ?? .en
        guard let categories = GuardHelper.categories(categoryName), let account = Account(uid: uid),
              let scope = Self.scope(rawScope, account: account)
        else {
            reply(false, Language.$override.withValue(language) { L("Не понял, что открыть", "Didn’t understand what to open") })
            return
        }
        let minutes = GuardHelper.minutes(rawMinutes)
        let command = GuardHelper.isSafeCommandLabel(rawCommand) ? rawCommand : nil
        let project = scope.isEmpty ? nil : (scope as NSString).lastPathComponent
        let names = categoryName == "all" ? ["all"] : categories.map(\.rawValue)
        // Цепочку клиента root-часть читает у ядра сама: от root видно любой процесс.
        let client = ProcessChain.read(pid: clientPid)
        let prompt = Language.$override.withValue(language) {
            let requester = GuardHelper.requester(
                supplied: rawRequester, clientArguments: client.first?.arguments ?? [],
                clientParent: ProcessArguments.info(pid: clientPid)?.ppid ?? 0,
                parentChain: AgentWatchRules.chainText(Array(client.dropFirst()))
            )
            return GuardPhrase.unlockPrompt(categories, minutes: minutes, project: project, command: command, requester: requester)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = Authorizer.authorize(externalForm: authorization, right: GuardHelper.unlockRight, prompt: prompt)
            self.queue.async {
                self.releaseExcluded(account)
                guard status == errAuthorizationSuccess else {
                    self.journal(.deny(names, minutes: minutes))
                    reply(false, Language.$override.withValue(language) { Authorizer.message(status) })
                    return
                }
                let failures = self.setOwner(categories, account: account, toUser: true, scope: scope)
                self.state.open(categories, minutes: minutes, uid: account.uid, now: Date())
                self.saveState()
                self.journal(.unlock(names, user: account.name, minutes: minutes, scope: scope.isEmpty ? nil : scope))
                self.schedule()
                reply(true, failures.isEmpty ? nil : Language.$override.withValue(language) { Self.describe(failures, home: account.home) })
            }
        }
    }

    /// Touch ID для просьбы к ssh-agent (договор 3, 2026-10-21): посредник Радарчика
    /// придержал «подпиши» от чужого источника и ждёт. Файлы не трогаем — только окно.
    /// Текст — из проверенных кусков: имя ключа, что подписывают и где; кто просит —
    /// по тем же правилам, что у `unlock`.
    func confirm(
        key rawKey: String, action rawAction: String, place rawPlace: String, requester rawRequester: String, language: String, authorization: Data,
        uid: uid_t, clientPid: pid_t, reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        let language = Language(rawValue: language) ?? .en
        guard Account(uid: uid) != nil else {
            reply(false, Language.$override.withValue(language) { L("Не понял, чей ключ", "Didn’t understand whose key") })
            return
        }
        let client = ProcessChain.read(pid: clientPid)
        let prompt = Language.$override.withValue(language) {
            let requester = GuardHelper.requester(
                supplied: rawRequester, clientArguments: client.first?.arguments ?? [],
                clientParent: ProcessArguments.info(pid: clientPid)?.ppid ?? 0,
                parentChain: AgentWatchRules.chainText(Array(client.dropFirst()))
            )
            return GuardPhrase.signPrompt(
                key: GuardHelper.safeKeyName(rawKey), action: GuardHelper.SignAction(rawValue: rawAction) ?? .sign,
                place: GuardHelper.safeRequester(rawPlace), requester: requester
            )
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = Authorizer.authorize(externalForm: authorization, right: GuardHelper.unlockRight, prompt: prompt)
            guard status == errAuthorizationSuccess else {
                reply(false, Language.$override.withValue(language) { Authorizer.message(status) })
                return
            }
            reply(true, nil)
        }
    }

    /// «Сетевой надзор» (договор 4): новые соединения после `since`. Первый вызов включает
    /// захват, таймер выключает его через `networkIdle` без вызовов — выключил надзор в
    /// Радарчике или закрыл его, и root-часть снова ничего не слушает.
    func networkFlows(since: UInt64, uid: uid_t, reply: @escaping @Sendable (Data, UInt64, String?) -> Void) {
        queue.async {
            self.lastNetworkPoll = Date()
            self.sniffer.start()
            self.scheduleNetworkIdle()
            // Только соединения процессов самого пользователя: чужие его не касаются.
            let result = self.sniffer.flows(since: since, uid: uid)
            let data = (try? JSONEncoder().encode(result.flows)) ?? Data()
            reply(data, result.next, result.error)
        }
    }

    private func scheduleNetworkIdle() {
        guard networkIdleTimer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        source.setEventHandler { [weak self] in
            guard let self, let last = lastNetworkPoll, Date().timeIntervalSince(last) > Self.networkIdle else { return }
            sniffer.stop()
            networkIdleTimer?.cancel()
            networkIdleTimer = nil
        }
        source.resume()
        networkIdleTimer = source
    }

    /// Закрыть можно без Touch ID: это только прибавляет защиты. Закрыли одну папку,
    /// а в категории ещё что-то открыто — таймер категории остаётся и закроет остальное.
    func lock(categoryName: String, scope rawScope: String, language: String, uid: uid_t, reply: @escaping @Sendable (Bool, String?) -> Void) {
        let language = Language(rawValue: language) ?? .en
        queue.async {
            guard let categories = GuardHelper.categories(categoryName), let account = Account(uid: uid),
                  let scope = Self.scope(rawScope, account: account)
            else {
                reply(false, Language.$override.withValue(language) { L("Не понял, что закрыть", "Didn’t understand what to lock") })
                return
            }
            self.releaseExcluded(account)
            let failures = self.setOwner(categories, account: account, toUser: false, scope: scope)
            self.state.close(categories.filter { !self.anyOpen($0, account: account) })
            self.saveState()
            self.journal(.lock(categoryName == "all" ? ["all"] : categories.map(\.rawValue), scope: scope.isEmpty ? nil : scope))
            self.schedule()
            reply(true, failures.isEmpty ? nil : Language.$override.withValue(language) { Self.describe(failures, home: account.home) })
        }
    }

    /// Папка проекта из запроса: пусто — вся категория; иначе только внутри домашней
    /// папки и без «..». nil — запрос отклоняется.
    private static func scope(_ raw: String, account: Account) -> String? {
        guard !raw.isEmpty else { return "" }
        let parts = raw.split(separator: "/").map(String.init)
        guard raw.hasPrefix(account.home + "/"), !parts.contains(".."), !parts.contains(".") else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Что не секрет, но старый guard держал у root, — отдаём тебе насовсем:
    /// - ключи проектов из исключений (лежат в git): иначе `git add` падает
    ///   на test.key. Только `env`: SSH, AWS, GPG исключениями не бывают,
    ///   что бы ни было записано в списке;
    /// - публичные ключи (`*.pub`): guard закрывал их вместе с приватными
    ///   (`~/.ssh/id_*`), а подпись коммитов SSH-ключом читает именно `.pub` —
    ///   `git commit` падал с «Couldn't load public key».
    private func releaseExcluded(_ account: Account) {
        let config = GuardConfig.parse((try? String(contentsOfFile: GuardHelper.configPath, encoding: .utf8)) ?? "")
        let projectKeys = Set(matches(config, .env, account: account))
        let excluded = config.excluded.filter { projectKeys.contains($0) }
        let publicKeys = GuardCategory.allCases.flatMap { matches(config, $0, account: account) }.filter(GuardRules.isPublicKey)
        for path in Set(excluded + publicKeys) where LockProbe.owner(of: path) == 0 {
            _ = SafeOwnership.set(path, home: account.home, owner: account.uid, group: account.gid, mode: 0o644, allowedOwners: [0])
        }
    }

    /// Все файлы по правилам категории — вместе с исключениями.
    private func matches(_ config: GuardConfig, _ category: GuardCategory, account: Account) -> [String] {
        config.rules.filter { $0.category == category && $0.pattern.hasPrefix("~/") }.flatMap {
            LockProbe.files(matching: GuardRules.expandHome($0.pattern, home: account.home))
        }
    }

    /// Есть ли в категории ещё открытые файлы.
    private func anyOpen(_ category: GuardCategory, account: Account) -> Bool {
        files([category], account: account).contains { LockProbe.owner(of: $0) == account.uid }
    }

    /// Для установщика: отдать тебе файлы из исключений, которые старый guard держал у root.
    static func releaseExcluded(userName: String) -> Int32 {
        guard let account = Account(name: userName) else {
            FileHandle.standardError.write(Data("Нет такого пользователя: \(userName)\n".utf8))
            return 1
        }
        let engine = HelperEngine()
        engine.queue.sync { engine.releaseExcluded(account) }
        return 0
    }

    /// Перед удалением root-части: вернуть все ключи пользователю (`sudo … --release-all <user>`).
    static func releaseAll(userName: String) -> Int32 {
        guard let account = Account(name: userName) else {
            FileHandle.standardError.write(Data("Нет такого пользователя: \(userName)\n".utf8))
            return 1
        }
        let engine = HelperEngine()
        return engine.queue.sync {
            let failures = engine.setOwner(GuardCategory.allCases, account: account, toUser: true)
            engine.state = GuardHelperState()
            engine.saveState()
            engine.journal(.unlock(["all"], user: account.name, minutes: nil))
            for (path, failure) in failures { print("не тронут: \(path) — \(failure)") }
            return 0
        }
    }

    // MARK: - Файлы

    /// Файлы категорий по списку: только `~/…` (внутри домашней папки), без публичных
    /// ключей и без исключений — исключения действуют только для ключей проектов;
    /// со `scope` — только внутри этой папки.
    private func files(_ categories: [GuardCategory], account: Account, scope: String = "") -> [String] {
        let config = GuardConfig.parse((try? String(contentsOfFile: GuardHelper.configPath, encoding: .utf8)) ?? "")
        var paths: [String] = []
        var seen = Set<String>()
        for rule in config.rules where categories.contains(rule.category) && rule.pattern.hasPrefix("~/") {
            for path in LockProbe.files(matching: GuardRules.expandHome(rule.pattern, home: account.home))
            where !GuardRules.isPublicKey(path) && !(rule.category == .env && config.excluded.contains(path))
                && (scope.isEmpty || path.hasPrefix(scope + "/")) && seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    /// Открыть — владелец ты, закрыть — root. Права в обоих случаях 600.
    /// Каждый файл — через `SafeOwnership`: без ссылок, без жёстких ссылок, только внутри дома.
    private func setOwner(_ categories: [GuardCategory], account: Account, toUser: Bool, scope: String = "") -> [(String, SafeOwnership.Failure)] {
        files(categories, account: account, scope: scope).compactMap { path in
            let failure = SafeOwnership.set(
                path, home: account.home, owner: toUser ? account.uid : 0, group: toUser ? account.gid : 0, mode: 0o600,
                allowedOwners: [0, account.uid]
            )
            return failure.map { (path, $0) }
        }
    }

    /// «Не тронул 1 файл: ~/.ssh/id_x — это ссылка».
    private static func describe(_ failures: [(String, SafeOwnership.Failure)], home: String) -> String {
        let count = failures.count
        let files = Words.plural(count, ru: ("файл", "файла", "файлов"), en: ("file", "files"))
        let first = failures[0]
        let reason: String = switch first.1 {
        case .symlink: L("это ссылка", "it’s a symlink")
        case .hardLinked: L("у него жёсткие ссылки", "it has hard links")
        case .notRegularFile: L("это не обычный файл", "it isn’t a regular file")
        case .foreignOwner: L("у него чужой владелец", "someone else owns it")
        case .outsideHome: L("он вне домашней папки", "it’s outside the home folder")
        case .missing: L("его уже нет", "it’s gone")
        case .system(let code): String(cString: strerror(code))
        }
        return L("Не тронул \(count) \(files): ", "Left \(count) \(files) alone: ") + ShellRedactor.shortenHome(first.0, home: home) + " — " + reason
    }

    // MARK: - Таймер

    /// Один таймер на ближайшее автозакрытие. По часам на стене: мак спал — по
    /// пробуждении закроется сразу.
    private func schedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = state.nextDeadline else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(wallDeadline: .now() + max(deadline.timeIntervalSinceNow, 0), leeway: .seconds(1))
        source.setEventHandler { [weak self] in self?.fire() }
        source.resume()
        timer = source
    }

    private func fire() {
        for window in state.due(now: Date()) {
            if let account = Account(uid: window.uid) { _ = setOwner([window.category], account: account, toUser: false) }
            state.close([window.category])
            journal(.autoLock([window.category.rawValue], reason: .timeout))
        }
        saveState()
        schedule()
    }

    private static func bootTime() -> Date {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }

    // MARK: - Состояние и журнал (в папке root)

    private static func loadState() -> GuardHelperState {
        guard let data = FileManager.default.contents(atPath: GuardHelper.statePath),
              let state = try? JSONDecoder().decode(GuardHelperState.self, from: data)
        else { return GuardHelperState() }
        return state
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Пишем во временный файл рядом и переименовываем: папка — root, подсунуть ничего нельзя.
        try? data.write(to: URL(fileURLWithPath: GuardHelper.statePath), options: .atomic)
        chmod(GuardHelper.statePath, 0o600)
    }

    /// Журнал в формате guard — Радарчик читает его тем же разбором. Больше 2 МБ —
    /// оставляем последний мегабайт.
    private func journal(_ action: GuardJournal.Action) {
        let text = GuardJournal.lines(action, at: Date()).joined(separator: "\n") + "\n"
        let file = open(GuardHelper.journalPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { return }
        _ = text.withCString { write(file, $0, strlen($0)) }
        var info = stat()
        let size = fstat(file, &info) == 0 ? info.st_size : 0
        close(file)
        guard size > 2_000_000, let data = FileManager.default.contents(atPath: GuardHelper.journalPath) else { return }
        var tail = data.suffix(1_000_000)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[(newline + 1)...] }
        try? Data(tail).write(to: URL(fileURLWithPath: GuardHelper.journalPath), options: .atomic)
        chmod(GuardHelper.journalPath, 0o644)
    }
}
