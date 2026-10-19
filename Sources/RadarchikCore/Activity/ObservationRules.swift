import Foundation

/// Что не наблюдаем. Список правится в настройках, это значения по умолчанию.
public enum ObservationRules {
    /// Приложения, из которых не пишем ничего, даже время: менеджеры паролей, Связка ключей.
    public static let defaultExcludedApps: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
    ]

    /// Сайты, где пишется только время в браузере, без адреса и заголовка: банки, госуслуги, сейфы паролей.
    public static let defaultExcludedDomains: Set<String> = [
        "sberbank.ru", "sber.ru", "tbank.ru", "tinkoff.ru", "alfabank.ru", "vtb.ru",
        "gazprombank.ru", "raiffeisen.ru", "psbank.ru", "sovcombank.ru", "rshb.ru",
        "gosuslugi.ru", "nalog.gov.ru", "1password.com", "bitwarden.com",
    ]

    /// Имена приложений из списка по умолчанию — чтобы в исключениях не висели
    /// bundle id тех, что не установлены.
    static var knownNames: [String: String] {
        [
            "com.1password.1password": "1Password",
            "com.agilebits.onepassword7": "1Password 7",
            "com.bitwarden.desktop": "Bitwarden",
            "com.apple.keychainaccess": L("Связка ключей", "Keychain Access"),
            "com.apple.Passwords": L("Пароли", "Passwords"),
            "org.keepassxc.keepassxc": "KeePassXC",
            "com.lastpass.LastPass": "LastPass",
        ]
    }

    public static func knownName(of bundleId: String) -> String? { knownNames[bundleId] }

    /// Домен из списка или его поддомен: `online.sberbank.ru` попадает под `sberbank.ru`.
    public static func isExcluded(host: String, domains: Set<String>) -> Bool {
        let host = host.lowercased()
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

public enum BrowserKind: Sendable, Equatable {
    /// Chrome, Arc, Brave, Edge, Яндекс: адрес через `active tab`, есть режим инкогнито.
    case chromium
    /// Safari: адрес через `current tab`. Приватное окно через AppleScript не отличить.
    case safari
    /// Firefox: AppleScript не отдаёт адрес — только заголовок окна.
    case firefox
}

public enum Browsers {
    static let known: [String: BrowserKind] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "ru.yandex.desktop.yandex-browser": .chromium,
        "com.operasoftware.Opera": .chromium,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "org.mozilla.firefox": .firefox,
    ]

    public static func kind(of bundleId: String) -> BrowserKind? { known[bundleId] }

    /// Все известные браузеры — для экрана разрешений.
    public static let bundleIds: [String] = known.keys.sorted()

    /// Браузер, которому принадлежит процесс. Микрофон и звук часто держит
    /// вспомогательный процесс, например `com.google.Chrome.helper`.
    public static func owningBrowser(of bundleId: String) -> String? {
        known.keys
            .filter { bundleId == $0 || bundleId.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }
}

/// Как назвать звонок: по приложению, которое держит микрофон, а для
/// браузера — по сайту созвона (meet.google.com, telemost.yandex.ru).
public enum CallService {
    static let known: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram",
        "com.skype.skype": "Skype",
    ]

    public static func name(holderBundleId: String?, holderName: String?, browserHost: String?) -> String? {
        if let id = holderBundleId {
            if Browsers.owningBrowser(of: id) != nil { return browserHost ?? L("Браузер", "Browser") }
            if let name = known[id] { return name }
            if let match = known.first(where: { id.hasPrefix($0.key + ".") }) { return match.value }
        }
        return holderName ?? browserHost
    }
}

/// Куда ушла вставка. Без слежки за клавиатурой точно не узнать, поэтому
/// это оценка: скопировал в A и в течение минуты перешёл в B.
public enum PasteHeuristic {
    public static let window: TimeInterval = 60

    public static func target(copiedIn source: String?, copiedAt: Date, activated: String, at moment: Date) -> String? {
        guard activated != source, moment >= copiedAt, moment.timeIntervalSince(copiedAt) <= window else { return nil }
        return activated
    }
}
