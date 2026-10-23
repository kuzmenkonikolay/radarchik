import Foundation
import Testing
@testable import RadarchikCore

/// «Что это?» (2026-10-22): факты об алерте уходят в Claude списком строк, ответ приходит
/// по схеме — что это, вердикт, что делать.
@Suite("Что это?: вопрос к Claude")
struct ExplainTests {
    static let facts = ExplainFacts(
        subject: .resource, headline: "duetexpertd ест 76% процессора — обычно почти ноль", process: "duetexpertd", path: "/usr/libexec/duetexpertd",
        signing: "системный, подпись Apple", chain: "duetexpertd ← launchd", notes: ["Держится 5 мин."]
    )

    @Test func promptListsTheFacts() {
        let prompt = ExplainPrompt.user(Self.facts)
        #expect(prompt.hasPrefix("Заметил: duetexpertd ест 76% процессора"))
        #expect(prompt.contains("Вид: процесс ест больше обычного"))
        #expect(prompt.contains("Путь: /usr/libexec/duetexpertd"))
        #expect(prompt.contains("Подпись: системный, подпись Apple"))
        #expect(prompt.contains("Кто запустил: duetexpertd ← launchd"))
        #expect(prompt.hasSuffix("Держится 5 мин."))
        #expect(!prompt.contains("Командная строка"))
        let network = ExplainFacts(subject: .network, headline: "x", process: "curl", chain: "curl ← zsh", notes: ["через прокси 127.0.0.1:8888"], commandLine: nil)
        #expect(ExplainPrompt.user(network).contains("Вид: скрипт или агент вышел в сеть"))
        #expect(ExplainPrompt.system.contains("verdict"))
        english {
            #expect(ExplainPrompt.user(Self.facts).contains("Signature: системный, подпись Apple"))
            #expect(ExplainPrompt.system.contains("Radarchik"))
        }
    }

    @Test func requestIsSmallAndStructured() throws {
        let request = try ClaudeAPI.explainRequest(apiKey: "sk-test", model: .opus, facts: Self.facts)
        #expect(request.url == ClaudeAPI.messagesURL)
        #expect(request.timeoutInterval == 60)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == ClaudeModel.opus.rawValue)
        #expect(body["max_tokens"] as? Int == 2_000)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "low")
        let format = try #require(config["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["what", "verdict", "advice"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == ExplainPrompt.user(Self.facts))
        #expect(body["system"] as? String == ExplainPrompt.system)
    }

    private static func response(text: String, stop: String = "end_turn", input: Int = 400, output: Int = 80) -> Data {
        let json: [String: Any] = [
            "model": "claude-opus-5-5", "stop_reason": stop,
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
            "usage": ["input_tokens": input, "output_tokens": output],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func answerIsParsedWithVerdictAndPrice() throws {
        let data = Self.response(text: #"{"what": "duetexpertd — системный сервис подсказок Siri.", "verdict": "normal", "advice": "Ничего не делай, через пару минут успокоится."}"#)
        let result = try ClaudeAPI.parseExplanation(data: data, statusCode: 200, model: .opus)
        #expect(result.explanation.what == "duetexpertd — системный сервис подсказок Siri.")
        #expect(result.explanation.verdict == .normal)
        #expect(result.explanation.advice == "Ничего не делай, через пару минут успокоится.")
        #expect(result.model == "claude-opus-5-5")
        let expected = 400 * ClaudeModel.opus.pricing.input / 1_000_000 + 80 * ClaudeModel.opus.pricing.output / 1_000_000
        #expect(abs(result.costUSD - expected) < 1e-9)
        // Незнакомый вердикт — «не уверен»; отказ и обрезка — ошибки; чужой статус — ошибка с кодом.
        let odd = try ClaudeAPI.parseExplanation(data: Self.response(text: #"{"what": "x", "verdict": "weird", "advice": "y"}"#), statusCode: 200, model: .opus)
        #expect(odd.explanation.verdict == .unknown)
        #expect(throws: ClaudeAPIError.self) { try ClaudeAPI.parseExplanation(data: Self.response(text: "", stop: "refusal"), statusCode: 200, model: .opus) }
        #expect(throws: ClaudeAPIError.self) { try ClaudeAPI.parseExplanation(data: Self.response(text: "not json"), statusCode: 200, model: .opus) }
        #expect(throws: ClaudeAPIError.self) { try ClaudeAPI.parseExplanation(data: Data("{}".utf8), statusCode: 401, model: .opus) }
    }

    @Test func programNameComesFromTheRecord() {
        func event(_ kind: GuardEventKind, title: String, detail: String?) -> GuardEvent {
            GuardEvent(id: 1, kind: kind, level: .warning, at: .distantPast, title: title, detail: detail, allowKey: nil, status: .logged, statusChangedAt: nil)
        }
        #expect(GuardPhrase.programName(event(.network, title: "Новый адрес у Claude Code · curl: docs.python.org", detail: "151.101.1.223 · curl ← zsh ← Claude Code ← zsh ← Terminal")) == "curl")
        #expect(GuardPhrase.programName(event(.network, title: "t", detail: "через прокси 127.0.0.1:8888 · claude ← zsh ← Terminal")) == "claude")
        #expect(GuardPhrase.programName(event(.agent, title: "t", detail: "ключ id_ed25519 · ssh-keygen ← git ← zsh ← Terminal")) == "ssh-keygen")
        #expect(GuardPhrase.programName(event(.process, title: "node -e — запустил Cursor", detail: "/opt/homebrew/bin/node -e const x = 1")) == "node")
        #expect(GuardPhrase.programName(event(.process, title: "python -c — запустил zsh", detail: nil)) == "python")
    }
}
