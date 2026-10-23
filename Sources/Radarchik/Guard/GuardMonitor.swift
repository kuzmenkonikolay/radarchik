import Foundation
import Observation
import RadarchikCore

/// «Защита» для интерфейса (SPEC §3б). Раз в 2 секунды просит `GuardWorker`
/// проверить новые процессы, чаще или реже — ключи, раз в 5 минут — настройки
/// Claude Code, и держит готовое для чёлки: крыло с таймером, тревоги, экран.
///
/// Как Радарчик говорит:
/// - опасное (процесс, код после git pull, хуки из чужого репозитория) — записка
///   под чёлкой, лицо беспокоится, на сводке облачко с кнопками, пока не ответишь;
///   на звонке тоже, потому что это важнее цифр;
/// - «стоит глянуть» — только записка, и то не на звонке и не когда тебя нет;
/// - мелочь — в журнал на экране «Защита».
@MainActor
@Observable
final class GuardMonitor {
    private(set) var keys = GuardKeysState()
    /// Ждут ответа, старые первыми: показываем по одной.
    private(set) var alerts: [GuardEvent] = []
    /// Журнал за сутки, новые первыми.
    private(set) var recent: [GuardEvent] = []
    /// Последние проверки кода.
    private(set) var scans: [GuardEvent] = []
    private(set) var audit: [AuditFinding] = []
    /// О чём сказать прямо сейчас: по нему чёлка раскрывает алерт (опасное — с кнопками,
    /// «стоит глянуть» — с «Показать / Понятно»). Очередь — `pending`.
    private(set) var announcement: GuardEvent?
    /// Git-хуки Радарчика подключены (`core.hooksPath`).
    private(set) var hooksConnected = false
    /// Тикает раз в секунду, пока в крыле идёт обратный отсчёт.
    private(set) var now = Date()
    /// Тревоги о процессах, которые ещё живы: только им нужна кнопка «Убить».
    private(set) var aliveProcesses: Set<Int64> = []
    /// Root-часть (этап 2): стоит ли, отвечает ли и не старая ли.
    private(set) var helper = HelperStatus.unknown
    /// Что сейчас открываем или закрываем («ssh», «all»): кнопка ждёт ответа.
    private(set) var inFlight: Set<String> = []
    /// Слежка за SSH-ключом: посредник перед ssh-agent работает.
    private(set) var agentWatching = false
    /// «Сетевой надзор» (2026-10-22): что видели и что сказали за сутки.
    private(set) var network = NetworkSummary()
    /// Root-часть отдаёт соединения; false — не спрашивали, нет root-части или захват не идёт.
    private(set) var networkWatching = false
    /// Почему захват не идёт — словами root-части.
    private(set) var networkError: String?
    var lastError: String?

    enum HelperStatus: Equatable {
        case unknown
        case notInstalled
        case ready
        /// Стоит старее, чем ждёт Радарчик: переставить `make install-guard`.
        case outdated(Int)
        case unreachable
    }

    /// Открывать и закрывать отсюда можно, когда root-часть на месте — пусть и старее
    /// договора: открыть и закрыть она умеет с версии `unlockVersion`.
    var canUnlock: Bool {
        switch helper {
        case .ready: true
        case .outdated(let version): version >= GuardHelper.unlockVersion
        default: false
        }
    }

    /// Touch ID для просьбы к ssh-agent (`confirm`) — только у root-части текущего договора.
    var canConfirm: Bool { helper == .ready }

    var activeAlert: GuardEvent? { settings.guardEnabled ? alerts.first : nil }
    var wing: GuardWing? { settings.guardEnabled ? GuardStatus.wing(keys.categories, now: now) : nil }
    /// Главное о ключах — карточка экрана «Защита».
    var keysHeadline: String { GuardPhrase.keysHeadline(keys.categories, now: now) }
    /// Коротко — строка на сводке.
    var keysLine: String { GuardPhrase.keysLine(keys.categories, now: now, unlocksToday: keys.unlocksToday) }

    /// Чёлка раскрыта: записка не нужна, тревога и так в облачке. Задаёт `NotchController`.
    @ObservationIgnored var isPanelExpanded: () -> Bool = { false }

    private let worker: GuardWorker
    private let settings: AppSettings
    private let tracker: ActivityTracker
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    /// Что ещё не сказали: по одной записке за раз.
    @ObservationIgnored private var pending: [GuardEvent] = []
    /// Сокет для git-хука: «проверил код, запись такая-то» (`--codescan`).
    @ObservationIgnored private var socket: ShellSocketServer?
    /// Сокет для zsh-хука (этап 3): «нужны ли ключи этой команде» и «команда закончилась».
    @ObservationIgnored private var shellServer: LineSocketServer?
    /// Что открыто под команды терминала: «категория|папка» → сколько команд его ждут.
    /// Закрываем, когда закончилась последняя.
    @ObservationIgnored private var commandHolds: [String: Int] = [:]
    /// Команда (метка от хука) → что открыто для неё и когда.
    /// Команды терминала, для которых открыли ключ: что открыли, когда и из какой оболочки (pid).
    @ObservationIgnored private var commandTokens: [String: (needs: [KeyNeed], at: Date, shell: Int32)] = [:]
    /// Посредник перед ssh-agent: через него терминал ходит к ключу.
    @ObservationIgnored private var agentRelay: SSHAgentRelay?
    /// Решения по просьбам «подпиши» идут по одному: второе окно Touch ID не нужно,
    /// если первое уже подтвердило то же самое.
    @ObservationIgnored private var gateChain: Task<Void, Never>?
    /// Сколько ждём решения, пока клиент висит на посреднике; дольше — отказ.
    nonisolated private static let gateTimeout: TimeInterval = 5 * 60
    /// До какого номера соединения root-части уже разобраны; nil — ещё не спрашивали.
    @ObservationIgnored private var networkSequence: UInt64?
    /// После ошибки root-части сеть не спрашиваем до этого прохода.
    @ObservationIgnored private var networkRetryTick = 0

    /// Сколько висит записка.
    private static let announcementDuration: Duration = .seconds(8)
    /// Несказанное «стоит глянуть» старше этого уже не новость.
    private static let pendingLifetime: TimeInterval = 15 * 60

    init(worker: GuardWorker, settings: AppSettings, tracker: ActivityTracker) {
        self.worker = worker
        self.settings = settings
        self.tracker = tracker
    }

    func start() {
        guard settings.guardEnabled else { return }
        do {
            try GitHooks.install()
        } catch {
            lastError = L("Не вышло записать git-хуки: \(error.localizedDescription)", "Couldn’t write the git hooks: \(error.localizedDescription)")
        }
        startSocket()
        startShellServer()
        startAgentRelay()
        startLoop()
        checkHelper()
    }

    // MARK: - Тумблеры

    func setEnabled(_ enabled: Bool) {
        settings.guardEnabled = enabled
        if enabled {
            start()
        } else {
            loopTask?.cancel()
            loopTask = nil
            clockTask?.cancel()
            clockTask = nil
            socket?.stop()
            socket = nil
            shellServer?.stop()
            shellServer = nil
            stopAgentRelay()
            dismissAnnouncement()
            pending.removeAll()
            Task { await worker.resetProcesses() }
        }
    }

    func setWatchProcesses(_ enabled: Bool) {
        settings.guardWatchProcesses = enabled
        // Включили снова — проверить всех, кто работает сейчас, а не только новых.
        Task { await worker.resetProcesses() }
    }

    func setAuditClaude(_ enabled: Bool) {
        settings.guardAuditClaude = enabled
        if !enabled { audit = [] }
    }

    /// «Сетевой надзор». Выключили — root-часть сама остановит захват через две минуты без вопросов.
    func setWatchNetwork(_ enabled: Bool) {
        settings.guardWatchNetwork = enabled
        if !enabled {
            networkWatching = false
            networkSequence = nil
        }
    }

    // MARK: - Открыть и закрыть (root-часть, этап 2)

    /// Стоит ли root-часть и отвечает ли — при запуске и при открытии экрана «Защита».
    func checkHelper() {
        Task {
            guard GuardHelper.isInstalled else {
                helper = .notInstalled
                return
            }
            guard let version = await GuardHelperClient.version() else {
                helper = .unreachable
                return
            }
            helper = version < GuardHelper.version ? .outdated(version) : .ready
        }
    }

    /// Открыть по Touch ID: категорию или всё (nil). Окно покажет macOS, текст в нём
    /// напишет root-часть — с «Просит: кнопка в чёлке». Отменил окно — молча ничего.
    func unlock(_ category: GuardCategory?, minutes: Int = GuardHelper.defaultMinutes) {
        perform(category) { try await GuardHelperClient.unlock($0, minutes: minutes, requester: GuardHelper.notchButton) }
    }

    /// Закрыть сейчас — без Touch ID.
    func lock(_ category: GuardCategory?) {
        perform(category) { try await GuardHelperClient.lock($0) }
    }

    /// Пока открыто через root-часть: ещё 5 минут от сейчас (снова Touch ID — это тоже открытие).
    func extend(_ category: GuardCategory) {
        unlock(category, minutes: GuardHelper.defaultMinutes)
    }

    private func perform(_ category: GuardCategory?, _ request: @escaping @Sendable (String) async throws -> String?) {
        let name = category?.rawValue ?? "all"
        guard !inFlight.contains(name) else { return }
        inFlight.insert(name)
        Task {
            do {
                if let warning = try await request(name) { lastError = warning }
            } catch is CancellationError {
                // Отменил окно Touch ID — это ответ, а не ошибка.
            } catch {
                lastError = error.localizedDescription
                if case GuardHelperError.unavailable = error { helper = .unreachable }
            }
            inFlight.remove(name)
            await refreshKeysNow()
        }
    }

    /// Журнал root-части уже записан — сразу показать новый замок и таймер.
    private func refreshKeysNow() async {
        let (state, events) = await worker.keys(now: Date())
        if keys != state { keys = state }
        updateClock()
        for event in events { enqueue(event) }
    }

    // MARK: - Ключи под команду терминала (этап 3)

    private func startShellServer() {
        guard shellServer == nil else { return }
        let server = LineSocketServer(path: GuardShellSocket.path) { [weak self] line, peer, reply in
            Task { @MainActor in
                guard let self else { return reply("ok") }
                self.shellLine(line, peer: peer, reply: reply)
            }
        }
        do {
            try server.start()
            shellServer = server
        } catch {
            lastError = L("Не вышло открыть сокет для терминала: \(error)", "Couldn’t open the terminal socket: \(error)")
        }
    }

    /// От zsh-хука: `need<TAB>метка<TAB>папка<TAB>команда` перед командой,
    /// `done<TAB>метка` после неё. На любой вопрос — ответ, иначе хук ждал бы зря.
    /// `peer` — pid того, кто постучал (от ядра): из него — «Просит: …» в окне Touch ID.
    private func shellLine(_ line: String, peer: Int32, reply: @escaping LineSocketServer.Reply) {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "need" where parts.count == 4:
            Task { reply(await commandNeeds(token: parts[1], cwd: parts[2], command: parts[3], peer: peer)) }
        case "done" where parts.count >= 2:
            // Хук ответа не ждёт и уже закрыл соединение: только закрыть со своей стороны.
            reply("")
            commandDone(token: parts[1])
        default:
            Log.guardFlow.notice("терминал: непонятная строка (\(parts.count) частей)")
            reply("ok")
        }
    }

    /// Нужны ли команде ключи и закрыты ли они. Да — Touch ID через root-часть,
    /// открыть на время команды (с запасом `commandMinutes`, если терминал закроют посреди).
    /// Ответ хуку: «ok» — ничего не нужно, «opened…» — открыл, «cancelled» — отменил окно,
    /// «hint<TAB>текст» — нужно, но root-части нет: хук напечатает подсказку.
    private func commandNeeds(token: String, cwd: String, command: String, peer: Int32) async -> String {
        guard settings.guardEnabled else { return "ok" }
        let needs = CommandKeys.needs(command, context: ShellContext.make(cwd: cwd))
        var locked: [KeyNeed] = []
        for need in needs where await worker.hasLockedFiles(need) { locked.append(need) }
        let label = CommandKeys.label(command)
        Log.guardFlow.notice("""
            need \(token, privacy: .public): «\(label ?? "?", privacy: .public)», нужно \(Self.names(needs), privacy: .public), \
            закрыто \(Self.names(locked), privacy: .public), root-часть \(String(describing: self.helper), privacy: .public)
            """)
        guard !locked.isEmpty else { return "ok" }
        guard canUnlock else { return "hint\t" + GuardPhrase.commandHint(command: label, needs: locked) }
        // Кто постучал в сокет: обычно сама оболочка вкладки — «zsh ← Terminal».
        let requester = await worker.requesterChain(pid: peer)
        Log.guardFlow.notice("need \(token, privacy: .public): просит \(requester, privacy: .public)")

        var opened: [KeyNeed] = []
        for need in locked {
            do {
                Log.guardFlow.notice("need \(token, privacy: .public): прошу root-часть открыть \(need.category.rawValue, privacy: .public)")
                if let warning = try await GuardHelperClient.unlock(
                    need.category.rawValue, scope: need.scope, minutes: GuardHelper.commandMinutes, command: label, requester: requester
                ) {
                    lastError = warning
                }
                Log.guardFlow.notice("need \(token, privacy: .public): открыто \(need.category.rawValue, privacy: .public)")
                opened.append(need)
            } catch is CancellationError {
                // Отменил окно Touch ID — команда пойдёт как есть.
                Log.guardFlow.notice("need \(token, privacy: .public): окно Touch ID отменено")
                break
            } catch {
                Log.guardFlow.error("need \(token, privacy: .public): ошибка root-части: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                break
            }
        }
        guard !opened.isEmpty else { return "cancelled" }
        for need in opened { commandHolds[Self.holdKey(need), default: 0] += 1 }
        // Старые метки (терминал закрыли посреди команды) root-часть уже закрыла по таймеру.
        commandTokens = commandTokens.filter { Date().timeIntervalSince($0.value.at) < Double(GuardHelper.commandMinutes) * 60 }
        commandTokens[token] = (opened, Date(), peer)
        Log.guardFlow.notice("need \(token, privacy: .public): обновляю ключи перед ответом")
        await refreshKeysNow()
        Log.guardFlow.notice("need \(token, privacy: .public): отвечаю «opened»")
        return "opened\t" + opened.map(GuardPhrase.need).joined(separator: ", ")
    }

    /// Команда закончилась — закрыть то, что открывали для неё, если больше никому не нужно.
    private func commandDone(token: String) {
        guard let entry = commandTokens.removeValue(forKey: token) else {
            Log.guardFlow.notice("done \(token, privacy: .public): ничего не открывали")
            return
        }
        for need in entry.needs {
            let key = Self.holdKey(need)
            let left = (commandHolds[key] ?? 1) - 1
            guard left <= 0 else {
                Log.guardFlow.notice("done \(token, privacy: .public): \(key, privacy: .private) ещё нужен \(left) командам")
                commandHolds[key] = left
                continue
            }
            commandHolds[key] = nil
            Task {
                Log.guardFlow.notice("done \(token, privacy: .public): прошу root-часть закрыть \(need.category.rawValue, privacy: .public)")
                do {
                    _ = try await GuardHelperClient.lock(need.category.rawValue, scope: need.scope)
                    Log.guardFlow.notice("done \(token, privacy: .public): закрыто \(need.category.rawValue, privacy: .public)")
                } catch {
                    Log.guardFlow.error("done \(token, privacy: .public): не закрылось: \(error.localizedDescription, privacy: .public)")
                }
                await refreshKeysNow()
            }
        }
    }

    // MARK: - Кто пользуется SSH-ключом

    /// Посредник перед ssh-agent. Настоящий агент — из окружения Радарчика; нет его —
    /// слежки нет, терминал ходит в агент сам. Метка рядом с сокетом говорит хуку,
    /// за каким агентом посредник и жив ли Радарчик.
    private func startAgentRelay() {
        guard agentRelay == nil, let upstream = AgentSocket.upstream() else { return }
        let relay = SSHAgentRelay(path: AgentSocket.path, upstream: upstream) { [weak self] request in
            self?.decideSign(request) ?? .forward
        } onSign: { [weak self] signing in
            Task { @MainActor in self?.agentSigned(signing) }
        }
        do {
            try relay.start()
            try AgentSocket.writeMarker(upstream: upstream)
            agentRelay = relay
            agentWatching = true
        } catch {
            relay.stop()
            lastError = L("Не вышло включить слежку за SSH-ключом: \(error)", "Couldn’t start watching the SSH key: \(error)")
        }
    }

    /// Выключили «Защиту» или Радарчик закрывается: метку — первой, чтобы новые
    /// команды терминала сразу шли в агент напрямую.
    func stopAgentRelay() {
        AgentSocket.removeMarker()
        agentRelay?.stop()
        agentRelay = nil
        agentWatching = false
    }

    /// Просьба «подпиши» ещё у посредника, клиент ждёт. Зовётся из потока посредника:
    /// решение — на главном акторе, ждём его здесь. Не дождались — отказ: лучше
    /// упавший `git commit`, чем ключ без ответа.
    nonisolated private func decideSign(_ request: SSHAgentRelay.Request) -> SSHAgentRelay.Decision {
        let semaphore = DispatchSemaphore(value: 0)
        let box = DecisionBox()
        Task { @MainActor [weak self] in
            let decision = await self?.gate(request) ?? .forward
            box.value = decision
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.gateTimeout) == .success else {
            Log.guardFlow.error("агент: решение не пришло за \(Int(Self.gateTimeout)) с — отказ")
            return .refuse
        }
        return box.value
    }

    /// По одному: следующее решение ждёт предыдущее, и подтверждение первого
    /// (`AgentGate.grace`) достаётся остальным без второго окна.
    private func gate(_ request: SSHAgentRelay.Request) async -> SSHAgentRelay.Decision {
        let previous = gateChain
        let task = Task { @MainActor [weak self] () -> SSHAgentRelay.Decision in
            await previous?.value
            return await self?.gateNow(request) ?? .forward
        }
        gateChain = Task { _ = await task.value }
        return await task.value
    }

    /// Своё — пропустить; чужое защищённому ключу — Touch ID через root-часть, пока
    /// клиент ждёт. Отменил окно — отказ. Root-часть не ответила — пропустить, а
    /// дальше тревога, как без неё (`agentUse`).
    private func gateNow(_ request: SSHAgentRelay.Request) async -> SSHAgentRelay.Decision {
        guard settings.guardEnabled else { return .forward }
        let plan = await worker.agentPlan(request, now: Date(), approvedShells: approvedShells(), canAsk: canConfirm)
        guard case .ask(let ask) = plan else { return .forward }
        Log.guardFlow.notice("агент: \(ask.phrase, privacy: .public) просит \(ask.requester, privacy: .public) — Touch ID")
        do {
            try await GuardHelperClient.confirm(key: ask.key, action: ask.action, place: ask.place, requester: ask.requester)
            await worker.agentConfirmed(ask, now: Date())
            Log.guardFlow.notice("агент: подтверждено")
            return .forward
        } catch is CancellationError {
            Log.guardFlow.notice("агент: окно Touch ID отменено — отказ")
        } catch GuardHelperError.failed(let message) {
            Log.guardFlow.notice("агент: не подтверждено (\(message, privacy: .public)) — отказ")
        } catch {
            Log.guardFlow.error("агент: ошибка root-части: \(error.localizedDescription, privacy: .public) — пропускаю")
            lastError = error.localizedDescription
            if case GuardHelperError.unavailable = error { helper = .unreachable }
            return .forward
        }
        await worker.agentRefused(ask, now: Date())
        await refreshJournal()
        return .refuse
    }

    /// Оболочки, для чьих команд ты сам открыл ключ по Touch ID: их обращение — не тревога.
    private func approvedShells() -> Set<Int32> {
        let limit = Double(GuardHelper.commandMinutes) * 60
        return Set(commandTokens.values.filter { Date().timeIntervalSince($0.at) < limit }.map(\.shell))
    }

    /// Агент подписал через посредника: в журнал, а чужое — тревогой.
    private func agentSigned(_ signing: SSHAgentRelay.Signing) {
        guard settings.guardEnabled else { return }
        let approved = approvedShells()
        Task {
            let events = await worker.agentUse(signing, now: Date(), approvedShells: approved)
            await refreshJournal()
            for event in events { enqueue(event) }
        }
    }

    private static func names(_ needs: [KeyNeed]) -> String {
        needs.isEmpty ? "—" : needs.map { $0.category.rawValue + ($0.scope == nil ? "" : "(проект)") }.joined(separator: ",")
    }

    private static func holdKey(_ need: KeyNeed) -> String {
        need.category.rawValue + "|" + (need.scope ?? "")
    }

    // MARK: - Ответ на тревогу

    func respond(_ event: GuardEvent, with response: GuardResponse) {
        // Убираем сразу, не дожидаясь фона: кнопка должна срабатывать мгновенно.
        alerts.removeAll { $0.id == event.id }
        pending.removeAll { $0.id == event.id }
        if announcement?.id == event.id { dismissAnnouncement() }
        Task {
            await worker.respond(event.id, with: response, now: Date())
            await refreshJournal()
        }
    }

    /// Чёлку раскрыли — записка больше не нужна.
    func dismissAnnouncement() {
        announcementTask?.cancel()
        announcementTask = nil
        if announcement != nil { announcement = nil }
    }

    /// Чёлка свернулась: то, что объявляли, уже показали алертом — очередь идёт дальше.
    func panelDidCollapse() {
        dismissAnnouncement()
        announceIfPossible()
    }

    /// Для листа экранов (`--render-screens`): готовое состояние без проверок.
    func preview(
        keys: GuardKeysState, alerts: [GuardEvent], recent: [GuardEvent], scans: [GuardEvent], audit: [AuditFinding], hooksConnected: Bool,
        helper: HelperStatus, now: Date, announcement: GuardEvent? = nil, network: NetworkSummary = NetworkSummary(), networkWatching: Bool = false
    ) {
        self.helper = helper
        self.announcement = announcement
        agentWatching = true
        self.network = network
        self.networkWatching = networkWatching
        self.keys = keys
        self.alerts = alerts
        self.recent = recent
        self.scans = scans
        self.audit = audit
        self.hooksConnected = hooksConnected
        self.now = now
        aliveProcesses = Set(alerts.filter { $0.kind == .process || $0.kind == .agent || $0.kind == .network }.map(\.id))
    }

    // MARK: - Проверки

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.pass(tick: tick)
                tick += 1
                // Допуск: macOS может склеить пробуждение с чужими таймерами — меньше просыпаний.
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
            }
        }
    }

    /// Один проход: процессы — всегда, ключи — каждые 6 секунд (а пока идёт
    /// таймер, каждые 2), настройки Claude и хуки — раз в 5 минут.
    private func pass(tick: Int) async {
        let now = Date()
        var events: [GuardEvent] = []
        if settings.guardWatchProcesses {
            events += await worker.watchProcesses(now: now)
        }
        if settings.guardWatchNetwork, helper == .ready, tick >= networkRetryTick {
            events += await pollNetwork(now: now, tick: tick)
        }
        if tick % 3 == 0 || wing != nil {
            let (state, keyEvents) = await worker.keys(now: now)
            if keys != state { keys = state }
            events += keyEvents
            updateClock()
        }
        if tick % 150 == 0 {
            if settings.guardAuditClaude {
                let (findings, auditEvents) = await worker.audit(now: now)
                if audit != findings { audit = findings }
                events += auditEvents
            }
            let connected = await worker.hooksConnected()
            if hooksConnected != connected { hooksConnected = connected }
        }
        // Журнал — когда что-то случилось, и раз в полминуты (вдруг процесс тревоги завершился).
        if !events.isEmpty || tick % 15 == 0 {
            await refreshJournal()
        }
        guard settings.guardEnabled, !Task.isCancelled else { return }
        for event in events { enqueue(event) }
    }

    private func refreshJournal() async {
        let now = Date()
        let active = await worker.active()
        let recent = await worker.recent(now: now)
        let scans = await worker.lastScans(limit: 3)
        var alive = Set<Int64>()
        // «Убить» есть у процессов и у программ, взявших SSH-ключ.
        for event in active where event.kind == .process || event.kind == .agent || event.kind == .network {
            if await worker.isProcessAlive(event.id) { alive.insert(event.id) }
        }
        let network = await worker.networkSummary(now: now)
        if alerts != active { alerts = active }
        if self.recent != recent { self.recent = recent }
        if self.scans != scans { self.scans = scans }
        if self.network != network { self.network = network }
        if aliveProcesses != alive { aliveProcesses = alive }
        // Ответили на тревогу где-то ещё (или её не стало) — записку убираем.
        if let announcement, announcement.level == .critical, !active.contains(where: { $0.id == announcement.id }) { dismissAnnouncement() }
    }

    /// Спросить root-часть о новых соединениях (`networkFlows`). Первый раз — только номер,
    /// без старого: то, что было до запуска, уже не новость. Ошибка — пауза на полминуты.
    private func pollNetwork(now: Date, tick: Int) async -> [GuardEvent] {
        do {
            let result = try await GuardHelperClient.networkFlows(since: networkSequence ?? UInt64.max)
            networkSequence = result.next
            if let error = result.error {
                if networkError != error { networkError = error }
                if networkWatching { networkWatching = false }
                networkRetryTick = tick + 15
                return []
            }
            if networkError != nil { networkError = nil }
            if !networkWatching { networkWatching = true }
            guard !result.flows.isEmpty else { return [] }
            return await worker.networkFlows(result.flows, now: now)
        } catch {
            Log.guardFlow.error("сеть: root-часть не ответила: \(error.localizedDescription, privacy: .public)")
            if case GuardHelperError.unavailable = error { helper = .unreachable }
            if networkWatching { networkWatching = false }
            networkRetryTick = tick + 15
            return []
        }
    }

    /// Пока в крыле идёт обратный отсчёт, `now` тикает раз в секунду. Отсчёт
    /// кончился — часы останавливаются: в покое чёлка ничего не перерисовывает.
    private func updateClock() {
        now = Date()
        guard clockTask == nil, wing?.remaining != nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                guard let self else { return }
                self.now = Date()
                if self.wing?.remaining == nil {
                    self.clockTask = nil
                    return
                }
            }
        }
    }

    // MARK: - Записка

    private func enqueue(_ event: GuardEvent) {
        guard !pending.contains(where: { $0.id == event.id }) else { return }
        pending.append(event)
        announceIfPossible()
    }

    /// Сказать запиской, если сейчас можно: чёлка свёрнута, а для «стоит глянуть» —
    /// ещё и не звонок, и ты за компьютером. Опасное — сразу, даже на звонке.
    private func announceIfPossible() {
        let now = Date()
        pending.removeAll { $0.level < .critical && now.timeIntervalSince($0.at) > Self.pendingLifetime }
        guard announcement == nil, !isPanelExpanded(),
              let index = pending.firstIndex(where: { $0.level == .critical || canSpeak })
        else { return }
        let event = pending.remove(at: index)
        announcement = event
        announcementTask?.cancel()
        announcementTask = nil
        // Опасное висит, пока не наведёшь курсор: чёлка раскроется, и записку уберёт
        // `dismissAnnouncement`, а в облачке будут кнопки. Остальное — 8 секунд
        // (просьба пользователя 2026-10-20: тревогу не пропустить, отойдя от мака).
        guard event.level < .critical else { return }
        announcementTask = Task { [weak self] in
            try? await Task.sleep(for: Self.announcementDuration)
            guard !Task.isCancelled, let self else { return }
            self.announcement = nil
            self.announceIfPossible()
        }
    }


    /// Звонок — молчим о мелочах; никого нет минуту — ждём, пока вернёшься.
    private var canSpeak: Bool {
        !tracker.isInCall && ActivityTracker.idleSeconds() < 60
    }

    // MARK: - Сокет для git-хука

    private func startSocket() {
        guard socket == nil else { return }
        let server = ShellSocketServer(path: GuardSocket.path) { [weak self] message in
            Task { @MainActor in self?.codeScanArrived(message) }
        }
        do {
            try server.start()
            socket = server
        } catch {
            lastError = L("Не вышло открыть сокет «Защиты»: \(error)", "Couldn’t open the Guard socket: \(error)")
        }
    }

    /// Хук проверил код и записал итог в журнал: «code <id>».
    private func codeScanArrived(_ message: String) {
        let parts = message.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, parts[0] == "code", let id = Int64(parts[1]) else { return }
        Task {
            guard let event = await worker.event(id) else { return }
            await refreshJournal()
            if event.level >= .warning { enqueue(event) }
        }
    }
}

extension GuardWorker {
    /// Глобальный `core.hooksPath` — через git, поэтому в фоне.
    func hooksConnected() -> Bool { GitHooks.isConnected() }
}

/// Ответ главного актора потоку посредника.
private final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SSHAgentRelay.Decision = .forward

    var value: SSHAgentRelay.Decision {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
