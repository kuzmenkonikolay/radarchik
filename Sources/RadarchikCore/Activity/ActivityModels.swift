import Foundation

// Модели наблюдения (этап 3). Сюда попадает только то, что уже очищено:
// заголовки без спиннеров и счётчиков, адреса без query и id, команды без секретов.

/// Что сейчас на экране. Трекер собирает такой снимок раз в 2 секунды и при
/// переключении приложений.
public struct FocusSnapshot: Hashable, Sendable {
    public var bundleId: String
    public var appName: String
    public var windowTitle: String?
    /// Нормализованный адрес вкладки (`URLNormalizer`), только для браузеров.
    public var url: String?
    /// Приватное окно или сайт из исключений: заголовка и адреса нет, есть только время.
    public var isPrivate: Bool

    public init(bundleId: String, appName: String, windowTitle: String? = nil, url: String? = nil, isPrivate: Bool = false) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.isPrivate = isPrivate
    }
}

/// Отрезок времени в одном приложении, окне или на одной странице.
public struct ActivitySession: Hashable, Sendable {
    /// rowid в базе; nil — пока только в памяти.
    public var id: Int64?
    public var bundleId: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var isPrivate: Bool
    public var startedAt: Date
    public var endedAt: Date

    public init(
        id: Int64? = nil, bundleId: String, appName: String, windowTitle: String? = nil,
        url: String? = nil, isPrivate: Bool = false, startedAt: Date, endedAt: Date
    ) {
        self.id = id
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.isPrivate = isPrivate
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    init(snapshot: FocusSnapshot, at moment: Date) {
        self.init(
            bundleId: snapshot.bundleId, appName: snapshot.appName, windowTitle: snapshot.windowTitle,
            url: snapshot.url, isPrivate: snapshot.isPrivate, startedAt: moment, endedAt: moment
        )
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Та же ли это «точка внимания»: приложение, окно и страница.
    func matches(_ snapshot: FocusSnapshot) -> Bool {
        bundleId == snapshot.bundleId && windowTitle == snapshot.windowTitle
            && url == snapshot.url && isPrivate == snapshot.isPrivate
    }
}

/// Запуск и закрытие приложений. Нужны для советов вроде «каждое утро
/// руками открываешь одни и те же 6 приложений».
public struct AppLifecycleEvent: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case launched
        case terminated
        /// Уже было запущено, когда стартовал Радарчик.
        case running
    }

    public var id: Int64?
    public var bundleId: String
    public var appName: String
    public var kind: Kind
    public var at: Date

    public init(id: Int64? = nil, bundleId: String, appName: String, kind: Kind, at: Date) {
        self.id = id
        self.bundleId = bundleId
        self.appName = appName
        self.kind = kind
        self.at = at
    }
}

/// Факт копирования, без содержимого буфера. `toBundleId` — оценка: в какое
/// приложение перешёл в течение минуты (`PasteHeuristic`).
public struct PasteEvent: Hashable, Sendable {
    public var id: Int64?
    public var fromBundleId: String?
    public var toBundleId: String?
    public var at: Date

    public init(id: Int64? = nil, fromBundleId: String?, toBundleId: String?, at: Date) {
        self.id = id
        self.fromBundleId = fromBundleId
        self.toBundleId = toBundleId
        self.at = at
    }
}

/// Звонок: пока занят микрофон. Звук не пишется, доступ к микрофону не нужен.
public struct CallSession: Hashable, Sendable {
    public var id: Int64?
    public var bundleId: String?
    /// Zoom, Telegram, meet.google.com…
    public var service: String?
    public var usesCamera: Bool
    public var startedAt: Date
    /// nil — звонок ещё идёт.
    public var endedAt: Date?

    public init(id: Int64? = nil, bundleId: String?, service: String?, usesCamera: Bool, startedAt: Date, endedAt: Date?) {
        self.id = id
        self.bundleId = bundleId
        self.service = service
        self.usesCamera = usesCamera
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Команда терминала из zsh-хука, уже без секретов (`ShellRedactor`).
public struct ShellCommand: Hashable, Sendable {
    public var id: Int64?
    public var command: String
    /// Без значений и чисел: по нему ищутся повторы и он же уйдёт в LLM.
    public var template: String
    /// Папка, домашняя заменена на «~».
    public var cwd: String?
    public var startedAt: Date
    public var durationMs: Int64
    public var exitCode: Int32

    public init(
        id: Int64? = nil, command: String, template: String, cwd: String?,
        startedAt: Date, durationMs: Int64, exitCode: Int32
    ) {
        self.id = id
        self.command = command
        self.template = template
        self.cwd = cwd
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.exitCode = exitCode
    }
}
