import Foundation
import Observation
import RadarchikCore

/// Ресурсы мака для интерфейса (этап 6, SPEC §3а). Раз в 5 секунд просит
/// `ResourceWorker` замерить мак, раз в 15 — ещё и приложения, и держит
/// готовое для чёлки: строку при наведении, экран «Система», тревоги.
///
/// Как Радарчик говорит о тревоге:
/// 1. Под вырезом на 8 секунд выезжает записка (`announcement`) — один раз на тревогу.
/// 2. Пока не ответишь или пока не пройдёт само, лицо беспокоится, а сводка
///    вместо фразы о деньгах показывает тревогу с кнопками.
/// 3. На звонке и пока тебя нет за компьютером молчит и ждёт.
/// 4. По желанию — ещё и уведомление macOS.
@MainActor
@Observable
final class ResourceMonitor {
    private(set) var system: SystemSnapshot?
    private(set) var apps: [AppUsageRow] = []
    private(set) var history: [SystemMinute] = []
    /// Активные тревоги, старые первыми: показываем по одной.
    private(set) var alerts: [ResourceAlert] = []
    /// У скольких приложений норма уже накопилась (для подсказки на экране «Система»).
    private(set) var normsCount = 0
    /// Записка под чёлкой прямо сейчас.
    private(set) var announcement: ResourceAlert?
    /// Уведомления запрещены в Системных настройках.
    private(set) var notificationsDenied = false
    var lastError: String?

    var activeAlert: ResourceAlert? { alerts.first }

    /// Чёлка раскрыта: записка не нужна, тревога и так в облачке. Задаёт `NotchController`.
    @ObservationIgnored var isPanelExpanded: () -> Bool = { false }

    private let worker: ResourceWorker
    private let settings: AppSettings
    private let tracker: ActivityTracker
    @ObservationIgnored private let notifier = ResourceNotifier()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    /// О каких тревогах уже сказали (запиской или в облачке).
    @ObservationIgnored private var announced: Set<Int64> = []
    /// «Пример тревоги» с экрана «Система» — живёт только в памяти.
    @ObservationIgnored private var example: ResourceAlert?
    /// На что уже ответили: замер, начатый до ответа, не должен вернуть тревогу на миг.
    @ObservationIgnored private var answered: Set<Int64> = []
    /// Последняя ошибка движка, которую уже показали: закрытый баннер не должен
    /// возвращаться через 5 секунд из-за той же ошибки.
    @ObservationIgnored private var shownEngineError: String?

    /// Сколько висит записка.
    private static let announcementDuration: Duration = .seconds(8)
    /// О старых тревогах (например, после перезапуска) запиской не говорим — только лицом.
    private static let announceWithin: TimeInterval = 15 * 60
    private static let exampleId: Int64 = -1_000

    init(worker: ResourceWorker, settings: AppSettings, tracker: ActivityTracker) {
        self.worker = worker
        self.settings = settings
        self.tracker = tracker
    }

    func start() {
        notifier.activate()
        // Клик по уведомлению — записка ещё раз, чтобы было видно, где искать.
        notifier.onOpen = { [weak self] in self?.repeatAnnouncement() }
        if settings.resourceNotifications {
            Task { notificationsDenied = await notifier.isDenied() }
        }
        guard settings.resourcesEnabled else { return }
        startLoop()
    }

    /// Тумблер «Следить за ресурсами» в настройках.
    func setEnabled(_ enabled: Bool) {
        settings.resourcesEnabled = enabled
        if enabled {
            startLoop()
        } else {
            loopTask?.cancel()
            loopTask = nil
            dismissAnnouncement()
            system = nil
            apps = []
            history = []
            alerts = []
            example = nil
        }
    }

    /// Тумблер «Дублировать уведомлением»: при включении macOS спросит разрешение.
    func setNotifications(_ enabled: Bool) {
        settings.resourceNotifications = enabled
        guard enabled else { return }
        Task {
            if await notifier.requestAuthorization() {
                notificationsDenied = false
            } else {
                notificationsDenied = await notifier.isDenied()
            }
        }
    }

    // MARK: - Ответ на тревогу

    func respond(_ alert: ResourceAlert, with status: AlertStatus) {
        if announcement?.id == alert.id { dismissAnnouncement() }
        // Убираем сразу, не дожидаясь фона: кнопка должна срабатывать мгновенно.
        answered.insert(alert.id)
        alerts.removeAll { $0.id == alert.id }
        if alert.id == example?.id {
            example = nil
            return
        }
        Task { apply(await worker.respond(to: alert.id, with: status)) }
    }

    /// Облачко с тревогой показали на сводке — запиской о ней больше не говорим.
    func markSeen(_ alert: ResourceAlert) {
        announced.insert(alert.id)
    }

    /// Чёлку раскрыли — записка больше не нужна.
    func dismissAnnouncement() {
        announcementTask?.cancel()
        announcementTask = nil
        if announcement != nil { announcement = nil }
    }

    /// Чёлка свернулась — может, пора сказать о том, что ждало.
    func panelDidCollapse() {
        announceIfPossible()
    }

    /// Тревога для проверки глазами: как Радарчик скажет, не дожидаясь настоящей.
    /// Берём приложение, которое сейчас держит больше всех памяти.
    func showExample() {
        let top = apps.max { $0.usage.memoryBytes < $1.usage.memoryBytes }
        let app = top?.usage.app ?? AppIdentity(key: "com.google.Chrome", name: "Google Chrome")
        let bytes = Double(top?.usage.memoryBytes ?? 4_400_000_000)
        let now = Date()
        let alert = ResourceAlert(
            id: Self.exampleId, kind: .memory, app: app, value: bytes, usual: bytes / 3,
            startedAt: now.addingTimeInterval(-7 * 60), createdAt: now,
            title: ResourcePhrase.memory(app: app.name, bytes: bytes, usual: bytes / 3, totalBytes: nil),
            detail: L("Это пример, на самом деле всё в порядке", "This is just an example, everything is actually fine"), status: .active, statusChangedAt: nil
        )
        example = alert
        alerts.removeAll { $0.id == Self.exampleId }
        alerts.insert(alert, at: 0)
        announced.remove(Self.exampleId)
        announceIfPossible(force: true)
    }

    /// Для листа экранов (`--render-screens`): показать готовое состояние без замеров.
    func preview(_ state: ResourceState) {
        apply(state)
    }

    /// Тревоги за сутки — для экрана «Система».
    func recentAlerts() async -> [ResourceAlert] {
        await worker.recentAlerts()
    }

    // MARK: - Замеры

    private func startLoop() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // Процессы — каждый третий замер, то есть раз в 15 секунд.
                guard let state = await self?.worker.sample(includeProcesses: tick % 3 == 0) else { return }
                guard !Task.isCancelled else { return }
                self?.apply(state)
                tick += 1
                // Допуск: macOS может склеить пробуждение с чужими таймерами — меньше просыпаний.
                try? await Task.sleep(for: .seconds(5), tolerance: .seconds(1))
            }
        }
    }

    private func apply(_ state: ResourceState) {
        // Слежение выключили, пока шёл замер или ответ, — ничего не показываем.
        guard settings.resourcesEnabled else { return }
        if system != state.system { system = state.system }
        if apps != state.apps { apps = state.apps }
        if history != state.history { history = state.history }
        if normsCount != state.normsCount { normsCount = state.normsCount }
        // Пример держим поверх настоящих, пока на него не ответили.
        let merged = (example.map { [$0] } ?? []) + state.alerts.filter { !answered.contains($0.id) }
        if alerts != merged { alerts = merged }
        // Каждую новую ошибку базы — баннером один раз.
        if let error = state.lastError, error != shownEngineError {
            shownEngineError = error
            lastError = error
        }
        // Тревога прошла сама, пока висела записка, — записку убираем.
        if let announcement, !alerts.contains(where: { $0.id == announcement.id }) { dismissAnnouncement() }
        announceIfPossible()
    }

    /// Сказать о тревоге запиской, если сейчас можно: чёлка свёрнута,
    /// не звонок и ты за компьютером. О каждой тревоге — один раз.
    private func announceIfPossible(force: Bool = false) {
        guard announcement == nil, !isPanelExpanded() else { return }
        let now = Date()
        guard let alert = alerts.first(where: {
            !announced.contains($0.id) && now.timeIntervalSince($0.createdAt) < Self.announceWithin
        }) else { return }
        // Пример показываем сразу: его попросили нажатием.
        guard force || canSpeak else { return }
        announced.insert(alert.id)
        show(alert)
        if settings.resourceNotifications && alert.id != Self.exampleId { notifier.post(alert) }
    }

    private func repeatAnnouncement() {
        guard let alert = activeAlert, !isPanelExpanded() else { return }
        dismissAnnouncement()
        show(alert)
    }

    private func show(_ alert: ResourceAlert) {
        announcement = alert
        announcementTask?.cancel()
        announcementTask = Task { [weak self] in
            try? await Task.sleep(for: Self.announcementDuration)
            guard !Task.isCancelled else { return }
            self?.announcement = nil
        }
    }

    /// Звонок — молчим (вдруг показываешь экран); никого нет минуту — ждём, пока вернёшься.
    private var canSpeak: Bool {
        !tracker.isInCall && ActivityTracker.idleSeconds() < 60
    }
}
