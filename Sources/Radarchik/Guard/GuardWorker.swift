import Darwin
import Foundation
import RadarchikCore

/// Ключи для интерфейса: категории, сколько раз открывали сегодня и откуда список.
struct GuardKeysState: Sendable, Equatable {
    var categories: [CategoryStatus] = []
    var unlocksToday: [GuardCategory: Int] = [:]
    /// Чей список и журнал: root-части, старого guard или встроенный.
    var source = GuardSource.builtIn
}

/// Как ответили на тревогу «Защиты».
enum GuardResponse: Sendable {
    case kill
    case once
    case always
    case dismiss
}

/// Что посреднику делать с просьбой «подпиши» (`GuardWorker.agentPlan`).
enum AgentPlan: Sendable {
    case forward
    case ask(AgentAsk)
}

/// Всё для окна Touch ID и записи после него: ключ, действие, кто просит.
struct AgentAsk: Sendable {
    let key: String
    let action: GuardHelper.SignAction
    /// Репозиторий или адрес — для текста окна.
    let place: String?
    /// «Подпись коммита в storefront» — для журнала.
    let phrase: String
    let origin: AgentOrigin
    /// «Claude Code ← zsh ← Terminal» — строка «Просит: …».
    let requester: String
    let detail: String
    let graceKey: String
}

/// Фоновая половина «Защиты» (SPEC §3б): владельцы ключей, процессы, настройки
/// Claude Code и журнал — не на главном потоке, чтобы чёлка не подтормаживала.
/// Наружу отдаёт готовое, показывает `GuardMonitor`.
actor GuardWorker {
    private let repository: GuardRepository
    private let home = NSHomeDirectory()
    private let userUID = getuid()

    // MARK: Ключи
    /// Лежит ли файл в git — спрашиваем git раз в 10 минут, не чаще.
    private var tracked: [String: (inGit: Bool, at: Date)] = [:]
    private var logStamp: String?
    private var logEntries: [LegacyGuardLog.Entry] = []
    /// О каких «открыто слишком долго» уже сказали (по времени открытия).
    private var announcedOverdue: Set<Date> = []

    // MARK: Процессы
    /// Кого уже проверили: pid → «время запуска|программа». После exec программа
    /// меняется, а pid и время — нет, поэтому сверяем и её.
    private var seen: [Int32: String] = [:]
    private var isFirstPass = true
    /// Тревога → её процесс, чтобы «Убить» убил ровно его.
    private var processOf: [Int64: (pid: Int32, startTime: UInt64)] = [:]
    private var argumentsBuffer: [UInt8] = []

    // MARK: Настройки Claude
    private var auditStamp: String?
    private var auditFindings: [AuditFinding] = []

    // MARK: SSH-ключ в агенте
    /// Ключ (как его шлёт агент) → имя файла и защищён ли он списком.
    private var keyNames: [Data: (name: String, isProtected: Bool)] = [:]
    private var keyNamesAt: Date?
    /// Подтверждённое по Touch ID: «источник|действие» → до когда действует (`AgentGate.grace`).
    private var confirmedUntil: [String: Date] = [:]

    // MARK: Сеть
    /// Когда последний раз видели установку пакетов — зависимости после неё «свежие».
    private var installSeenAt: Date?
    /// Когда источник последний раз получал записку: вторая за минуту — тихо в журнал.
    private var networkNoteAt: [String: Date] = [:]
    /// Обратный DNS по адресу без имени — на час, nil тоже (нет записи или не успели).
    private var reverseNames: [String: (name: String?, at: Date)] = [:]

    init(databasePath: String) throws {
        repository = try GuardRepository(database: Database(path: databasePath))
        try? repository.purge(now: Date())
    }

    // MARK: - Ключи

    /// Кто владеет ключами сейчас и что из этого стоит сказать.
    func keys(now: Date) -> (state: GuardKeysState, events: [GuardEvent]) {
        let source = GuardSource.current
        let config = source.config()
        var files: [ProtectedFile] = []
        var paths = Set<String>()
        for rule in config.rules {
            for path in LockProbe.files(matching: GuardRules.expandHome(rule.pattern, home: home))
            where !GuardRules.isPublicKey(path) && paths.insert(path).inserted {
                guard let owner = LockProbe.owner(of: path) else { continue }
                let state = LockProbe.state(ownerUID: owner, userUID: userUID)
                // Исключения списка root-части — это файлы в git: спрашивать git ещё раз незачем.
                let inGit = config.excluded.contains(path) || isTracked(path, now: now)
                files.append(ProtectedFile(path: path, category: rule.category, state: state, inGit: inGit))
            }
        }
        // Журнал перечитываем, только когда он изменился (или сменился сам журнал).
        let stamp = source.logStamp()
        if stamp != logStamp {
            logStamp = stamp
            logEntries = source.logTail().map { LegacyGuardLog.parse($0) } ?? []
        }
        let categories = GuardStatus.categories(files, windows: LegacyGuardLog.windows(logEntries))
        let today = LegacyGuardLog.unlockCounts(logEntries, since: Calendar.current.startOfDay(for: now))
        return (GuardKeysState(categories: categories, unlocksToday: today, source: source), keyEvents(categories, now: now))
    }

    /// Открыто дольше таймера — сказать один раз на открытие. Новый ключ, который
    /// guard ещё не закрывал, — один раз в три дня, чтобы не зудеть.
    private func keyEvents(_ categories: [CategoryStatus], now: Date) -> [GuardEvent] {
        var events: [GuardEvent] = []
        for status in categories where status.isOpen {
            if let window = status.window, let closesAt = window.closesAt,
               now > closesAt.addingTimeInterval(GuardStatus.overdueGrace), !announcedOverdue.contains(window.openedAt) {
                announcedOverdue.insert(window.openedAt)
                let title = GuardPhrase.keys([status], now: now, unlocksToday: [:], home: home)
                if let event = try? repository.add(kind: .keys, level: .warning, at: now, title: title, detail: nil, allowKey: nil, status: .logged) {
                    events.append(event)
                }
            }
            guard status.window == nil else { continue }
            for file in status.openFiles {
                let key = "keys|" + file.path
                if let last = try? repository.lastSeen(key), now.timeIntervalSince(last) < 3 * 86_400 { continue }
                let title = GuardPhrase.keys([CategoryStatus(category: status.category, files: [file], window: nil)], now: now, unlocksToday: [:], home: home)
                if let event = try? repository.add(kind: .keys, level: .warning, at: now, title: title, detail: nil, allowKey: key, status: .logged) {
                    events.append(event)
                }
            }
        }
        return events
    }

    /// Закрыто ли что-то из того, что нужно команде (этап 3): есть ли у категории
    /// (в папке проекта, если она задана) файл у root. Файлы в git не считаются.
    func hasLockedFiles(_ need: KeyNeed) -> Bool {
        let config = GuardSource.current.config()
        for rule in config.rules where rule.category == need.category {
            for path in LockProbe.files(matching: GuardRules.expandHome(rule.pattern, home: home))
            where !GuardRules.isPublicKey(path) && (need.scope.map { path.hasPrefix($0 + "/") } ?? true) {
                guard LockProbe.owner(of: path) == 0 else { continue }
                if rule.category == .env && (config.excluded.contains(path) || isTracked(path, now: Date())) { continue }
                return true
            }
        }
        return false
    }

    private func isTracked(_ path: String, now: Date) -> Bool {
        if let cached = tracked[path], now.timeIntervalSince(cached.at) < 600 { return cached.inGit }
        let inGit = Git.isTracked(path)
        tracked[path] = (inGit, now)
        return inGit
    }

    // MARK: - Процессы

    /// Новые процессы с прошлого прохода (раз в 2 секунды). Возвращает то,
    /// о чём сказать в чёлке; в журнал пишется всё, кроме разрешённого навсегда.
    func watchProcesses(now: Date) -> [GuardEvent] {
        let firstPass = isFirstPass
        isFirstPass = false
        let allowed = (try? repository.allowedKeys()) ?? []
        let me = getpid()
        var alive: [Int32: String] = [:]
        var announce: [GuardEvent] = []
        for pid in ProcessArguments.allPids() where pid > 0 && pid != me {
            // Чужие процессы (root, система) не читаются — и не нужны: малварь из npm работает от тебя.
            guard let info = ProcessArguments.info(pid: pid), info.uid == userUID,
                  let path = ProcessArguments.path(of: pid) else { continue }
            let identity = "\(info.startTime)|\(path)"
            alive[pid] = identity
            guard seen[pid] != identity,
                  let command = ProcessArguments.read(pid: pid, buffer: &argumentsBuffer)
            else { continue }
            if NetworkRules.isInstall(command.arguments) { installSeenAt = now }
            let process = WatchedProcess(
                pid: pid, startTime: info.startTime, path: path, arguments: command.arguments,
                parentPath: ProcessArguments.path(of: info.ppid)
            )
            guard let finding = ProcessWatchRules.evaluate(process, home: home), !allowed.contains(finding.allowKey) else { continue }
            // Предупреждения про то, что работало ещё до запуска Радарчика, и повторы
            // за сутки — тихо в журнал. Критичное — всегда в чёлку, с кнопками.
            let repeated = (try? repository.lastSeen(finding.allowKey)).flatMap { $0 }.map { now.timeIntervalSince($0) < 86_400 } ?? false
            let isCritical = finding.level == .critical
            guard let event = try? repository.add(
                kind: .process, level: finding.level, at: now, title: GuardPhrase.process(finding), detail: finding.commandLine,
                allowKey: finding.allowKey, status: isCritical ? .active : .logged
            ) else { continue }
            if isCritical { processOf[event.id] = (pid, info.startTime) }
            if isCritical || !(firstPass || repeated) { announce.append(event) }
        }
        seen = alive
        return announce
    }

    /// Забыть, кого видели: слежку выключили — при включении проверим всех заново.
    func resetProcesses() {
        seen.removeAll()
        isFirstPass = true
    }

    /// Жив ли ещё процесс тревоги — от этого зависит, показывать ли «Убить».
    func isProcessAlive(_ eventId: Int64) -> Bool {
        guard let process = processOf[eventId], let info = ProcessArguments.info(pid: process.pid) else { return false }
        return info.startTime == process.startTime
    }

    // MARK: - Кто пользуется SSH-ключом

    /// Кто постучал в сокет терминала — цепочка от его процесса для окна Touch ID:
    /// «zsh ← Terminal» или «node install.js ← sh ← node npm ← zsh ← Terminal».
    func requesterChain(pid: Int32) -> String {
        pid > 0 ? AgentWatchRules.chainText(ProcessChain.read(pid: pid)) : ""
    }

    /// Просьба «подпиши» ещё не ушла агенту: что с ней делать (`AgentGate`). `.ask` —
    /// всё для окна Touch ID и для записи после ответа. `canAsk` — root-часть умеет `confirm`.
    func agentPlan(_ request: SSHAgentRelay.Request, now: Date, approvedShells: Set<Int32>, canAsk: Bool) -> AgentPlan {
        let use = describe(request.request, chain: request.chain, now: now)
        let verdict = AgentGate.verdict(
            origin: use.origin, isProtected: use.key.isProtected,
            approved: AgentWatchRules.isApproved(request.chain, origin: use.origin, shells: approvedShells),
            allowedAlways: (try? repository.isAllowed(use.alarmKey)) ?? false,
            confirmedUntil: confirmedUntil[use.graceKey], now: now, canAsk: canAsk
        )
        guard verdict == .ask else { return .forward }
        return .ask(AgentAsk(
            key: use.key.name, action: use.signAction, place: use.place, phrase: use.action, origin: use.origin,
            requester: AgentWatchRules.requesterText(request.chain, origin: use.origin), detail: use.detail, graceKey: use.graceKey
        ))
    }

    /// Подтвердил Touch ID: тому же источнику то же действие — без окна ещё `AgentGate.grace`.
    /// Запись в журнал сделает `agentUse`, когда агент подпишет.
    func agentConfirmed(_ ask: AgentAsk, now: Date) {
        confirmedUntil = confirmedUntil.filter { $0.value > now }
        confirmedUntil[ask.graceKey] = now.addingTimeInterval(AgentGate.grace)
    }

    /// Отменил окно или не подтвердил: клиент получил отказ. В журнал — ты уже видел, кто просил.
    func agentRefused(_ ask: AgentAsk, now: Date) {
        _ = try? repository.add(
            kind: .agent, level: .warning, at: now, title: GuardPhrase.agentRefused(ask.phrase, origin: ask.origin), detail: ask.detail,
            allowKey: nil, status: .logged
        )
    }

    /// Агент подписал по просьбе через посредника. Из терминала — запись в журнал,
    /// одно и то же не чаще раза в 10 минут. Скрипт, приложение, ИИ-агент или фоновый
    /// процесс — тревога, если ключ защищён и источник не разрешён «Всегда» (без root-части:
    /// с ней такое не доходит до агента без Touch ID — `agentPlan`). Пока тревога висит,
    /// вторую такую же не поднимаем. `approvedShells` — оболочки, для чьих команд ты
    /// только что открыл ключ по Touch ID: их обращение — запись, не тревога.
    func agentUse(_ signing: SSHAgentRelay.Signing, now: Date, approvedShells: Set<Int32> = []) -> [GuardEvent] {
        // Агент отказал — ключом не воспользовались.
        guard signing.signed else { return [] }
        let chain = signing.chain
        let use = describe(signing.request, chain: chain, now: now)
        let (origin, key, action, detail, alarmKey) = (use.origin, use.key, use.action, use.detail, use.alarmKey)
        let confirmed = confirmedUntil[use.graceKey].map { $0 > now } ?? false
        let approved = confirmed || AgentWatchRules.isApproved(chain, origin: origin, shells: approvedShells)
        if !approved, AgentWatchRules.isAlarm(origin), key.isProtected, !((try? repository.isAllowed(alarmKey)) ?? false) {
            guard !((try? repository.active()) ?? []).contains(where: { $0.allowKey == alarmKey }),
                  let event = try? repository.add(
                    kind: .agent, level: .critical, at: now, title: GuardPhrase.agentAlarm(action, origin: origin), detail: detail,
                    allowKey: alarmKey, status: .active
                  )
            else { return [] }
            // «Убить» — скрипт или клиент, ровно тот: pid и время запуска.
            if let info = ProcessArguments.info(pid: origin.pid) { processOf[event.id] = (origin.pid, info.startTime) }
            return [event]
        }
        let logKey = "agent-log|" + alarmKey + "|" + action
        if let last = try? repository.lastSeen(logKey), now.timeIntervalSince(last) < 600 { return [] }
        let suffix = if confirmed {
            L(" · подтвердил по Touch ID", " · confirmed via Touch ID")
        } else if approved && AgentWatchRules.isAlarm(origin) {
            L(" · ключ открыл сам по Touch ID", " · you opened the key via Touch ID")
        } else {
            ""
        }
        _ = try? repository.add(kind: .agent, level: .info, at: now, title: GuardPhrase.agentUse(action, origin: origin) + suffix, detail: detail, allowKey: logKey, status: .logged)
        return []
    }

    /// Одна просьба словами: откуда, каким ключом, что подписывают. Общее для решения
    /// до подписи (`agentPlan`) и записи после (`agentUse`).
    private func describe(_ request: SSHAgentProtocol.SignRequest, chain: [ProcessLink], now: Date) -> AgentUse {
        let origin = AgentWatchRules.origin(chain)
        let purpose = SSHSignPurpose(signedData: request.data)
        let destination = AgentWatchRules.destination(chain)
        // Подпись коммита: git запускает ssh-keygen в корне репозитория.
        let repository = chain.first?.cwd.flatMap { Git.repositoryRoot(containing: $0 + "/.") }.map { ($0 as NSString).lastPathComponent }
        let action = GuardPhrase.agentAction(purpose, destination: destination, place: repository)
        let key = keyInfo(request.keyBlob, now: now)
        let (signAction, place): (GuardHelper.SignAction, String?) = switch purpose {
        case .login: (.login, destination)
        case .signature("git"): (.commit, repository)
        default: (.sign, nil)
        }
        let alarmKey = AgentWatchRules.allowKey(origin)
        return AgentUse(
            origin: origin, key: key, action: action, signAction: signAction, place: place,
            // Вторая строка: каким ключом и кто кого запустил. Только имена программ, без аргументов.
            detail: L("ключ \(key.name)", "key \(key.name)") + " · " + AgentWatchRules.chainText(chain),
            alarmKey: alarmKey, graceKey: alarmKey + "|" + action
        )
    }

    private struct AgentUse {
        let origin: AgentOrigin
        let key: (name: String, isProtected: Bool)
        let action: String
        let signAction: GuardHelper.SignAction
        let place: String?
        let detail: String
        let alarmKey: String
        let graceKey: String
    }

    // MARK: - Сеть (2026-10-22)

    /// Соединения от root-части: что из этого наше и ново (`NetworkRules`). Пара
    /// «источник → адрес» считается один раз; известная — только счётчик. Возвращает
    /// то, о чём сказать: записки и тревоги. Тревога — с процессом для «Убить».
    func networkFlows(_ flows: [NetworkFlow], now: Date) async -> [GuardEvent] {
        var announce: [GuardEvent] = []
        let fresh = installSeenAt.map { now.timeIntervalSince($0) < NetworkRules.freshWindow } ?? false || recentCodeScan(now: now)
        for received in flows {
            guard !NetworkRules.isPrivate(received.address), !NetworkRules.isServicePort(received.port), !received.chain.isEmpty else { continue }
            let origin = AgentWatchRules.origin(received.chain)
            let scope = NetworkRules.scope(received.chain, origin: origin)
            guard scope != .ignore else { continue }
            // Имени из эфира нет (кэш резолвера, шифрованный DNS) — спросим обратный DNS с подтверждением.
            var flow = received
            if flow.names.isEmpty, let name = await reverseName(flow.address, now: now) { flow = flow.withNames([name]) }
            let host = NetworkRules.host(flow)
            let identity = NetworkRules.identity(flow.chain, origin: origin)
            let name = NetworkRules.name(flow.chain, origin: origin)
            let project = flow.chain.first?.cwd.flatMap { Git.repositoryRoot(containing: $0 + "/.") }.map { ($0 as NSString).lastPathComponent }
            if let known = (try? repository.networkSeen(identity: identity, host: host)) ?? nil {
                try? repository.touchNetworkSeen(identity: identity, name: name, host: host, project: project, level: known.level, at: flow.date)
                continue
            }
            guard var assessment = NetworkRules.assess(flow: flow, origin: origin, scope: scope, fresh: fresh, home: home) else { continue }
            let allowKey = NetworkRules.allowKey(identity: identity, host: host)
            let allowed = ((try? repository.isAllowed(allowKey)) ?? false) || ((try? repository.isAllowed(NetworkRules.allowKey(identity: identity, host: "*"))) ?? false)
            if allowed || (assessment.level == .warning && networkNoteAt[identity].map { now.timeIntervalSince($0) < 60 } == true) {
                assessment = NetworkRules.Assessment(level: .info, reasons: assessment.reasons)
            }
            try? repository.touchNetworkSeen(identity: identity, name: name, host: host, project: project, level: assessment.level, at: flow.date)
            let title: String = switch assessment.level {
            case .critical: GuardPhrase.networkAlarm(name: name, host: host, port: flow.port, reasons: assessment.reasons)
            case .warning: GuardPhrase.networkNote(name: name, host: host, port: flow.port, reasons: assessment.reasons)
            case .info: GuardPhrase.networkTitle(name: name, host: host, port: flow.port)
            }
            // Вторая строка: адрес за именем (или прокси) и кто кого запустил — без аргументов.
            var detail = AgentWatchRules.chainText(flow.chain)
            if let proxy = flow.proxy {
                detail = L("через прокси \(proxy)", "via proxy \(proxy)") + " · " + detail
            } else if host != flow.address {
                detail = flow.address + " · " + detail
            }
            guard let event = try? repository.add(
                kind: .network, level: assessment.level, at: flow.date, title: title, detail: detail, allowKey: allowKey,
                status: assessment.level == .critical ? .active : .logged
            ) else { continue }
            if assessment.level == .critical, let info = ProcessArguments.info(pid: flow.pid) { processOf[event.id] = (flow.pid, info.startTime) }
            if assessment.level == .warning { networkNoteAt[identity] = now }
            if assessment.level >= .warning { announce.append(event) }
        }
        return announce
    }

    /// Что видели и что сказали за сутки — экран «Сеть».
    func networkSummary(now: Date) -> NetworkSummary {
        let since = now.addingTimeInterval(-86_400)
        let seen = (try? repository.networkSeen(since: since)) ?? []
        let events = ((try? repository.events(since: since)) ?? []).filter { $0.kind == .network }
        return NetworkSummary(seen: seen, events: events)
    }

    /// Обратный DNS с подтверждением (`ReverseDNS`), не дольше полутора секунд, ответ — на час.
    private func reverseName(_ address: String, now: Date) async -> String? {
        if let cached = reverseNames[address], now.timeIntervalSince(cached.at) < 3_600 { return cached.name }
        let name = await Self.resolve(address, timeout: 1.5)
        reverseNames[address] = (name, now)
        if reverseNames.count > 2_000 { reverseNames = reverseNames.filter { now.timeIntervalSince($0.value.at) < 3_600 } }
        return name
    }

    /// Разрешение блокирующее — в отдельной задаче; не успело — nil, а она дорешает в фоне.
    nonisolated private static func resolve(_ address: String, timeout: Double) async -> String? {
        let lookup = Task.detached(priority: .utility) { ReverseDNS.confirmedName(address) }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await lookup.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Недавно был `git pull` или clone (проверка кода записала итог) — код в проекте свежий.
    private func recentCodeScan(now: Date) -> Bool {
        ((try? repository.events(since: now.addingTimeInterval(-NetworkRules.freshWindow))) ?? []).contains { $0.kind == .code }
    }

    /// Имя ключа и защищён ли он. Список перечитываем не чаще раза в минуту.
    /// Незнакомый ключ — по отпечатку; защищённым он считается, только если
    /// не нашлось ни одного `.pub` (тогда сравнивать не с чем — тревожимся обо всех).
    private func keyInfo(_ blob: Data, now: Date) -> (name: String, isProtected: Bool) {
        if keyNamesAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            keyNames = loadKeyNames()
            keyNamesAt = now
        }
        return keyNames[blob] ?? (String(SSHPublicKey.fingerprint(blob).prefix(19)) + "…", keyNames.isEmpty)
    }

    /// `.pub` рядом с защищёнными файлами и в `~/.ssh`: имя ключа — имя файла без `.pub`.
    /// Защищён — если сам приватный файл есть в списке «Защиты».
    private func loadKeyNames() -> [Data: (name: String, isProtected: Bool)] {
        var protected = Set<String>()
        for rule in GuardSource.current.config().rules {
            for path in LockProbe.files(matching: GuardRules.expandHome(rule.pattern, home: home)) where !GuardRules.isPublicKey(path) {
                protected.insert(path)
            }
        }
        var candidates = Set(protected.map { $0 + ".pub" })
        let folder = home + "/.ssh"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".pub") {
            candidates.insert(folder + "/" + name)
        }
        var result: [Data: (name: String, isProtected: Bool)] = [:]
        for publicPath in candidates {
            guard let line = try? String(contentsOfFile: publicPath, encoding: .utf8), let blob = SSHPublicKey.blob(fromLine: line) else { continue }
            let privatePath = String(publicPath.dropLast(".pub".count))
            result[blob] = ((privatePath as NSString).lastPathComponent, protected.contains(privatePath))
        }
        return result
    }

    // MARK: - Настройки Claude Code

    /// Проверка настроек, если файлы менялись. О критичном — тревога один раз
    /// на находку, остальное — в журнал и на экран.
    func audit(now: Date) -> (findings: [AuditFinding], events: [GuardEvent]) {
        let located = ClaudeConfigLocator.files(home: home)
        let stamp = located.map { "\($0.path):\(Self.modified($0.path))" }.joined(separator: "\n")
        guard stamp != auditStamp else { return (auditFindings, []) }
        auditStamp = stamp
        let files = located.compactMap { item -> ClaudeConfigFile? in
            guard let content = Self.read(item.path, limit: 512 * 1_024) else { return nil }
            let inGit = item.kind == .userSettings ? false : isTracked(item.path, now: now)
            return ClaudeConfigFile(path: item.path, kind: item.kind, content: content, inGit: inGit)
        }
        auditFindings = ClaudeConfigAudit.audit(files)
        var events: [GuardEvent] = []
        for finding in auditFindings {
            let key = "audit|" + finding.id
            guard (try? repository.lastSeen(key)).flatMap({ $0 }) == nil else { continue }
            let isCritical = finding.level == .critical
            if let event = try? repository.add(
                kind: .audit, level: finding.level, at: now, title: GuardPhrase.audit(finding, home: home), detail: nil,
                allowKey: key, status: isCritical ? .active : .logged
            ), isCritical {
                events.append(event)
            }
        }
        return (auditFindings, events)
    }

    private static func modified(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_mtimespec.tv_sec) : 0
    }

    private static func read(_ path: String, limit: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= limit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Журнал и ответы

    func event(_ id: Int64) -> GuardEvent? {
        try? repository.event(id)
    }

    func active() -> [GuardEvent] {
        (try? repository.active()) ?? []
    }

    /// За сутки, новые первыми — экран «Защита».
    func recent(now: Date) -> [GuardEvent] {
        (try? repository.events(since: now.addingTimeInterval(-86_400))) ?? []
    }

    /// Последние проверки кода — сколько бы дней назад они ни были.
    func lastScans(limit: Int) -> [GuardEvent] {
        let events = (try? repository.events(since: Date().addingTimeInterval(-Double(GuardRepository.retentionDays) * 86_400))) ?? []
        return Array(events.filter { $0.kind == .code }.prefix(limit))
    }

    func respond(_ id: Int64, with response: GuardResponse, now: Date) {
        guard let event = try? repository.event(id) else { return }
        switch response {
        case .kill:
            if let process = processOf[id] { ProcessArguments.kill(pid: process.pid, startTime: process.startTime) }
            try? repository.setStatus(id, .killed, at: now)
        case .once:
            try? repository.setStatus(id, .allowedOnce, at: now)
        case .always:
            if let key = event.allowKey { try? repository.allow(key, at: now) }
            try? repository.setStatus(id, .allowedAlways, at: now)
        case .dismiss:
            try? repository.setStatus(id, .dismissed, at: now)
        }
        processOf[id] = nil
    }
}

/// Где лежат настройки Claude Code: твои в `~/.claude` и проектные в папках с кодом
/// (на два уровня вглубь — как в guard: `~/work/<проект>` и `~/work/<группа>/<проект>`).
enum ClaudeConfigLocator {
    static let roots = ["work", "projects", "Developer", "code", "src"]

    static func files(home: String) -> [(path: String, kind: ClaudeConfigKind)] {
        var found: [(String, ClaudeConfigKind)] = []
        for name in ["settings.json", "settings.local.json"] where FileManager.default.fileExists(atPath: "\(home)/.claude/\(name)") {
            found.append(("\(home)/.claude/\(name)", .userSettings))
        }
        for root in roots.map({ "\(home)/\($0)" }) where isFolder(root) {
            for project in [root] + subfolders(root) + subfolders(root).flatMap(subfolders) {
                found += projectFiles(project)
            }
        }
        return found
    }

    private static func projectFiles(_ folder: String) -> [(String, ClaudeConfigKind)] {
        let candidates: [(String, ClaudeConfigKind)] = [
            ("\(folder)/.claude/settings.json", .projectSettings),
            ("\(folder)/.claude/settings.local.json", .projectLocalSettings),
            ("\(folder)/.mcp.json", .mcp),
            ("\(folder)/CLAUDE.md", .claudeMd),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.0) }
    }

    private static func subfolders(_ folder: String) -> [String] {
        let skipped: Set<String> = ["node_modules", "vendor", "Library", "build", "dist", "tmp"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") && !skipped.contains($0) }.map { "\(folder)/\($0)" }.filter(isFolder)
    }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        // lstat: по ссылкам на папки не ходим — так не уйдём в цикл.
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
