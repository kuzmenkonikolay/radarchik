import Foundation
import Testing
@testable import RadarchikCore

// Этап 4: разбор дня и советы.

private let moscow: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return calendar
}()

/// Момент по московским часам: at(18, 22, 5) — 18 октября 2026, 22:05.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    moscow.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func summary(
    apps: [DaySummary.AppTime] = [], sites: [DaySummary.SiteTime] = [], commands: [DaySummary.CommandCount] = [],
    pastes: [DaySummary.PasteFlow] = [], switches: [DaySummary.SwitchPair] = [],
    callSeconds: TimeInterval = 0, callCount: Int = 0, activeSeconds: TimeInterval = 0
) -> DaySummary {
    DaySummary(apps: apps, sites: sites, commands: commands, pastes: pastes, switches: switches,
               callSeconds: callSeconds, callCount: callCount, activeSeconds: activeSeconds)
}

@Suite("Разбор дня: расписание")
struct ReviewScheduleTests {
    @Test func firstReviewWaitsForTheEvening() {
        #expect(!ReviewSchedule.isDue(lastReview: nil, now: at(18, 21, 59), hour: 22, calendar: moscow))
        #expect(ReviewSchedule.isDue(lastReview: nil, now: at(18, 22, 0), hour: 22, calendar: moscow))
    }

    @Test func onceADay() {
        #expect(!ReviewSchedule.isDue(lastReview: at(18, 22, 1), now: at(18, 23, 30), hour: 22, calendar: moscow))
        #expect(!ReviewSchedule.isDue(lastReview: at(18, 22, 1), now: at(19, 8, 0), hour: 22, calendar: moscow))
        #expect(ReviewSchedule.isDue(lastReview: at(18, 22, 1), now: at(19, 22, 0), hour: 22, calendar: moscow))
    }

    @Test func catchesUpInTheMorningIfTheMacSlept() {
        // 18-го в 22:00 мак спал → разбор при первой активности 19-го.
        #expect(ReviewSchedule.isDue(lastReview: at(17, 22, 5), now: at(19, 8, 0), hour: 22, calendar: moscow))
    }

    @Test func periodStartsAtLastReviewButNotEarlierThanTwoDays() {
        #expect(ReviewSchedule.period(lastReview: at(17, 22, 5), now: at(19, 8, 0), calendar: moscow).lowerBound == at(17, 22, 5))
        #expect(ReviewSchedule.period(lastReview: at(1, 22, 0), now: at(19, 8, 0), calendar: moscow).lowerBound == at(17, 8, 0))
        #expect(ReviewSchedule.period(lastReview: nil, now: at(18, 22, 0), calendar: moscow).lowerBound == at(18, 0, 0))
    }
}

@Suite("Разбор дня: поиск рутины")
struct RoutineDetectorTests {
    @Test func repeatedCommandIsACandidateAndDailyRepeatsAreNoted() {
        let template = "docker compose run --rm -e RAILS_MASTER_KEY=… web bin/rails c"
        let today = summary(commands: [DaySummary.CommandCount(template: template, count: 12, totalDurationMs: 60_000, failures: 0)])
        let history = (14...17).map { DayDigest(day: LocalDate(year: 2026, month: 10, day: $0), launchedApps: [], morningSites: [], commandCounts: [template: 6]) }
        let candidates = RoutineDetector.candidates(today: today, history: history)
        let candidate = candidates.first { $0.kind == .repeatedCommand }
        #expect(candidate != nil)
        #expect(candidate?.evidence.contains("12") == true)
        #expect(candidate?.evidence.contains(template) == true)
        #expect(candidate?.evidence.contains("4 из последних 4") == true)
    }

    @Test func slowAndFailingCommands() {
        let today = summary(commands: [
            DaySummary.CommandCount(template: "make app", count: 6, totalDurationMs: 25 * 60_000, failures: 0),
            DaySummary.CommandCount(template: "swift test", count: 5, totalDurationMs: 30_000, failures: 4),
        ])
        let kinds = RoutineDetector.candidates(today: today, history: []).map(\.kind)
        #expect(kinds.contains(.slowCommand))
        #expect(kinds.contains(.failingCommand))
    }

    @Test func switchingCopyingAndSites() {
        let today = summary(
            sites: [DaySummary.SiteTime(host: "github.com", seconds: 2400, visits: 15)],
            pastes: [DaySummary.PasteFlow(fromApp: "Почта", toApp: "Arc", count: 7)],
            switches: [DaySummary.SwitchPair(first: "Arc", second: "Терминал", count: 34)]
        )
        let candidates = RoutineDetector.candidates(today: today, history: [])
        #expect(candidates.contains { $0.kind == .switching && $0.evidence.contains("34") })
        #expect(candidates.contains { $0.kind == .copying && $0.evidence.contains("Почта") && $0.evidence.contains("Arc") })
        #expect(candidates.contains { $0.kind == .frequentSite && $0.evidence.contains("github.com") })
    }

    @Test func appsLaunchedByHandAlmostEveryDay() {
        let history = (13...17).map { day in
            DayDigest(day: LocalDate(year: 2026, month: 10, day: day),
                      launchedApps: day == 15 ? ["Telegram"] : ["Telegram", "Slack"], morningSites: ["mail.ru", "github.com"], commandCounts: [:])
        }
        let candidates = RoutineDetector.candidates(today: summary(), history: history)
        let launches = candidates.first { $0.kind == .dailyLaunches }
        #expect(launches?.evidence.contains("Telegram") == true)
        #expect(launches?.evidence.contains("Slack") == true)
        #expect(candidates.contains { $0.kind == .morningSites && $0.evidence.contains("github.com") })
    }

    @Test func quietDayHasNoCandidates() {
        let today = summary(
            commands: [DaySummary.CommandCount(template: "ls", count: 3, totalDurationMs: 100, failures: 0)],
            switches: [DaySummary.SwitchPair(first: "Arc", second: "Терминал", count: 5)]
        )
        #expect(RoutineDetector.candidates(today: today, history: []).isEmpty)
    }

    @Test func englishEvidence() {
        english {
            let today = summary(
                commands: [DaySummary.CommandCount(template: "make test", count: 12, totalDurationMs: 0, failures: 0)],
                switches: [DaySummary.SwitchPair(first: "Arc", second: "Terminal", count: 34)]
            )
            let candidates = RoutineDetector.candidates(today: today, history: [])
            #expect(candidates.contains { $0.evidence == "Command `make test` — 12 times a day" })
            #expect(candidates.contains { $0.evidence == "Switched Arc ↔ Terminal 34 times" })
        }
    }

    @Test func candidatesAreSortedByTimeToWinBackAndLimited() {
        let commands = (1...12).map { DaySummary.CommandCount(template: "cmd\($0)", count: 5 + $0, totalDurationMs: 0, failures: 0) }
        let candidates = RoutineDetector.candidates(today: summary(commands: commands), history: [], limit: 5)
        #expect(candidates.count == 5)
        #expect(candidates.first?.evidence.contains("cmd12") == true)
        #expect(zip(candidates, candidates.dropFirst()).allSatisfy { $0.weeklyMinutes >= $1.weeklyMinutes })
    }
}

@Suite("Разбор дня: текст для Claude")
struct ReviewPromptTests {
    func input(titles: [String] = []) -> ReviewInput {
        ReviewInput(
            periodStart: at(18, 9, 12), periodEnd: at(18, 22, 0),
            summary: summary(
                apps: [DaySummary.AppTime(bundleId: "company.thebrowser.Browser", appName: "Arc", seconds: 3 * 3600 + 600)],
                sites: [DaySummary.SiteTime(host: "github.com", seconds: 3900, visits: 23)],
                commands: [DaySummary.CommandCount(template: "make test", count: 9, totalDurationMs: 90_000, failures: 1)],
                activeSeconds: 7 * 3600 + 2400
            ),
            candidates: [RoutineCandidate(kind: .repeatedCommand, evidence: "Команда `make test` — 9 раз за день", weeklyMinutes: 11)],
            windowTitles: titles,
            previousTips: [PreviousTip(title: "Алиас для rails c", status: .dismissed), PreviousTip(title: "Кнопка утренних вкладок", status: .done)]
        )
    }

    @Test func messageCarriesTheSummaryCandidatesAndPreviousTips() {
        let text = ReviewPrompt.userMessage(input(), calendar: moscow)
        #expect(text.contains("18 октября"))
        #expect(text.contains("09:12"))
        #expect(text.contains("Arc — 3 ч 10 мин"))
        #expect(text.contains("github.com — 1 ч 05 мин · 23"))
        #expect(text.contains("`make test` — ×9"))
        #expect(text.contains("Команда `make test` — 9 раз за день"))
        #expect(text.contains("«Алиас для rails c» — не надо"))
        #expect(text.contains("«Кнопка утренних вкладок» — уже сделал"))
        #expect(!text.contains("Заголовки окон"))
    }

    @Test func windowTitlesOnlyWhenAllowed() {
        let text = ReviewPrompt.userMessage(input(titles: ["SPEC.md — radarchik"]), calendar: moscow)
        #expect(text.contains("Заголовки окон"))
        #expect(text.contains("SPEC.md — radarchik"))
    }

    @Test func systemPromptAsksForTipsInRussian() {
        #expect(ReviewPrompt.system.contains("3–5"))
        #expect(ReviewPrompt.system.contains("по-русски"))
    }

    /// Советы приходят на языке интерфейса: по-английски и запрос английский.
    @Test func englishInterfaceGetsAnEnglishPrompt() {
        english {
            let text = ReviewPrompt.userMessage(input(), calendar: moscow)
            #expect(text.contains("October 18, 2026, 09:12–22:00"))
            #expect(text.contains("Arc — 3h 10m"))
            #expect(text.contains("github.com — 1h 5m · 23"))
            #expect(text.contains("`make test` — ×9"))
            #expect(text.contains("“Алиас для rails c” — not needed"))
            #expect(!text.contains("Window titles"))
            #expect(ReviewPrompt.system.contains("3–5"))
            #expect(ReviewPrompt.system.contains("in English"))
            #expect(!ReviewPrompt.system.contains("по-русски"))
        }
    }
}

@Suite("Разбор дня: запрос к Claude и ответ")
struct ClaudeAPITests {
    func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func opusRequestUsesStructuredOutputsAndServerFallback() throws {
        let request = try ClaudeAPI.reviewRequest(apiKey: "sk-test", model: .opus, system: "S", user: "U")
        #expect(request.url == ClaudeAPI.messagesURL)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")

        let json = try body(request)
        #expect(json["model"] as? String == "claude-opus-5-5")
        #expect(json["max_tokens"] as? Int == 16_000)
        #expect(json["system"] as? String == "S")
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["thinking"] == nil)   // у Opus 5.5 мышление всегда включено, отключать нельзя
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "U")
        let config = try #require(json["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["tips"])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func haikuHasNoServerFallback() throws {
        let request = try ClaudeAPI.reviewRequest(apiKey: "sk-test", model: .haiku, system: "S", user: "U")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try body(request)["fallbacks"] == nil)
    }

    @Test func parsesTipsSkippingThinkingAndCountsCost() throws {
        let tips = #"{"tips":[{"title":"Алиас для rails c","observation":"12 раз набирал длинную команду","suggestion":"alias rc='docker compose run --rm web bin/rails c'","effort":"низкий","time_saved_per_week_min":15,"tool_hint":"zsh alias"}]}"#
        let response: [String: Any] = [
            "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "abc"],
                ["type": "text", "text": tips],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 12_000, "output_tokens": 2_500],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let result = try ClaudeAPI.parseReview(data: data, statusCode: 200, model: .opus)
        #expect(result.tips.count == 1)
        #expect(result.tips[0].title == "Алиас для rails c")
        #expect(result.tips[0].timeSavedPerWeekMin == 15)
        #expect(result.tips[0].effort == "низкий")
        #expect(result.inputTokens == 12_000)
        #expect(result.outputTokens == 2_500)
        // Opus 5.5: $4 / $20 за миллион → 0,048 + 0,05
        #expect(abs(result.costUSD - 0.098) < 0.000_001)
    }

    @Test func refusalTruncationAndHttpErrorsAreReported() throws {
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

        let refusal = try data(["content": [], "stop_reason": "refusal", "stop_details": ["type": "refusal", "category": "cyber"], "usage": ["input_tokens": 10, "output_tokens": 0]])
        #expect(throws: ClaudeAPIError.refusal(category: "cyber")) { try ClaudeAPI.parseReview(data: refusal, statusCode: 200, model: .opus) }

        let truncated = try data(["content": [["type": "text", "text": "{\"tips\":["]], "stop_reason": "max_tokens", "usage": ["input_tokens": 10, "output_tokens": 16_000]])
        #expect(throws: ClaudeAPIError.truncated) { try ClaudeAPI.parseReview(data: truncated, statusCode: 200, model: .opus) }

        let unauthorized = try data(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])
        #expect(throws: ClaudeAPIError.http(status: 401, type: "authentication_error", message: "invalid x-api-key")) {
            try ClaudeAPI.parseReview(data: unauthorized, statusCode: 401, model: .opus)
        }
    }

    /// Усилие хранится словом языка, на котором шёл разбор. Старые советы — по-русски,
    /// поэтому слово узнаём на обоих языках, а показываем на текущем.
    @Test func effortWordsFollowTheLanguage() throws {
        #expect(TipEffort(word: "низкий") == .low)
        #expect(TipEffort(word: "high") == .high)
        #expect(TipEffort(word: "очень") == nil)
        let oldTip = ReviewTip(title: "Алиас", observation: "", suggestion: "", effort: "средний", timeSavedPerWeekMin: 5, toolHint: nil)
        english {
            #expect(TipEffort.low.word == "low")
            #expect(ClaudeAPI.clean(oldTip)?.effort == "medium")
            #expect(ClaudeAPIError.truncated.description == "Claude’s answer was cut off — I’ll try again later.")
        }
        let request = try english { try ClaudeAPI.reviewRequest(apiKey: "sk-test", model: .opus, system: "S", user: "U") }
        let format = try #require((try body(request)["output_config"] as? [String: Any])?["format"] as? [String: Any])
        let tip = try #require(((format["schema"] as? [String: Any])?["properties"] as? [String: Any])?["tips"] as? [String: Any])
        let effort = try #require(((tip["items"] as? [String: Any])?["properties"] as? [String: Any])?["effort"] as? [String: Any])
        #expect(effort["enum"] as? [String] == ["low", "medium", "high"])
    }
}

@Suite("Разбор дня: хранение советов")
struct ReviewRepositoryTests {
    func result() -> ReviewResult {
        ReviewResult(
            tips: [
                ReviewTip(title: "Алиас", observation: "12 раз", suggestion: "alias rc=…", effort: "низкий", timeSavedPerWeekMin: 15, toolHint: "zsh"),
                ReviewTip(title: "Кнопка вкладок", observation: "каждое утро", suggestion: "Shortcuts", effort: "средний", timeSavedPerWeekMin: 20, toolHint: nil),
            ],
            model: "claude-opus-5-5", inputTokens: 100, outputTokens: 50, costUSD: 0.01
        )
    }

    @Test func savesReviewWithTipsAndTracksStatuses() throws {
        let repository = try ReviewRepository(database: Database(path: ":memory:"))
        let (review, tips) = try repository.save(periodStart: at(18, 9), periodEnd: at(18, 22), createdAt: at(18, 22, 1), prompt: "P", result: result())
        #expect(review.model == "claude-opus-5-5")
        #expect(tips.map(\.title) == ["Алиас", "Кнопка вкладок"])
        #expect(tips.allSatisfy { $0.status == .new })
        #expect(try repository.latestReview()?.createdAt == at(18, 22, 1))
        #expect(try repository.latestReview()?.prompt == "P")

        try repository.setStatus(.dismissed, tipId: tips[0].id, at: at(18, 22, 30))
        try repository.setStatus(.planned, tipId: tips[1].id, at: at(18, 22, 31))
        #expect(try repository.tips().first { $0.id == tips[0].id }?.status == .dismissed)
        #expect(try repository.previousTips(since: at(1, 0)).sorted { $0.title < $1.title } == [
            PreviousTip(title: "Алиас", status: .dismissed),
            PreviousTip(title: "Кнопка вкладок", status: .planned),
        ])
    }

    @Test func noReviewYet() throws {
        let repository = try ReviewRepository(database: Database(path: ":memory:"))
        #expect(try repository.latestReview() == nil)
        #expect(try repository.tips().isEmpty)
    }

    @Test func mascotWavesWhenTipsAreReady() {
        #expect(MascotBrain.state(isExpanded: true, mood: .growing, isResting: false, event: nil, hasNewTips: true) == .tipWave)
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: false, event: nil, hasNewTips: true) == .idleScan)
    }
}

@Suite("Разбор дня: прокси")
struct ProxyAddressTests {
    @Test func parsesHttpProxyFromSettings() {
        #expect(ProxyAddress.parse("http://127.0.0.1:8888") == ProxyAddress(host: "127.0.0.1", port: 8888))
        #expect(ProxyAddress.parse("127.0.0.1:8888") == ProxyAddress(host: "127.0.0.1", port: 8888))
        #expect(ProxyAddress.parse("  http://localhost:3128/  ") == ProxyAddress(host: "localhost", port: 3128))
        #expect(ProxyAddress.parse("http://127.0.0.1:8888")?.display == "127.0.0.1:8888")
    }

    @Test func rejectsWhatWeCannotUse() {
        #expect(ProxyAddress.parse("") == nil)
        #expect(ProxyAddress.parse("http://127.0.0.1") == nil)          // без порта не угадываем
        #expect(ProxyAddress.parse("socks5://127.0.0.1:1080") == nil)   // поддерживаем только HTTP-прокси
        #expect(ProxyAddress.parse("http://127.0.0.1:99999") == nil)
    }

    // MARK: - Прокси необязателен (решение 2026-10-19, перед open source)

    @Test func emptyFieldMeansDirectConnection() {
        #expect(ClaudeRoute.parse("") == .direct)
        #expect(ClaudeRoute.parse("   ") == .direct)
        #expect(ClaudeRoute.parse("http://127.0.0.1:8888") == .proxy(ProxyAddress(host: "127.0.0.1", port: 8888)))
        // Адрес с ошибкой — не «напрямую», а ошибка: человек хотел прокси.
        #expect(ClaudeRoute.parse("http://127.0.0.1") == nil)
        #expect(ClaudeRoute.parse("socks5://127.0.0.1:1080") == nil)
    }

    @Test func existingInstallKeepsGoingThroughTheOldProxy() {
        // Кто пользовался Радарчиком до 2026-10-19 и прокси не трогал, получает
        // старый адрес явно: у него по-прежнему всё только через прокси.
        #expect(ClaudeRoute.migratedProxySetting(stored: nil, isExistingInstall: true) == "http://127.0.0.1:8888")
        // Пустое поле раньше значило «никуда не ходить», а не «напрямую».
        #expect(ClaudeRoute.migratedProxySetting(stored: " ", isExistingInstall: true) == "http://127.0.0.1:8888")
        #expect(ClaudeRoute.migratedProxySetting(stored: "http://10.0.0.2:3128", isExistingInstall: true) == "http://10.0.0.2:3128")
    }

    @Test func newInstallStartsWithoutProxy() {
        #expect(ClaudeRoute.migratedProxySetting(stored: nil, isExistingInstall: false) == "")
    }

    @Test func networkErrorsAreExplainedForEachRoute() {
        let proxy = ClaudeRoute.proxy(ProxyAddress(host: "127.0.0.1", port: 8888))
        let refused = URLError(.cannotConnectToHost)
        #expect(proxy.describe(refused) == "Прокси 127.0.0.1:8888 не отвечает — он запущен? Без него в Claude не хожу.")
        #expect(ClaudeRoute.direct.describe(refused) == "Не достучался до api.anthropic.com — проверь интернет.")
        #expect(ClaudeRoute.direct.describe(URLError(.notConnectedToInternet)) == "Нет интернета.")
        english {
            #expect(proxy.describe(refused) == "Proxy 127.0.0.1:8888 isn’t responding — is it running? Radarchik won’t reach Claude without it.")
            #expect(ClaudeRoute.direct.describe(refused) == "Can’t reach api.anthropic.com — check your internet connection.")
            #expect(ClaudeRoute.direct.describe(URLError(.timedOut)) == "No response in 15 seconds — check your internet connection.")
        }
    }
}
