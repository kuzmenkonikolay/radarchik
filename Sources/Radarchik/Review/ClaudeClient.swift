import Foundation
import RadarchikCore

/// Сеть к Claude API: напрямую или через HTTP-прокси из настроек (`ClaudeRoute`).
///
/// С прокси каждая сессия собирается с явным HTTP- и HTTPS-прокси. HTTPS идёт
/// через него туннелем CONNECT, как `curl -x http://127.0.0.1:8888 https://api.anthropic.com`.
/// Если прокси не отвечает, запрос падает с понятной ошибкой, а не идёт в обход.
/// Но macOS при мёртвом прокси иногда сама пробует напрямую
/// (см. `ProxyAddress.sessionConfiguration`) — у пользователя это закрывает правило LuLu.
struct ClaudeClient: Sendable {
    let route: ClaudeRoute

    /// Отправить запрос; вернуть тело и HTTP-статус.
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let session = makeSession(totalTimeout: max(request.timeoutInterval, 15) + 30)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// «Проверить связь» — как curl пользователя: до 15 секунд на всё.
    /// С ключом проверяет и ключ (GET /v1/models), без ключа — только что Anthropic отвечает.
    func checkConnection(apiKey: String?) async -> String {
        var request: URLRequest
        if let apiKey {
            request = ClaudeAPI.modelsRequest(apiKey: apiKey)
        } else {
            request = URLRequest(url: URL(string: "https://api.anthropic.com/")!)
            request.timeoutInterval = 15
        }
        do {
            let (_, status) = try await send(request)
            return describe(status: status, hasKey: apiKey != nil)
        } catch {
            return route.describe(error)
        }
    }

    /// Ответ на «Проверить связь» — с прокси или без.
    private func describe(status: Int, hasKey: Bool) -> String {
        switch route {
        case .proxy(let proxy):
            guard hasKey else {
                return L("Прокси \(proxy.display) работает, Anthropic отвечает. Осталось добавить ключ.",
                         "Proxy \(proxy.display) works and Anthropic responds. Now add your key.")
            }
            switch status {
            case 200..<300: return L("Связь есть: прокси \(proxy.display) работает, ключ подходит.",
                                     "Connected: proxy \(proxy.display) works, the key is valid.")
            case 401: return L("Прокси работает, но ключ не подошёл (401).", "The proxy works, but the key was rejected (401).")
            default: return L("Прокси работает, Anthropic ответил \(status).", "The proxy works, Anthropic answered \(status).")
            }
        case .direct:
            guard hasKey else {
                return L("Anthropic отвечает. Осталось добавить ключ.", "Anthropic responds. Now add your key.")
            }
            switch status {
            case 200..<300: return L("Связь есть, ключ подходит.", "Connected, the key is valid.")
            case 401: return L("Anthropic отвечает, но ключ не подошёл (401).", "Anthropic responds, but the key was rejected (401).")
            default: return L("Anthropic ответил \(status).", "Anthropic answered \(status).")
            }
        }
    }

    private func makeSession(totalTimeout: TimeInterval) -> URLSession {
        URLSession(configuration: route.sessionConfiguration(timeout: totalTimeout))
    }
}
