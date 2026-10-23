import Foundation
import RadarchikCore
import UserNotifications

/// Системные уведомления о тревогах — по желанию (SPEC §3а), по умолчанию выключены.
/// Клик по уведомлению — чёлка ещё раз выдвигает записку, чтобы было видно, где искать.
@MainActor
final class ResourceNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func activate() {
        center.delegate = self
    }

    // Центр уведомлений — только через колбэки: в SDK macOS 15 (Xcode 16) ни он сам,
    // ни его настройки не `Sendable`, и `await center.…` с главного потока там не
    // собирается. Из колбэков уходит только Bool.

    /// Спросить разрешение (один раз macOS покажет запрос). false — запретили.
    func requestAuthorization() async -> Bool {
        let center = center
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Запрещено ли в Системных настройках — сказать об этом на экране настроек.
    func isDenied() async -> Bool {
        let center = center
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .denied)
            }
        }
    }

    func post(_ alert: ResourceAlert) {
        let content = UNMutableNotificationContent()
        content.title = L("Радарчик", "Radarchik")
        content.body = alert.speech
        let request = UNNotificationRequest(identifier: "resource-\(alert.id)", content: content, trigger: nil)
        center.add(request)
    }

    // Радарчик почти никогда не «активное» приложение, но на всякий случай
    // показываем баннер и тогда.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?() }
    }
}

extension ResourceAlert {
    /// Фраза целиком, с точками: «Батарея садится быстро — 28% в час. Больше всех ест Chrome.»
    var speech: String {
        [title, detail].compactMap { $0 }.map { $0 + "." }.joined(separator: " ")
    }
}
