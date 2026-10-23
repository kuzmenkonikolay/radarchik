import Foundation
import RadarchikCore
import Security

/// Touch ID или пароль — через базу авторизации macOS.
///
/// Радарчик присылает пустую авторизацию своего процесса (AuthorizationExternalForm).
/// Root-часть сама просит по ней право `dev.kuzmenko.radarchik.guard.unlock`,
/// разрешив показать окно: macOS покажет его в твоей сессии, с Touch ID.
/// Текст окна пишет root-часть — клиент не может подменить, что именно открывается.
/// Право записано установщиком: «пользователь из admin, каждый раз заново» (timeout 0).
enum Authorizer {
    static func authorize(externalForm data: Data, right: String, prompt: String) -> OSStatus {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else { return errAuthorizationInvalidRef }
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { data.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        let created = AuthorizationCreateFromExternalForm(&external, &reference)
        guard created == errAuthorizationSuccess, let reference else { return created }
        defer { AuthorizationFree(reference, []) }

        return right.withCString { rightName in
            "prompt".withCString { promptKey in
                prompt.withCString { promptValue in
                    var rightItem = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptKey, valueLength: strlen(promptValue), value: UnsafeMutableRawPointer(mutating: promptValue), flags: 0
                    )
                    return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(reference, &rights, &environment, [.interactionAllowed, .extendRights], nil)
                        }
                    }
                }
            }
        }
    }

    /// Что сказать Радарчику; nil — ты сам отменил окно, говорить не о чем.
    static func message(_ status: OSStatus) -> String? {
        switch status {
        case errAuthorizationCanceled: nil
        case errAuthorizationDenied: L("Не подтверждено", "Not confirmed")
        case errAuthorizationInteractionNotAllowed: L("Не смог показать окно подтверждения", "Couldn’t show the confirmation window")
        default: L("Авторизация не прошла (\(status))", "Authorization failed (\(status))")
        }
    }
}
