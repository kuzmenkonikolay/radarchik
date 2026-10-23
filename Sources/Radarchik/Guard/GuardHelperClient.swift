import Foundation
import RadarchikCore
import Security

/// Почему root-часть не сделала, что просили.
enum GuardHelperError: LocalizedError {
    case notInstalled
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: L("Root-часть не установлена: make install-guard в папке Радарчика", "The root part isn’t installed: make install-guard in the Radarchik folder")
        case .unavailable(let reason): L("Root-часть не отвечает: \(reason)", "The root part isn’t responding: \(reason)")
        case .failed(let message): message
        }
    }
}

/// Пустая авторизация этого процесса. По ней root-часть сама просит право
/// и показывает окно Touch ID в твоей сессии. Живёт, пока root-часть не ответит.
final class ClientAuthorization: @unchecked Sendable {
    private let reference: AuthorizationRef
    let externalForm: Data

    init?() {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return nil }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            return nil
        }
        self.reference = reference
        self.externalForm = withUnsafeBytes(of: &external) { Data($0) }
    }

    deinit {
        AuthorizationFree(reference, [])
    }
}

/// Радарчик → root-часть по XPC (SPEC §3б, этап 2). На каждый запрос — своё
/// соединение: запросов мало, держать его открытым незачем.
enum GuardHelperClient {
    /// Открыть категорию («all» — всё) на `minutes` (0 — до ручной блокировки);
    /// `scope` — только ключи в папке проекта, `command` — подпись команды для окна Touch ID,
    /// `requester` — кто просит (`GuardHelper.notchButton` или цепочка «zsh ← Terminal»).
    /// Возвращает предупреждение, если какие-то файлы не тронуты; nil — всё в порядке.
    /// Отменил окно Touch ID — `CancellationError`.
    static func unlock(_ category: String, scope: String? = nil, minutes: Int, command: String? = nil, requester: String = "") async throws -> String? {
        guard let authorization = ClientAuthorization() else {
            throw GuardHelperError.failed(L("Не вышло подготовить окно Touch ID", "Couldn’t prepare the Touch ID window"))
        }
        let language = Language.current.rawValue
        return try await call { helper, done in
            helper.unlock(
                category, scope: scope ?? "", minutes: minutes, command: command ?? "", requester: requester, language: language,
                authorization: authorization.externalForm
            ) { ok, message in
                // Авторизация должна дожить до ответа: по ней root-часть показывала окно.
                withExtendedLifetime(authorization) {
                    if ok {
                        done(.success(message))
                    } else {
                        done(.failure(message.map { GuardHelperError.failed($0) as Error } ?? CancellationError()))
                    }
                }
            }
        }
    }

    /// Touch ID для просьбы к ssh-agent от чужого источника (договор 3): файлы не трогаются.
    /// Отменил окно — `CancellationError`; не подтвердил — `failed`.
    static func confirm(key: String, action: GuardHelper.SignAction, place: String?, requester: String) async throws {
        guard let authorization = ClientAuthorization() else {
            throw GuardHelperError.failed(L("Не вышло подготовить окно Touch ID", "Couldn’t prepare the Touch ID window"))
        }
        let language = Language.current.rawValue
        try await call { helper, done in
            helper.confirm(key, action: action.rawValue, place: place ?? "", requester: requester, language: language, authorization: authorization.externalForm) { ok, message in
                withExtendedLifetime(authorization) {
                    done(ok ? .success(()) : .failure(message.map { GuardHelperError.failed($0) as Error } ?? CancellationError()))
                }
            }
        }
    }

    /// «Сетевой надзор» (договор 4): соединения после `since`, следующий номер и ошибка захвата.
    /// `UInt64.max` — ничего старого, только номер: так начинаем после запуска.
    static func networkFlows(since: UInt64) async throws -> (flows: [NetworkFlow], next: UInt64, error: String?) {
        try await call { helper, done in
            helper.networkFlows(since: since) { data, next, error in
                let flows = (try? JSONDecoder().decode([NetworkFlow].self, from: data)) ?? []
                done(.success((flows, next, error)))
            }
        }
    }

    /// Закрыть — без Touch ID; `scope` — только ключи в папке проекта.
    static func lock(_ category: String, scope: String? = nil) async throws -> String? {
        let language = Language.current.rawValue
        return try await call { helper, done in
            helper.lock(category, scope: scope ?? "", language: language) { ok, message in
                done(ok ? .success(message) : .failure(GuardHelperError.failed(message ?? L("Не закрылось", "Didn’t lock"))))
            }
        }
    }

    /// Версия договора root-части; nil — не стоит или не отвечает.
    static func version() async -> Int? {
        try? await call { helper, done in
            helper.version { done(.success($0)) }
        }
    }

    private static func call<T: Sendable>(
        _ body: @escaping @Sendable (GuardHelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard GuardHelper.isInstalled else { throw GuardHelperError.notInstalled }
        let connection = NSXPCConnection(machServiceName: GuardHelper.machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: GuardHelperProtocol.self)
        connection.resume()
        defer {
            connection.invalidate()
            Log.guardFlow.notice("XPC: соединение с root-частью закрыто")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Log.guardFlow.error("XPC: ошибка соединения: \(error.localizedDescription, privacy: .public)")
                once.resume(.failure(GuardHelperError.unavailable(error.localizedDescription)))
            }
            guard let helper = proxy as? GuardHelperProtocol else {
                once.resume(.failure(GuardHelperError.unavailable("XPC")))
                return
            }
            body(helper) { once.resume($0) }
        }
    }
}

/// Продолжение возобновляется ровно один раз: ответ или ошибка соединения — что раньше.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
