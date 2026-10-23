import Foundation
import Security
import RadarchikCore

/// Ключ Claude API хранится только в Связке ключей (SPEC §5), не в файлах
/// и не в UserDefaults. Доступ к записи есть только у приложения с той же подписью.
///
/// Прочитанный ключ живёт в памяти до выхода (2026-10-24): Связка спрашивает пароль
/// на каждое чтение, пока приложению не сказали «Разрешать всегда», а у самоподписанной
/// сборки это разрешение не переживает пересборку — и «Что это?» спрашивало пароль
/// каждый раз. Теперь — не больше одного раза за запуск.
@MainActor
enum KeychainStore {
    private static let service = "dev.kuzmenko.radarchik"
    private static var cache: [String: String] = [:]

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? L("ошибка Связки ключей \(status)", "Keychain error \(status)")
        }
    }

    static func read(_ account: String) -> String? {
        if let value = cache[account] { return value }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        cache[account] = value
        return value
    }

    /// Есть ли запись — без самого ключа: атрибуты Связка отдаёт, не спрашивая пароль.
    static func exists(_ account: String) -> Bool {
        if cache[account] != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            cache[account] = value
            return
        }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var item = base
        item[kSecValueData as String] = data
        // Доступен, только пока мак разблокирован: заблокирован — разбор подождёт.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = L("Радарчик — ключ Claude API", "Radarchik — Claude API key")
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
        cache[account] = value
    }

    static func delete(_ account: String) {
        cache[account] = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
