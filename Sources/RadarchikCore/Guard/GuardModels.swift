import Foundation

// «Защита» (SPEC §3б) — то, что раньше делал bash-guard (`~/work/guard`), теперь
// внутри Радарчика.
//
// Этап 1 работает без root. Радарчик:
// - видит, какие ключи закрыты и какие открыты, и сколько осталось до автозакрытия;
// - следит за процессами;
// - проверяет код после git pull;
// - проверяет настройки Claude Code.
//
// Открывать и закрывать ключи будет маленькая root-часть Радарчика (этап 2).
// Пока это делает старый `sudo guard unlock` в терминале.

/// Насколько серьёзно: просто запись в журнал, «стоит глянуть» или тревога.
public enum GuardLevel: String, Sendable, CaseIterable, Comparable {
    case info
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Что защищаем — категории как в guard. Порядок здесь — порядок на экране.
public enum GuardCategory: String, CaseIterable, Sendable {
    case ssh
    case env
    case aws
    case kube
    case gpg
    case keychain
    case browser
    case wallets
    case custom

    /// Как называется на экране «Защита».
    public var title: String {
        switch self {
        case .ssh: L("SSH-ключи", "SSH keys")
        // У guard это `.env` и ключи Rails (master.key, credentials/*.key).
        case .env: L("Ключи проектов", "Project keys")
        case .aws: "AWS"
        case .kube: "Kubernetes"
        case .gpg: "GPG"
        case .keychain: L("Связка ключей", "Keychain")
        case .browser: L("Данные браузеров", "Browser data")
        case .wallets: L("Криптокошельки", "Crypto wallets")
        case .custom: L("Другое", "Other")
        }
    }

    /// Коротко, как в командах guard, — для крыла чёлки: «ssh 4:12».
    public var shortName: String { rawValue }

    /// В середине фразы: «Радарчик откроет ключи проектов на 5 минут».
    public var inSentence: String {
        switch self {
        case .ssh: L("SSH-ключи", "SSH keys")
        case .env: L("ключи проектов", "project keys")
        case .aws: L("ключи AWS", "AWS keys")
        case .kube: L("доступ к Kubernetes", "Kubernetes access")
        case .gpg: L("ключи GPG", "GPG keys")
        case .keychain: L("связку ключей", "the keychain")
        case .browser: L("данные браузеров", "browser data")
        case .wallets: L("криптокошельки", "crypto wallets")
        case .custom: L("остальные файлы", "other files")
        }
    }

    /// Значок SF Symbols.
    public var icon: String {
        switch self {
        case .ssh: "key.fill"
        case .env: "lock.doc.fill"
        case .aws: "cloud.fill"
        case .kube: "shippingbox.fill"
        case .gpg: "signature"
        case .keychain: "lock.fill"
        case .browser: "globe"
        case .wallets: "bitcoinsign.circle.fill"
        case .custom: "doc.fill"
        }
    }
}

/// Закрыт ли файл. guard «закрывает», отдавая файл root (chown root, chmod 600):
/// тогда никакая программа под тобой его не прочитает.
public enum LockState: Sendable, Hashable {
    /// Владелец root — закрыт.
    case locked
    /// Владелец ты — открыт.
    case open
    /// Владелец кто-то третий — так не бывает, стоит глянуть.
    case foreign
}

/// Защищаемый файл и его состояние сейчас.
public struct ProtectedFile: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let category: GuardCategory
    public let state: LockState
    /// Файл лежит в git: он и так есть в истории, закрывать его бессмысленно.
    /// Хуже того, после такого закрытия git видит файл изменённым — так было
    /// с `config/credentials/test.key` в storefront.
    public let inGit: Bool

    public init(path: String, category: GuardCategory, state: LockState, inGit: Bool = false) {
        self.path = path
        self.category = category
        self.state = state
        self.inGit = inGit
    }
}

/// Как открыли через guard: на 5 минут, до конца SSH-сессий или до ручной блокировки.
public enum UnlockMode: String, Sendable {
    case timer
    case session
    case manual
}

/// Открытие по журналу guard: когда открыли и когда закроется само.
public struct UnlockWindow: Equatable, Sendable {
    public let openedAt: Date
    public let mode: UnlockMode
    /// nil — до ручной блокировки или до конца SSH-сессий.
    public let closesAt: Date?

    public init(openedAt: Date, mode: UnlockMode, closesAt: Date?) {
        self.openedAt = openedAt
        self.mode = mode
        self.closesAt = closesAt
    }
}

/// Категория на экране «Защита»: её файлы и открытие, если оно сейчас идёт.
public struct CategoryStatus: Identifiable, Sendable, Equatable {
    public var id: GuardCategory { category }
    public let category: GuardCategory
    public let files: [ProtectedFile]
    /// Последнее открытие через guard без закрытия после него.
    public let window: UnlockWindow?

    public init(category: GuardCategory, files: [ProtectedFile], window: UnlockWindow?) {
        self.category = category
        self.files = files
        self.window = window
    }

    /// Файлы, которые имеет смысл закрывать: без лежащих в git.
    public var guarded: [ProtectedFile] { files.filter { !$0.inGit } }
    public var openFiles: [ProtectedFile] { guarded.filter { $0.state != .locked } }
    public var isOpen: Bool { !openFiles.isEmpty }
}

/// Крыло свёрнутой чёлки, пока что-то открыто через guard: «ssh 4:12».
public struct GuardWing: Equatable, Sendable {
    public let categories: [GuardCategory]
    /// Сколько осталось до автозакрытия; nil — таймера нет или он уже прошёл.
    public let remaining: TimeInterval?
    /// Таймер прошёл, а ключи открыты: перезагрузка посреди разблокировки
    /// или фоновая задача guard не сработала.
    public let isOverdue: Bool

    public init(categories: [GuardCategory], remaining: TimeInterval?, isOverdue: Bool) {
        self.categories = categories
        self.remaining = remaining
        self.isOverdue = isOverdue
    }

    /// «ssh 4:12», «ssh+env 1:00» или просто «ssh», если таймера нет.
    public var text: String {
        let names = categories.map(\.shortName).joined(separator: "+")
        guard let remaining else { return names }
        return names + " " + Self.clock(remaining)
    }

    /// Обратный отсчёт: «4:12».
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
