import Foundation
import Observation
import RadarchikCore

/// Разбор дня (этап 4). Раз в день собирает сводку из лога, ищет рутину
/// эвристиками, отправляет **только сводку** в Claude (напрямую или через
/// прокси из настроек) и сохраняет 3–5 советов. После этого Радарчик машет
/// блокнотом, а огонёк белеет.
///
/// Когда: в `settings.reviewHour` (22:00) или при первой активности после,
/// если мак спал (`ReviewSchedule`). Не во время звонка. Тихий день (меньше
/// 20 минут за компьютером) пропускается без запроса. При ошибке сети
/// следующая попытка — через 30 минут.
@MainActor
@Observable
final class ReviewService {
    static let keyAccount = "anthropic-api-key"

    private(set) var tips: [Tip] = []
    private(set) var latestReview: StoredReview?
    private(set) var isRunning = false
    /// Где сейчас разбор — шаги экрана F; nil — не идёт.
    private(set) var progress: ReviewProgress?
    private(set) var hasAPIKey = false
    private(set) var connectionStatus: String?
    private(set) var isCheckingConnection = false
    var lastError: String?
    /// «Что это?» — тем же ключом и маршрутом, что разбор.
    let explain: ExplainService

    private let reviews: ReviewRepository
    private let activity: ActivityRepository
    private let settings: AppSettings
    private let tracker: ActivityTracker
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var retryAfter: Date?

    init(reviews: ReviewRepository, activity: ActivityRepository, settings: AppSettings, tracker: ActivityTracker) {
        self.reviews = reviews
        self.activity = activity
        self.settings = settings
        self.tracker = tracker
        explain = ExplainService(settings: settings)
    }

    func start() {
        reload()
        hasAPIKey = KeychainStore.read(Self.keyAccount) != nil
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runIfDue()
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
            }
        }
    }

    var reviewHour: Int { settings.reviewHour }

    // MARK: - Советы для экранов

    /// Новые советы, которые ещё не открывал: по ним белеет огонёк и Радарчик машет.
    var newTipsCount: Int {
        let seen = settings.tipsSeenAt ?? .distantPast
        return tips.filter { $0.status == .new && $0.createdAt > seen }.count
    }

    /// Советы последнего разбора.
    var latestTips: [Tip] {
        guard let id = latestReview?.id else { return [] }
        return tips.filter { $0.reviewId == id }
    }

    /// Советы прошлых разборов, кроме отклонённых.
    var olderTips: [Tip] {
        tips.filter { $0.reviewId != latestReview?.id && $0.status != .dismissed }
    }

    func markSeen() {
        settings.tipsSeenAt = Date()
    }

    func setStatus(_ status: TipStatus, for tip: Tip) {
        do {
            try reviews.setStatus(status, tipId: tip.id, at: Date())
            reload()
        } catch {
            lastError = L("Не сохранилось: ", "Couldn’t save: ") + "\(error)"
        }
    }

    // MARK: - Ключ и связь

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore.save(trimmed, account: Self.keyAccount)
            hasAPIKey = true
            lastError = nil
        } catch {
            lastError = L("Ключ не сохранился: ", "Couldn’t save the key: ") + "\(error)"
        }
    }

    func deleteAPIKey() {
        KeychainStore.delete(Self.keyAccount)
        hasAPIKey = false
    }

    func checkConnection() async {
        guard let route = ClaudeRoute.parse(settings.proxyAddress) else {
            connectionStatus = Self.badProxyAddress
            return
        }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        connectionStatus = await ClaudeClient(route: route).checkConnection(apiKey: KeychainStore.read(Self.keyAccount))
    }

    /// Ошибка в адресе — не идём напрямую молча: человек хотел прокси.
    private static var badProxyAddress: String {
        L("Адрес прокси должен быть вида http://127.0.0.1:8888 — или оставь поле пустым, чтобы ходить напрямую.",
          "The proxy address should look like http://127.0.0.1:8888 — or leave the field empty to connect directly.")
    }

    // MARK: - Разбор

    func runNow() async {
        await run(now: Date(), manual: true)
    }

    /// Что уйдёт в Claude, если разобрать прямо сейчас (экран «Что уходит в Claude»).
    func previewPrompt(now: Date = Date()) -> String {
        ReviewPrompt.userMessage(makeInput(period: currentPeriod(now: now), now: now))
    }

    private var lastAttempt: Date? {
        [settings.lastReviewAttemptAt, latestReview?.createdAt].compactMap { $0 }.max()
    }

    private func currentPeriod(now: Date) -> ClosedRange<Date> {
        ReviewSchedule.period(lastReview: lastAttempt, now: now, calendar: .current)
    }

    private func runIfDue(now: Date = Date()) async {
        guard settings.observationEnabled, hasAPIKey, !isRunning, !tracker.isInCall else { return }
        if let retryAfter, now < retryAfter { return }
        guard ReviewSchedule.isDue(lastReview: lastAttempt, now: now, hour: settings.reviewHour, calendar: .current) else { return }
        await run(now: now, manual: false)
    }

    private func run(now: Date, manual: Bool) async {
        guard !isRunning else { return }
        guard let apiKey = KeychainStore.read(Self.keyAccount) else {
            hasAPIKey = false
            lastError = L("Нет ключа Claude — добавь его в «Разбор дня и Claude».", "No Claude key — add one in “Daily review & Claude”.")
            return
        }
        guard let route = ClaudeRoute.parse(settings.proxyAddress) else {
            lastError = Self.badProxyAddress
            return
        }
        isRunning = true
        progress = ReviewProgress(step: 1, summary: nil)
        defer {
            isRunning = false
            progress = nil
        }
        let period = currentPeriod(now: now)
        let input = makeInput(period: period, now: now)
        // Тихий день: запрос не тратим, ждём следующего вечера.
        if !manual && input.summary.activeSeconds < 20 * 60 {
            settings.lastReviewAttemptAt = now
            return
        }
        let apps = Words.plural(input.summary.apps.count, ru: ("приложение", "приложения", "приложений"), en: ("app", "apps"))
        progress = ReviewProgress(step: 2, summary: "\(DurationFormat.short(input.summary.activeSeconds)), \(input.summary.apps.count) \(apps)")

        let model = settings.claudeModel
        let prompt = ReviewPrompt.userMessage(input)
        do {
            let request = try ClaudeAPI.reviewRequest(apiKey: apiKey, model: model, system: ReviewPrompt.system, user: prompt)
            progress?.step = 3
            let (data, status) = try await ClaudeClient(route: route).send(request)
            progress?.step = 4
            let result = try ClaudeAPI.parseReview(data: data, statusCode: status, model: model)
            _ = try reviews.save(periodStart: period.lowerBound, periodEnd: period.upperBound, createdAt: now, prompt: prompt, result: result)
            settings.lastReviewAttemptAt = now
            lastError = nil
            retryAfter = nil
            reload()
        } catch let error as ClaudeAPIError {
            fail(error.description, now: now)
        } catch {
            fail(route.describe(error), now: now)
        }
    }

    private func fail(_ message: String, now: Date) {
        lastError = message
        retryAfter = now.addingTimeInterval(30 * 60)
    }

    /// Для листа экранов (`--render-screens`): советы из базы и «ключ есть» —
    /// без обращения к Связке ключей и без запросов.
    func loadForPreview() {
        reload()
        hasAPIKey = true
    }

    /// Для листа экранов: экран F с нужным шагом.
    func previewProgress(_ value: ReviewProgress?) {
        progress = value
        isRunning = value != nil
    }

    private func reload() {
        tips = (try? reviews.tips()) ?? []
        latestReview = try? reviews.latestReview()
    }

    // MARK: - Сводка для Claude

    private func makeInput(period: ClosedRange<Date>, now: Date) -> ReviewInput {
        let sessions = (try? activity.sessions(in: period)) ?? []
        let summary = DaySummaryBuilder.build(
            sessions: sessions,
            commands: (try? activity.commands(in: period)) ?? [],
            pastes: (try? activity.pastes(in: period)) ?? [],
            calls: (try? activity.calls(in: period)) ?? [],
            now: now
        )
        return ReviewInput(
            periodStart: period.lowerBound,
            periodEnd: period.upperBound,
            summary: summary,
            candidates: RoutineDetector.candidates(today: summary, history: digests(before: period.lowerBound, days: 7)),
            windowTitles: settings.sendWindowTitles ? Self.topTitles(sessions) : [],
            previousTips: (try? reviews.previousTips(since: now.addingTimeInterval(-60 * 86_400))) ?? []
        )
    }

    /// Следы прошлых дней для привычек «каждый день одно и то же».
    /// Дни, когда мака не было, пропускаются.
    private func digests(before start: Date, days: Int) -> [DayDigest] {
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: start)
        return (1...days).reversed().compactMap { offset -> DayDigest? in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: firstDay),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { return nil }
            let range = dayStart...nextDay.addingTimeInterval(-1)
            let sessions = (try? activity.sessions(in: range)) ?? []
            let launched = Set(((try? activity.appEvents(in: range)) ?? []).filter { $0.kind == .launched }.map(\.appName))
            var commandCounts: [String: Int] = [:]
            for command in (try? activity.commands(in: range)) ?? [] {
                commandCounts[command.template, default: 0] += 1
            }
            guard !sessions.isEmpty || !commandCounts.isEmpty || !launched.isEmpty else { return nil }
            // «Утро» — первые 30 минут активности, а не время по часам.
            var morningSites = Set<String>()
            if let first = sessions.first?.startedAt {
                let cutoff = first.addingTimeInterval(30 * 60)
                morningSites = Set(sessions.filter { $0.startedAt <= cutoff }.compactMap { $0.url.flatMap(URLNormalizer.host(of:)) })
            }
            return DayDigest(day: LocalDate(dayStart, calendar: calendar), launchedApps: launched, morningSites: morningSites, commandCounts: commandCounts)
        }
    }

    /// Самые долгие заголовки окон с именем приложения. Приватные сессии заголовков не имеют.
    private static func topTitles(_ sessions: [ActivitySession], limit: Int = 15) -> [String] {
        var seconds: [String: TimeInterval] = [:]
        for session in sessions where !session.isPrivate {
            guard let title = session.windowTitle else { continue }
            seconds["\(title) (\(session.appName))", default: 0] += session.duration
        }
        return seconds.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}

/// Шаг разбора для экрана F: 1 — собираю день, 2 — ищу повторы, 3 — спрашиваю Claude, 4 — собираю советы.
struct ReviewProgress: Equatable {
    var step: Int
    /// «8 ч 40 мин, 23 приложения» — когда день собран.
    var summary: String?
}
