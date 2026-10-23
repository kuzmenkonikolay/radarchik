import Foundation
import RadarchikCore

/// Кого пускать. Требование к подписи клиента записывает установщик
/// (`make install-guard`) — подпись Радарчика сертификатом «Radarchik dev».
///
/// Это вторая линия: подпись можно подделать (у codesign для этого сертификата
/// стоит «Разрешать всегда», и подписаться им может любая программа под тобой).
/// Поэтому открыть всё равно нельзя без Touch ID, который проверяет сама root-часть.
/// root-клиентов не пускаем: у root нет домашней папки с твоими ключами.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let engine: HelperEngine

    init(engine: HelperEngine) {
        self.engine = engine
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let requirement = (try? String(contentsOfFile: GuardHelper.requirementPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let uid = connection.effectiveUserIdentifier
        guard !requirement.isEmpty, uid != 0 else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: GuardHelperProtocol.self)
        connection.exportedObject = HelperService(engine: engine, uid: uid, pid: connection.processIdentifier)
        connection.resume()
        return true
    }
}

/// То, что видит Радарчик по XPC. Кто спрашивает, берём у соединения
/// (uid и pid из ядра), а не со слов клиента.
final class HelperService: NSObject, GuardHelperProtocol {
    private let engine: HelperEngine
    private let uid: uid_t
    /// Процесс клиента: по нему окно Touch ID скажет, кто просит.
    private let pid: pid_t

    init(engine: HelperEngine, uid: uid_t, pid: pid_t) {
        self.engine = engine
        self.uid = uid
        self.pid = pid
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(GuardHelper.version)
    }

    func unlock(
        _ category: String, scope: String, minutes: Int, command: String, requester: String, language: String, authorization: Data,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        engine.unlock(
            categoryName: category, scope: scope, minutes: minutes, command: command, requester: requester, language: language,
            authorization: authorization, uid: uid, clientPid: pid, reply: reply
        )
    }

    func lock(_ category: String, scope: String, language: String, reply: @escaping @Sendable (Bool, String?) -> Void) {
        engine.lock(categoryName: category, scope: scope, language: language, uid: uid, reply: reply)
    }

    func confirm(
        _ key: String, action: String, place: String, requester: String, language: String, authorization: Data,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        engine.confirm(
            key: key, action: action, place: place, requester: requester, language: language, authorization: authorization, uid: uid, clientPid: pid,
            reply: reply
        )
    }

    func networkFlows(since: UInt64, reply: @escaping @Sendable (Data, UInt64, String?) -> Void) {
        engine.networkFlows(since: since, uid: uid, reply: reply)
    }
}
