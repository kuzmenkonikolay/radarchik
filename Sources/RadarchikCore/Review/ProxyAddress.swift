import Foundation

/// Как Радарчик ходит в Claude API: напрямую или через HTTP-прокси.
///
/// До 2026-10-19 прокси был обязательным (SPEC §5, «очень важно»). Перед
/// open source он стал необязательным: пустое поле — напрямую, как все
/// приложения на маке (с прокси из настроек macOS, если он там задан).
/// У пользователя, который пользовался Радарчиком раньше, старый адрес
/// записывается явно (`migratedProxySetting`), и у него всё по-прежнему идёт
/// только через прокси.
public enum ClaudeRoute: Equatable, Sendable {
    case direct
    case proxy(ProxyAddress)

    /// Прежний обязательный адрес — как в `curl -x http://127.0.0.1:8888 https://api.anthropic.com`.
    public static let legacyProxy = "http://127.0.0.1:8888"

    /// Из поля настроек: пусто — напрямую, адрес — через него, ошибка в адресе — nil
    /// (человек хотел прокси, молча идти напрямую нельзя).
    public static func parse(_ raw: String) -> ClaudeRoute? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .direct }
        return ProxyAddress.parse(raw).map(ClaudeRoute.proxy)
    }

    /// Что лежит в поле прокси после обновления (один раз, при первом запуске новой версии).
    /// Кто уже пользовался Радарчиком, получает старый адрес, если не задал свой:
    /// пустое поле раньше значило «никуда не ходить», а не «напрямую».
    public static func migratedProxySetting(stored: String?, isExistingInstall: Bool) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isExistingInstall && trimmed.isEmpty { return legacyProxy }
        return stored ?? ""
    }

    /// Настройки сетевой сессии. Напрямую — без своего прокси: тогда действует
    /// прокси из настроек macOS, если он там есть.
    public func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        switch self {
        case .proxy(let address):
            return address.sessionConfiguration(timeout: timeout)
        case .direct:
            return ProxyAddress.baseConfiguration(timeout: timeout)
        }
    }

    /// Ошибка сети по-человечески. Когда HTTPS-прокси недоступен, macOS отдаёт
    /// не URLError, а CFNetwork 310 (`kCFErrorHTTPSProxyConnectionFailure`) —
    /// это проверено тестом `deadProxyMeansNoRequestAtAll`.
    public func describe(_ error: Error) -> String {
        let unreachable: String
        let timedOut: String
        switch self {
        case .proxy(let address):
            unreachable = L(
                "Прокси \(address.display) не отвечает — он запущен? Без него в Claude не хожу.",
                "Proxy \(address.display) isn’t responding — is it running? Radarchik won’t reach Claude without it."
            )
            timedOut = L("Нет ответа за 15 секунд — проверь прокси \(address.display).", "No response in 15 seconds — check proxy \(address.display).")
        case .direct:
            unreachable = L("Не достучался до api.anthropic.com — проверь интернет.", "Can’t reach api.anthropic.com — check your internet connection.")
            timedOut = L("Нет ответа за 15 секунд — проверь интернет.", "No response in 15 seconds — check your internet connection.")
        }
        let nsError = error as NSError
        // 306 — HTTP-прокси недоступен, 310 — HTTPS-прокси, 311 — прокси не принял CONNECT.
        if nsError.domain == (kCFErrorDomainCFNetwork as String), [306, 310, 311].contains(nsError.code) {
            return self == .direct
                ? L("Прокси из настроек macOS не отвечает.", "The proxy from macOS settings isn’t responding.")
                : unreachable
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return unreachable
            case .timedOut:
                return timedOut
            case .notConnectedToInternet:
                return L("Нет интернета.", "No internet connection.")
            default:
                return L("Сеть: ", "Network: ") + urlError.localizedDescription
            }
        }
        return L("Сеть: ", "Network: ") + nsError.localizedDescription
    }
}

/// HTTP-прокси для запросов к Claude API. HTTPS идёт через него туннелем CONNECT.
public struct ProxyAddress: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// «127.0.0.1:8888» — для подписей.
    public var display: String { "\(host):\(port)" }

    /// Из строки настроек. Порт обязателен; схема — только http (или без схемы).
    public static func parse(_ raw: String) -> ProxyAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty,
              let port = components.port, (1...65_535).contains(port)
        else { return nil }
        return ProxyAddress(host: host, port: port)
    }

    /// Ошибка сети по-человечески (см. `ClaudeRoute.describe`).
    public func describe(_ error: Error) -> String {
        ClaudeRoute.proxy(self).describe(error)
    }
}

extension ProxyAddress {
    /// Настройки сетевой сессии, где и HTTP, и HTTPS идут через этот прокси.
    /// HTTPS — туннелем CONNECT, как `curl -x`. Проверено тестом `requestsGoThroughTheProxy`.
    ///
    /// Известное (2026-10-19): когда прокси не отвечает, macOS иногда сама пробует
    /// соединиться напрямую — тест `deadProxyMeansNoRequestAtAll` ловит это примерно
    /// раз из 10–30. Пробовали `proxyConfigurations` с `allowFailover = false` — не
    /// помогло. Решено сеть не менять: прямые соединения Радарчика закрывает правило
    /// LuLu у пользователя. Если понадобится больше — свой туннель CONNECT (вариант
    /// «Радарчик сам соединяется только с прокси»).
    public func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = Self.baseConfiguration(timeout: timeout)
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        return configuration
    }

    /// Общее для обоих маршрутов: без кэша и cookies, без ожидания сети.
    static func baseConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Ответ без стрима приходит целиком в конце, поэтому таймаут
        // бездействия такой же длинный, как и общий.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }
}
