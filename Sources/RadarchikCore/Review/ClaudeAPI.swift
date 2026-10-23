import Foundation

/// Модель для разбора дня (выбирается в настройках). По умолчанию Opus 5.5.
public enum ClaudeModel: String, CaseIterable, Identifiable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .opus: "Opus 5.5"
        case .sonnet: "Sonnet 5.5"
        case .haiku: "Haiku 5.5"
        }
    }

    /// Для подсказки в настройках, при ~12 тыс. токенов в день.
    public var note: String {
        switch self {
        case .opus: L("лучшие советы, примерно $3–6 в месяц", "best tips, about $3–6 a month")
        case .sonnet: L("почти так же хорошо, вдвое дешевле", "almost as good, half the price")
        case .haiku: L("почти бесплатно, советы проще", "nearly free, simpler tips")
        }
    }

    /// $ за миллион токенов: вход, выход (прайс Anthropic на 2026-10-06).
    public var pricing: (input: Double, output: Double) {
        switch self {
        case .opus: (4, 20)
        case .sonnet: (2, 10)
        case .haiku: (0.10, 0.50)
        }
    }

    /// Серверный запасной вариант при отказе (`fallbacks: "default"`). У Haiku 5.5 его нет.
    public var supportsServerFallback: Bool { self != .haiku }
}

/// Сколько сил уйдёт на совет. В схеме ответа и в базе это слово на языке
/// разбора: «низкий» или «low». Старые советы — по-русски, поэтому слово
/// узнаём на обоих языках, а показываем на текущем.
public enum TipEffort: CaseIterable, Sendable {
    case low
    case medium
    case high

    /// Слово на текущем языке — для схемы ответа и для экрана.
    public var word: String {
        switch self {
        case .low: L("низкий", "low")
        case .medium: L("средний", "medium")
        case .high: L("высокий", "high")
        }
    }

    /// Из сохранённого слова на любом из языков.
    public init?(word: String) {
        switch word.lowercased() {
        case "низкий", "low": self = .low
        case "средний", "medium": self = .medium
        case "высокий", "high": self = .high
        default: return nil
        }
    }
}

/// Совет от Claude — ровно тот JSON, что в ТЗ (SPEC §3).
public struct ReviewTip: Codable, Hashable, Sendable {
    public var title: String
    public var observation: String
    public var suggestion: String
    /// Слово из `TipEffort` на языке разбора.
    public var effort: String
    public var timeSavedPerWeekMin: Int
    public var toolHint: String?

    enum CodingKeys: String, CodingKey {
        case title, observation, suggestion, effort
        case timeSavedPerWeekMin = "time_saved_per_week_min"
        case toolHint = "tool_hint"
    }

    public init(title: String, observation: String, suggestion: String, effort: String, timeSavedPerWeekMin: Int, toolHint: String?) {
        self.title = title
        self.observation = observation
        self.suggestion = suggestion
        self.effort = effort
        self.timeSavedPerWeekMin = timeSavedPerWeekMin
        self.toolHint = toolHint
    }
}

public struct ReviewResult: Hashable, Sendable {
    public let tips: [ReviewTip]
    /// Какая модель ответила (при отказе сервер мог передать запрос запасной).
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double

    public init(tips: [ReviewTip], model: String, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        self.tips = tips
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}

public enum ClaudeAPIError: Error, Equatable, CustomStringConvertible {
    case http(status: Int, type: String?, message: String?)
    case refusal(category: String?)
    case truncated
    case badResponse(String)

    public var description: String {
        switch self {
        case .http(status: 401, _, _):
            L("Ключ Claude не подошёл (401) — проверь его в настройках.", "The Claude key was rejected (401) — check it in settings.")
        case .http(status: 429, _, _):
            L("Слишком много запросов к Claude (429) — попробую позже.", "Too many requests to Claude (429) — I’ll try later.")
        case .http(let status, _, let message):
            L("Claude ответил ошибкой \(status)", "Claude returned error \(status)") + (message.map { ": \($0)" } ?? "") + "."
        case .refusal(let category):
            L("Claude отказался разбирать день", "Claude declined to review the day") + (category.map { " (\($0))" } ?? "") + "."
        case .truncated:
            L("Ответ Claude обрезался — попробую ещё раз позже.", "Claude’s answer was cut off — I’ll try again later.")
        case .badResponse(let detail):
            L("Не понял ответ Claude: \(detail).", "Couldn’t understand Claude’s answer: \(detail).")
        }
    }
}

/// Запрос к Messages API и разбор ответа — без сети, чтобы было что тестировать.
/// Отправляет `ClaudeClient` в приложении: напрямую или через прокси из настроек (SPEC §5).
///
/// Официального SDK для Swift нет, поэтому это обычный HTTP по документации
/// (скилл claude-api, 2026-10): structured outputs через `output_config.format`,
/// мышление у Opus 5.5 всегда включено (параметр `thinking` не шлём), глубину
/// задаёт `effort`, при отказе классификатора — серверный `fallbacks: "default"`.
public enum ClaudeAPI {
    public static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    static let version = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let maxTokens = 16_000

    public static func reviewRequest(apiKey: String, model: ClaudeModel, system: String, user: String) throws -> URLRequest {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        // Ответ приходит целиком в конце: с мышлением это может занять пару минут.
        request.timeoutInterval = 240
        setHeaders(&request, apiKey: apiKey)
        if model.supportsServerFallback {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": tipsSchema()],
            ],
        ]
        if model.supportsServerFallback {
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// GET /v1/models — для «Проверить связь»: проверяет и прокси, и ключ.
    public static func modelsRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        setHeaders(&request, apiKey: apiKey)
        return request
    }

    public static func parseReview(data: Data, statusCode: Int, model: ClaudeModel) throws -> ReviewResult {
        guard (200..<300).contains(statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw ClaudeAPIError.http(status: statusCode, type: envelope?.error.type, message: envelope?.error.message)
        }
        let message: MessageResponse
        do {
            message = try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch {
            throw ClaudeAPIError.badResponse(L("неожиданный формат ответа", "unexpected response format"))
        }
        // Сначала причина остановки: при отказе или обрезке JSON может не совпасть со схемой.
        switch message.stopReason {
        case "refusal": throw ClaudeAPIError.refusal(category: message.stopDetails?.category)
        case "max_tokens": throw ClaudeAPIError.truncated
        default: break
        }
        // Блоки мышления (пустые) и служебные пропускаем, берём только текст.
        let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard let json = text.data(using: .utf8), let envelope = try? JSONDecoder().decode(TipsEnvelope.self, from: json) else {
            throw ClaudeAPIError.badResponse(L("в ответе нет советов в ожидаемом виде", "no tips in the expected shape"))
        }
        let input = message.usage?.inputTokens ?? 0
        let output = message.usage?.outputTokens ?? 0
        return ReviewResult(
            tips: envelope.tips.compactMap(clean),
            model: message.model ?? model.rawValue,
            inputTokens: input,
            outputTokens: output,
            costUSD: Double(input) * model.pricing.input / 1_000_000 + Double(output) * model.pricing.output / 1_000_000
        )
    }

    // MARK: - «Что это?» (2026-10-22)

    /// Короткий ответ по схеме: что это, verdict, что делать. Усилие low, минута на всё.
    public static func explainRequest(apiKey: String, model: ClaudeModel, facts: ExplainFacts) throws -> URLRequest {
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        setHeaders(&request, apiKey: apiKey)
        if model.supportsServerFallback {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2_000,
            "system": ExplainPrompt.system,
            "messages": [["role": "user", "content": ExplainPrompt.user(facts)]],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": explanationSchema()],
            ],
        ]
        if model.supportsServerFallback {
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func parseExplanation(data: Data, statusCode: Int, model: ClaudeModel) throws -> ExplainResult {
        guard (200..<300).contains(statusCode) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw ClaudeAPIError.http(status: statusCode, type: envelope?.error.type, message: envelope?.error.message)
        }
        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data) else {
            throw ClaudeAPIError.badResponse(L("неожиданный формат ответа", "unexpected response format"))
        }
        switch message.stopReason {
        case "refusal": throw ClaudeAPIError.refusal(category: message.stopDetails?.category)
        case "max_tokens": throw ClaudeAPIError.truncated
        default: break
        }
        let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard let json = text.data(using: .utf8), let envelope = try? JSONDecoder().decode(ExplainEnvelope.self, from: json) else {
            throw ClaudeAPIError.badResponse(L("в ответе нет объяснения в ожидаемом виде", "no explanation in the expected shape"))
        }
        let input = message.usage?.inputTokens ?? 0
        let output = message.usage?.outputTokens ?? 0
        return ExplainResult(
            explanation: Explanation(
                what: envelope.what.trimmingCharacters(in: .whitespacesAndNewlines),
                verdict: Explanation.Verdict(rawValue: envelope.verdict.lowercased()) ?? .unknown,
                advice: envelope.advice.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            model: message.model ?? model.rawValue,
            costUSD: Double(input) * model.pricing.input / 1_000_000 + Double(output) * model.pricing.output / 1_000_000
        )
    }

    static func explanationSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "what": ["type": "string"],
                "verdict": ["type": "string", "enum": ["normal", "attention", "unknown"]],
                "advice": ["type": "string"],
            ],
            "required": ["what", "verdict", "advice"],
            "additionalProperties": false,
        ]
    }

    private struct ExplainEnvelope: Decodable {
        let what: String
        let verdict: String
        let advice: String
    }

    // MARK: - Внутреннее

    private static func setHeaders(_ request: inout URLRequest, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
    }

    /// JSON Schema ответа. Structured outputs требуют `additionalProperties: false`
    /// у каждого объекта и не поддерживают ограничения длины и чисел.
    static func tipsSchema() -> [String: Any] {
        let tip: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "observation": ["type": "string"],
                "suggestion": ["type": "string"],
                "effort": ["type": "string", "enum": TipEffort.allCases.map(\.word)],
                "time_saved_per_week_min": ["type": "integer"],
                "tool_hint": ["type": "string"],
            ],
            "required": ["title", "observation", "suggestion", "effort", "time_saved_per_week_min", "tool_hint"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": ["tips": ["type": "array", "items": tip]],
            "required": ["tips"],
            "additionalProperties": false,
        ]
    }

    /// Совет без заголовка отбрасываем, усилие приводим к одному из трёх слов
    /// текущего языка, минуты — не меньше нуля.
    static func clean(_ tip: ReviewTip) -> ReviewTip? {
        var tip = tip
        tip.title = tip.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tip.title.isEmpty else { return nil }
        tip.observation = tip.observation.trimmingCharacters(in: .whitespacesAndNewlines)
        tip.suggestion = tip.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        tip.effort = (TipEffort(word: tip.effort) ?? .medium).word
        tip.timeSavedPerWeekMin = max(0, tip.timeSavedPerWeekMin)
        let hint = tip.toolHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        tip.toolHint = (hint?.isEmpty ?? true) ? nil : hint
        return tip
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
        struct StopDetails: Decodable {
            let category: String?
        }

        let model: String?
        let content: [Block]
        let stopReason: String?
        let stopDetails: StopDetails?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case model, content, usage
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }
    }

    private struct TipsEnvelope: Decodable {
        let tips: [ReviewTip]
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let type: String
            let message: String
        }
        let error: Detail
    }
}
