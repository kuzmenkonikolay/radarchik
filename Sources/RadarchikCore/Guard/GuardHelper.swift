import Darwin
import Foundation

/// Root-часть «Защиты» (SPEC §3б, этап 2): имена, пути и договор с Радарчиком.
///
/// Root-часть — отдельный процесс от root (launchd), но часть Радарчика: та же
/// сборка, вторая цель в `Package.swift`. Умеет открыть или закрыть ключи из
/// списка и подтвердить Touch ID просьбу к ssh-agent. Открыть и подтвердить —
/// только после Touch ID или пароля: окно вызывает и проверяет она сама, и текст
/// в нём пишет тоже она. Закрыть можно без пальца — это только прибавляет защиты.
///
/// Всё её лежит там, куда пишет только root: бинарник — в `/Library/PrivilegedHelperTools`,
/// plist — в `/Library/LaunchDaemons`, список, журнал и таймеры — в `/var/db/…`.
/// `/Library/Application Support` не годится: туда пишет группа admin, а значит,
/// и любая программа под тобой.
public enum GuardHelper {
    /// Имя у launchd и служба XPC.
    public static let label = "dev.kuzmenko.radarchik.guardd"
    public static let machService = label
    /// Право в базе авторизации macOS: «открыть ключи» — Touch ID или пароль каждый раз.
    public static let unlockRight = "dev.kuzmenko.radarchik.guard.unlock"
    /// Версия договора: Радарчик попросит переставить root-часть, если она старше.
    /// 2 — в окне Touch ID написано, кто просит (2026-10-20).
    /// 3 — `confirm`: Touch ID для просьбы к ssh-agent от чужого источника (2026-10-21).
    /// 4 — `networkFlows`: «Сетевой надзор», соединения с pktap (2026-10-22).
    public static let version = 4
    /// От какой версии root-часть умеет открывать и закрывать: старее ждёт переустановки,
    /// а от `unlockVersion` до текущей Радарчик ею пользуется, только без нового.
    public static let unlockVersion = 2

    public static let binaryPath = "/Library/PrivilegedHelperTools/\(label)"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    public static let dataFolder = "/var/db/dev.kuzmenko.radarchik.guard"
    /// Что защищаем (`CATEGORY|PATH`, `exclude|PATH`). Читать может кто угодно — секретов там нет.
    public static let configPath = dataFolder + "/config"
    /// Журнал в формате guard: его читает тот же разбор (`LegacyGuardLog`).
    public static let journalPath = dataFolder + "/journal.log"
    /// Таймеры открытого — только для root.
    public static let statePath = dataFolder + "/state.json"
    /// Требование к подписи клиента. Это вторая линия: решает Touch ID.
    public static let requirementPath = dataFolder + "/client.requirement"

    /// По умолчанию открываем на 5 минут, как guard; не дольше 4 часов.
    public static let defaultMinutes = 5
    public static let maxMinutes = 240

    /// Стоит ли root-часть.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath) && FileManager.default.fileExists(atPath: configPath)
    }

    /// «ssh» → [.ssh], «all» → все; что-то другое — nil (запрос отклоняется).
    public static func categories(_ name: String) -> [GuardCategory]? {
        if name == "all" { return GuardCategory.allCases }
        return GuardCategory(rawValue: name).map { [$0] }
    }

    /// 0 — до ручной блокировки (nil); остальное — в пределах 1…`maxMinutes`.
    public static func minutes(_ value: Int) -> Int? {
        value == 0 ? nil : min(max(value, 1), maxMinutes)
    }

    /// Под команду терминала открываем с запасом: закроет сам Радарчик, когда команда
    /// кончится, а если терминал закрыли посреди — root-часть по этому таймеру.
    public static let commandMinutes = 10

    /// Подпись команды, которая попадёт в окно Touch ID: «git push». Только латиница,
    /// цифры, пробел и `._:-`, не длиннее 32 — подделанный клиент не впишет туда
    /// «это безопасно, жми».
    public static func isSafeCommandLabel(_ label: String) -> Bool {
        guard (1...32).contains(label.count), let first = label.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first)
        else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 ._:-")
        return label.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - Кто просит (2026-10-20)

    /// Радарчик из чёлки просит по кнопке.
    public static let notchButton = "@notch"

    /// Кто просит открыть — строка «Просит: …» в окне Touch ID. Окно может вызвать
    /// любая программа, и без этой строки не понять, твоя ли это команда.
    /// - Радарчик из чёлки (запустила система — родитель launchd, без флагов `--…`)
    ///   сам знает, кто его попросил: кнопка или тот, кто постучал в сокет терминала
    ///   (pid от ядра). Его словам верим.
    /// - Любой другой клиент — `Radarchik --guard` из терминала или подделка с той же
    ///   подписью — назваться не может: его цепочку root-часть читает у ядра сама.
    public static func requester(supplied: String, clientArguments: [String], clientParent: Int32, parentChain: String) -> String {
        let unknown = L("неизвестно кто", "unknown")
        guard let program = clientArguments.first.map({ ($0 as NSString).lastPathComponent }) else { return unknown }
        let flag = clientArguments.dropFirst().first { $0.hasPrefix("--") }
        if clientParent == 1 && flag == nil {
            if supplied == notchButton { return L("кнопка в чёлке", "the notch button") }
            return safeRequester(supplied) ?? unknown
        }
        let client = [program, flag].compactMap { $0 }.joined(separator: " ")
        return safeRequester(parentChain.isEmpty ? client : client + " ← " + parentChain) ?? unknown
    }

    // MARK: - Просьба к ssh-agent (2026-10-21)

    /// Что просят подписать — для текста окна. Строкой по XPC; незнакомое — `sign`.
    public enum SignAction: String, Sendable {
        /// `ssh-keygen -Y sign -n git`: подпись коммита или тега.
        case commit
        /// Вход на сервер (git push, ssh).
        case login
        case sign
    }

    /// Имя ключа для окна: имя файла, как у `id_ed25519`. Только латиница, цифры и `._-`,
    /// не длиннее 40; иначе nil — в окне будет просто «SSH-ключ».
    public static func safeKeyName(_ name: String) -> String? {
        guard (1...40).contains(name.count), let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy(allowed.contains) ? name : nil
    }

    /// Текст «кто просит» для окна: только буквы, цифры, пробел и `._-←()@:/+`,
    /// не длиннее 60. Ни кавычек, ни переводов строки — подделать фразу окна нечем.
    public static func safeRequester(_ text: String) -> String? {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "._-←()@:/+"))
        var cleaned = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                cleaned.append(" ")
            } else if allowed.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        var result = cleaned.split(separator: " ").joined(separator: " ")
        guard !result.isEmpty else { return nil }
        if result.count > 60 { result = String(result.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" }
        return result
    }
}

/// Договор Радарчика с root-частью по XPC:
/// - `category` — «ssh», «env»… или «all»;
/// - `scope` — папка проекта: открыть или закрыть только ключи внутри неё; пусто — всю категорию;
/// - `minutes` — 0 значит до ручной блокировки;
/// - `command` — подпись команды терминала для окна Touch ID («git push»); пусто — открыть по кнопке;
/// - `requester` — кто просит, словами Радарчика: `notchButton` или цепочка «zsh ← Terminal».
///   Root-часть верит ему, только если клиент — Радарчик из чёлки (`GuardHelper.requester`);
/// - `language` — на каком языке писать окно;
/// - `authorization` — пустая авторизация клиента (AuthorizationExternalForm): по ней
///   root-часть сама покажет окно в твоей сессии.
///
/// `confirm` (договор 3) — Touch ID для просьбы к ssh-agent от чужого источника
/// (`AgentGate`): файлы не трогает, только окно. `key` — имя ключа (`safeKeyName`),
/// `action` — `SignAction`, `place` — репозиторий или адрес (`safeRequester`),
/// `requester` — как у `unlock`. Отменил или не подтвердил — `false`.
@objc(RadarchikGuardHelperProtocol)
public protocol GuardHelperProtocol {
    func version(reply: @escaping @Sendable (Int) -> Void)
    func unlock(
        _ category: String, scope: String, minutes: Int, command: String, requester: String, language: String, authorization: Data,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )
    func lock(_ category: String, scope: String, language: String, reply: @escaping @Sendable (Bool, String?) -> Void)
    func confirm(
        _ key: String, action: String, place: String, requester: String, language: String, authorization: Data,
        reply: @escaping @Sendable (Bool, String?) -> Void
    )
    /// «Сетевой надзор» (договор 4): новые исходящие соединения после номера `since` —
    /// JSON `[NetworkFlow]` и номер, с которого спрашивать в следующий раз. Первый вызов
    /// включает захват с pktap, без вызовов две минуты — выключает. Третье — ошибка захвата.
    func networkFlows(since: UInt64, reply: @escaping @Sendable (Data, UInt64, String?) -> Void)
}

/// Список root-части: правила, как у guard, и исключения — файлы, которые
/// не трогаем (лежат в git: их закрытие ничего не защищает, а git видит их изменёнными).
public struct GuardConfig: Equatable, Sendable {
    public var rules: [GuardRule]
    public var excluded: Set<String>

    public init(rules: [GuardRule], excluded: Set<String>) {
        self.rules = rules
        self.excluded = excluded
    }

    public static func parse(_ text: String) -> GuardConfig {
        var excluded = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("exclude|") else { continue }
            let path = line.dropFirst("exclude|".count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { excluded.insert(path) }
        }
        return GuardConfig(rules: GuardRules.parse(text), excluded: excluded)
    }

    public func render() -> String {
        var lines = [
            "# Радарчик, «Защита» (SPEC §3б): что закрывает root-часть.",
            "# CATEGORY|PATH — что защищаем (~ — домашняя папка, * — любые символы).",
            "# exclude|PATH — не трогать: файл лежит в git.",
        ]
        lines += rules.map { "\($0.category.rawValue)|\($0.pattern)" }
        lines += excluded.sorted().map { "exclude|\($0)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Смена владельца файла так, чтобы ни ссылка, ни жёсткая ссылка не увели
/// root-часть на чужой файл. Ровно здесь старый guard давал путь к root:
/// `chown` по пути идёт по ссылкам, и подложенная `~/.ssh/id_x → /etc/…`
/// отдавала системный файл тебе.
///
/// Как сделано:
/// - путь обязан быть внутри домашней папки, без «..»;
/// - идём от домашней папки по одной папке за раз (`openat` с `O_NOFOLLOW`):
///   ссылка где угодно по дороге — отказ;
/// - сам файл открываем тоже без перехода по ссылке и дальше работаем только
///   с открытым дескриптором (`fstat`, `fchown`, `fchmod`): подменить файл
///   между проверкой и сменой нельзя;
/// - только обычный файл с одной жёсткой ссылкой (`st_nlink == 1`) и с владельцем
///   из разрешённых (root или ты).
public enum SafeOwnership {
    public enum Failure: Error, Equatable, Sendable {
        case outsideHome
        case symlink
        case notRegularFile
        case hardLinked
        case foreignOwner(uid_t)
        case missing
        case system(Int32)
    }

    /// nil — получилось.
    public static func set(_ path: String, home: String, owner: uid_t, group: gid_t, mode: mode_t, allowedOwners: Set<uid_t>) -> Failure? {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return .outsideHome }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(".."), !parts.contains(".") else { return .outsideHome }

        // Саму домашнюю папку открываем как есть: она точка отсчёта.
        var folder = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { return .system(errno) }
        for component in parts.dropLast() {
            let next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let failure = classify(folder, component, errno)
                close(folder)
                return failure
            }
            close(folder)
            folder = next
        }
        // O_NONBLOCK — чтобы FIFO под видом ключа не подвесил root-часть.
        let file = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            let failure = classify(folder, name, errno)
            close(folder)
            return failure
        }
        close(folder)
        defer { close(file) }

        var info = stat()
        guard fstat(file, &info) == 0 else { return .system(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegularFile }
        guard info.st_nlink == 1 else { return .hardLinked }
        guard allowedOwners.contains(info.st_uid) else { return .foreignOwner(info.st_uid) }
        guard fchown(file, owner, group) == 0, fchmod(file, mode) == 0 else { return .system(errno) }
        return nil
    }

    /// Почему не открылось: ссылка, нет такого или что-то не то.
    private static func classify(_ folder: Int32, _ name: String, _ error: Int32) -> Failure {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .system(error)
        }
        if info.st_mode & S_IFMT == S_IFLNK { return .symlink }
        return error == ENOTDIR ? .notRegularFile : .system(error)
    }
}

/// Что открыто и до когда — у root-части. Переживает её перезапуск (`state.json`).
public struct GuardHelperState: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public let category: GuardCategory
        /// Чьи ключи: по нему root-часть найдёт домашнюю папку, когда таймер выйдет.
        public let uid: uid_t
        public let openedAt: Date
        /// nil — до ручной блокировки.
        public var closesAt: Date?
    }

    public private(set) var windows: [GuardCategory: Window] = [:]

    public init() {}

    /// Открыть на `minutes` (nil — до ручной блокировки). Уже открытое продлевается
    /// от текущего момента, а «открыто с» остаётся прежним.
    public mutating func open(_ categories: [GuardCategory], minutes: Int?, uid: uid_t, now: Date) {
        for category in categories {
            let openedAt = windows[category]?.openedAt ?? now
            windows[category] = Window(category: category, uid: uid, openedAt: openedAt, closesAt: minutes.map { now.addingTimeInterval(Double($0) * 60) })
        }
    }

    public mutating func close(_ categories: [GuardCategory]) {
        for category in categories { windows[category] = nil }
    }

    /// Таймер вышел — пора закрыть.
    public func due(now: Date) -> [Window] {
        windows.values.filter { ($0.closesAt ?? .distantFuture) <= now }.sorted { $0.category.order < $1.category.order }
    }

    /// Ближайшее автозакрытие — на него ставится таймер.
    public var nextDeadline: Date? {
        windows.values.compactMap(\.closesAt).min()
    }

    /// При запуске root-части: что закрыть сразу. Просроченное — всегда.
    /// Если мак перезагружался после открытия — всё: перезагрузка закрывает
    /// и открытое «до ручной блокировки».
    public func toLockAtStart(now: Date, bootTime: Date) -> [Window] {
        windows.values.filter { $0.openedAt < bootTime || ($0.closesAt ?? .distantFuture) <= now }.sorted { $0.category.order < $1.category.order }
    }

    // Словарь с ключом-перечислением JSONEncoder пишет массивом пар — пишем
    // списком окон, так файл читается глазами.
    private enum CodingKeys: String, CodingKey { case windows }

    public init(from decoder: Decoder) throws {
        let list = try decoder.container(keyedBy: CodingKeys.self).decode([Window].self, forKey: .windows)
        windows = Dictionary(list.map { ($0.category, $0) }, uniquingKeysWith: { $1 })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows.values.sorted { $0.category.order < $1.category.order }, forKey: .windows)
    }
}

extension GuardCategory: Codable {
    /// Порядок на экране и в журнале.
    var order: Int { GuardCategory.allCases.firstIndex(of: self) ?? 0 }
}

/// Строки журнала root-части — в формате guard (`LegacyGuardLog` читает их без изменений):
///
///     2026-10-20 12:00:00 [ALLOW] unlock ssh for me (mode: timer, timeout: 300s)
///     2026-10-20 12:05:00 [AUTO] auto-lock ssh after timeout
public enum GuardJournal {
    public enum Reason: String, Sendable {
        case timeout
        case restart
    }

    /// `scope` — папка проекта, если открывали или закрывали только её ключи.
    public enum Action: Sendable {
        case unlock([String], user: String, minutes: Int?, scope: String? = nil)
        case lock([String], scope: String? = nil)
        case autoLock([String], reason: Reason)
        case deny([String], minutes: Int?)
    }

    /// Несколько категорий — по строке на каждую: так разбор знает про каждую.
    public static func line(_ action: Action, at date: Date, timeZone: TimeZone = .current) -> String {
        lines(action, at: date, timeZone: timeZone).joined(separator: "\n")
    }

    public static func lines(_ action: Action, at date: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let time = formatter.string(from: date)
        func mode(_ minutes: Int?) -> String {
            minutes.map { "mode: timer, timeout: \($0 * 60)s" } ?? "mode: manual"
        }
        func place(_ scope: String?) -> String { scope.map { " in \($0)" } ?? "" }
        switch action {
        case .unlock(let names, let user, let minutes, let scope):
            return names.map { "\(time) [ALLOW] unlock \($0) for \(user)\(place(scope)) (\(mode(minutes)))" }
        case .lock(let names, let scope):
            return names.map { "\(time) [LOCK] locked \($0)\(place(scope))" }
        case .autoLock(let names, let reason):
            return names.map { "\(time) [AUTO] auto-lock \($0) after \(reason.rawValue)" }
        case .deny(let names, let minutes):
            return names.map { "\(time) [DENY] unlock \($0) denied by user (\(mode(minutes)))" }
        }
    }
}
