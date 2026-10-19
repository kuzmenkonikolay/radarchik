import AppKit
import IOKit.pwr_mgt
import Observation
import RadarchikCore

/// Наблюдение за днём (этап 3): что на экране, команды терминала, копирование,
/// звонки, запуск приложений. Пишет в лог (`ActivityRepository`), хранит 30 дней.
///
/// Раз в 2 секунды делается снимок: активное приложение, заголовок окна,
/// вкладка браузера. Заодно проверяются простой, буфер обмена и микрофон.
/// Переключения приложений, сон и блокировка приходят уведомлениями.
/// Пока наблюдение выключено, трекер следит только за микрофоном:
/// во время звонка чёлка прячет цифры.
@MainActor
@Observable
final class ActivityTracker {
    /// Идёт звонок: чёлка прячет цифры, Радарчик не засыпает.
    private(set) var isInCall = false
    private(set) var accessibilityGranted = Permissions.accessibilityGranted
    /// Доступ к Apple Events по bundle id браузера — для экрана «Наблюдение».
    private(set) var automation: [String: Permissions.AutomationStatus] = [:]
    private(set) var lastCommandAt: Date?
    var lastError: String?

    private let repository: ActivityRepository
    private let settings: AppSettings
    private let recorder: ActivityRecorder
    private let probe = FocusProbe()
    private let callDetector = CallDetector()

    @ObservationIgnored private var shellServer: ShellSocketServer?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Мак спит, экран погас или сессия неактивна.
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var isProbing = false
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    /// Последнее копирование: ждём, в какое приложение перейдёшь.
    @ObservationIgnored private var pendingPaste: (id: Int64, from: String?, at: Date)?
    /// Текущий звонок; id nil — наблюдение выключено, звонок не пишется.
    /// `seenAt` — когда в базе последний раз отметили, что он ещё идёт.
    @ObservationIgnored private var currentCall: (id: Int64?, startedAt: Date, usesCamera: Bool, seenAt: Date)?
    @ObservationIgnored private var lastCleanup: Date?
    @ObservationIgnored private var automationCheckedAt: Date?

    init(repository: ActivityRepository, settings: AppSettings) {
        self.repository = repository
        self.settings = settings
        self.recorder = ActivityRecorder(repository: repository)
    }

    private var isPaused: Bool { isAsleep || isLocked }

    func start() {
        do {
            try ShellHook.install()
        } catch {
            lastError = L("Не записался zsh-хук: ", "Couldn’t write the zsh hook: ") + error.localizedDescription
        }
        // Звонки, которые не закрыл прошлый запуск (его убили посреди звонка).
        record { try repository.deleteDanglingCalls() }
        observeSystem()
        if settings.observationEnabled { enableComponents() }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // Допуск: macOS может склеить пробуждение с чужими таймерами — меньше просыпаний.
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(500))
            }
        }
    }

    /// Включение и выключение с экрана «Наблюдение».
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.observationEnabled else { return }
        settings.observationEnabled = enabled
        if enabled {
            enableComponents()
        } else {
            disableComponents()
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
    }

    /// Обновить статусы доступа к браузерам. `ask` — для какого браузера
    /// показать системный запрос (после кнопки «Спросить»).
    func refreshAutomation(ask bundleIdToAsk: String? = nil) {
        automationCheckedAt = Date()
        let installed = Browsers.bundleIds.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        Task.detached(priority: .utility) { [weak self] in
            var statuses: [String: Permissions.AutomationStatus] = [:]
            for id in installed {
                statuses[id] = Permissions.automationStatus(bundleId: id, ask: id == bundleIdToAsk)
            }
            await self?.apply(automation: statuses)
        }
    }

    /// Своё копирование (кнопка «Скопировать строку») не считаем.
    func ignoreOwnPasteboardChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Сводка с полуночи для экрана «Что записано сегодня». Без текущей
    /// несохранённой сессии — это максимум полминуты.
    func todaySummary(now: Date = Date()) -> DaySummary {
        let range = Calendar.current.startOfDay(for: now)...now
        return DaySummaryBuilder.build(
            sessions: (try? repository.sessions(in: range)) ?? [],
            commands: (try? repository.commands(in: range)) ?? [],
            pastes: (try? repository.pastes(in: range)) ?? [],
            calls: (try? repository.calls(in: range)) ?? [],
            now: now
        )
    }

    // MARK: - Цикл

    private func tick() async {
        let now = Date()
        // Звонок замечаем всегда: он прячет цифры, даже когда наблюдение выключено.
        sampleCall(at: now)
        guard settings.observationEnabled, !isPaused else { return }

        let granted = Permissions.accessibilityGranted
        if granted != accessibilityGranted { accessibilityGranted = granted }
        samplePasteboard(at: now)
        cleanupIfNeeded(at: now)
        if automationCheckedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            refreshAutomation()
        }

        // Простой: 2 минуты без клавиатуры и мыши. Если что-то не даёт экрану
        // гаснуть (видео, презентация) — 30 минут. На звонке простоя нет.
        let idle = Self.idleSeconds()
        let threshold: TimeInterval = Self.displaySleepPrevented() ? 30 * 60 : 2 * 60
        if !isInCall && idle >= threshold {
            record { try recorder.pause(at: now.addingTimeInterval(-idle)) }
            return
        }
        await observeFrontmost()
    }

    /// Снимок активного приложения: заголовок окна и адрес вкладки.
    private func observeFrontmost() async {
        guard settings.observationEnabled, !isPaused, !isProbing,
              let app = NSWorkspace.shared.frontmostApplication, let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier
        else { return }

        if settings.excludedApps.contains(bundleId) {
            record { try recorder.observe(nil, at: Date()) }
            return
        }

        let browser = Browsers.kind(of: bundleId)
        // В браузер стучимся, только если доступ уже дали: без спроса окно
        // с запросом не выскочит посреди работы. Спросить можно на экране «Наблюдение».
        let canReadURL = browser != nil && automation[bundleId] == .granted
        isProbing = true
        let result = await probe.probe(
            pid: app.processIdentifier, bundleId: bundleId, browser: browser,
            readTitle: accessibilityGranted, readURL: canReadURL
        )
        isProbing = false
        // Пока ждали ответа, могли переключиться — тогда снимок устарел.
        guard settings.observationEnabled, !isPaused,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
        else { return }

        var url = result.url.flatMap(URLNormalizer.normalize)
        var title = TitleNormalizer.normalize(result.title)
        var isPrivate = result.isIncognito
        if let normalized = url, let host = URLNormalizer.host(of: normalized),
           ObservationRules.isExcluded(host: host, domains: settings.excludedDomains) {
            isPrivate = true
        }
        if isPrivate {
            url = nil
            title = nil
        }
        let snapshot = FocusSnapshot(
            bundleId: bundleId, appName: app.localizedName ?? bundleId,
            windowTitle: title, url: url, isPrivate: isPrivate
        )
        record { try recorder.observe(snapshot, at: Date()) }
    }

    // MARK: - Звонки

    private func sampleCall(at now: Date) {
        let sample = callDetector.sample()
        if sample.microphoneInUse {
            if currentCall == nil {
                isInCall = true
                var id: Int64?
                if settings.observationEnabled {
                    let holder = callDetector.microphoneHolders().first { $0 != Bundle.main.bundleIdentifier }
                    let holderName = holder.flatMap { holder in
                        NSRunningApplication.runningApplications(withBundleIdentifier: Browsers.owningBrowser(of: holder) ?? holder).first?.localizedName
                    }
                    let host = recorder.current?.url.flatMap(URLNormalizer.host(of:))
                    let service = CallService.name(holderBundleId: holder, holderName: holderName, browserHost: host)
                    // Конец сразу «сейчас»: упадёт Радарчик — звонок не останется бесконечным.
                    id = try? repository.insert(CallSession(bundleId: holder, service: service, usesCamera: sample.cameraInUse, startedAt: now, endedAt: now))
                }
                currentCall = (id, now, sample.cameraInUse, now)
            } else if let call = currentCall {
                if sample.cameraInUse && !call.usesCamera { currentCall?.usesCamera = true }
                // Раз в минуту отмечаем, что звонок ещё идёт: если Радарчик убьют
                // посреди звонка, его конец в базе ошибётся не больше чем на минуту.
                if let id = call.id, now.timeIntervalSince(call.seenAt) >= 60 {
                    let usesCamera = currentCall?.usesCamera ?? call.usesCamera
                    record { try repository.endCall(id: id, at: now, usesCamera: usesCamera) }
                    currentCall?.seenAt = now
                }
            }
        } else if let call = currentCall {
            if let id = call.id {
                // Меньше 30 секунд — Siri или диктовка, не звонок.
                if now.timeIntervalSince(call.startedAt) < 30 {
                    record { try repository.deleteCall(id: id) }
                } else {
                    record { try repository.endCall(id: id, at: now, usesCamera: call.usesCamera) }
                }
            }
            currentCall = nil
            isInCall = false
        }
    }

    // MARK: - Буфер обмена (только факт, без содержимого)

    private func samplePasteboard(at now: Date) {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let from = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Скопировал из менеджера паролей — даже факт не пишем.
        if let from, settings.excludedApps.contains(from) {
            pendingPaste = nil
            return
        }
        do {
            let id = try repository.insert(PasteEvent(fromBundleId: from, toBundleId: nil, at: now))
            pendingPaste = (id, from, now)
        } catch {
            lastError = L("Лог не записался: ", "Couldn’t write the log: ") + "\(error)"
        }
    }

    private func appActivated(_ bundleId: String?) {
        guard settings.observationEnabled, !isPaused, let bundleId else { return }
        if let pending = pendingPaste {
            let now = Date()
            if !settings.excludedApps.contains(bundleId),
               let target = PasteHeuristic.target(copiedIn: pending.from, copiedAt: pending.at, activated: bundleId, at: now) {
                record { try repository.updatePasteTarget(id: pending.id, toBundleId: target) }
                pendingPaste = nil
            } else if now.timeIntervalSince(pending.at) > PasteHeuristic.window {
                pendingPaste = nil
            }
        }
        Task { await observeFrontmost() }
    }

    // MARK: - Терминал

    private func startShellServer() {
        guard shellServer == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tracker = self
        let server = ShellSocketServer(path: ShellHook.socketPath) { raw in
            // Разбор и вычистка — прямо в очереди сокета: сырая команда никуда не уходит.
            guard let message = ShellMessage.parse(raw) else { return }
            let command = message.makeCommand(home: home)
            Task { @MainActor in tracker.store(command) }
        }
        do {
            try server.start()
            shellServer = server
        } catch {
            lastError = L("Сокет для терминала не открылся: ", "Couldn’t open the terminal socket: ") + "\(error)"
        }
    }

    private func store(_ command: ShellCommand) {
        guard settings.observationEnabled else { return }
        record { try repository.insert(command) }
        lastCommandAt = command.startedAt
    }

    // MARK: - Приложения

    private func recordRunningApps() {
        let now = Date()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !settings.excludedApps.contains(id) else { continue }
            record { try repository.insert(AppLifecycleEvent(bundleId: id, appName: app.localizedName ?? id, kind: .running, at: now)) }
        }
    }

    private func appLifecycle(bundleId: String?, name: String?, kind: AppLifecycleEvent.Kind) {
        guard settings.observationEnabled, let bundleId, !settings.excludedApps.contains(bundleId) else { return }
        record { try repository.insert(AppLifecycleEvent(bundleId: bundleId, appName: name ?? bundleId, kind: kind, at: Date())) }
    }

    // MARK: - Включение и система

    private func enableComponents() {
        recordRunningApps()
        startShellServer()
        lastCommandAt = try? repository.lastCommandDate()
        refreshAutomation()
    }

    private func disableComponents() {
        record { try recorder.pause(at: Date()) }
        shellServer?.stop()
        shellServer = nil
        pendingPaste = nil
    }

    private func setAsleep(_ asleep: Bool) {
        isAsleep = asleep
        pauseOrResume()
    }

    private func setLocked(_ locked: Bool) {
        isLocked = locked
        pauseOrResume()
    }

    private func pauseOrResume() {
        if isPaused {
            record { try recorder.pause(at: Date()) }
        } else {
            Task { await observeFrontmost() }
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundleId) }
        })
        for (name, kind) in [
            (NSWorkspace.didLaunchApplicationNotification, AppLifecycleEvent.Kind.launched),
            (NSWorkspace.didTerminateApplicationNotification, AppLifecycleEvent.Kind.terminated),
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let isRegular = app?.activationPolicy == .regular
                let bundleId = app?.bundleIdentifier
                let name = app?.localizedName
                MainActor.assumeIsolated {
                    if isRegular { self?.appLifecycle(bundleId: bundleId, name: name, kind: kind) }
                }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(true) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(false) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(true) }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setLocked(false) }
        })
    }

    // MARK: - Мелочи

    private func apply(automation statuses: [String: Permissions.AutomationStatus]) {
        if statuses != automation { automation = statuses }
    }

    private func cleanupIfNeeded(at now: Date) {
        if let lastCleanup, now.timeIntervalSince(lastCleanup) < 6 * 3_600 { return }
        lastCleanup = now
        let cutoff = now.addingTimeInterval(-Double(ActivityRepository.retentionDays) * 86_400)
        record { try repository.deleteOlderThan(cutoff) }
    }

    private func record(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            lastError = L("Лог не записался: ", "Couldn’t write the log: ") + "\(error)"
        }
    }

    /// Сколько секунд не трогали клавиатуру и мышь (разрешения не нужны).
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Кто-то держит экран включённым (видео, презентация): человек смотрит, а не ушёл.
    static func displaySleepPrevented() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let values = status?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (values["PreventUserIdleDisplaySleep"] as? Int ?? 0) > 0
    }
}
