import Darwin
import Foundation

/// Что защищаем: категория и путь с `~` и звёздочками — «~/.ssh/id_*».
public struct GuardRule: Hashable, Sendable {
    public let category: GuardCategory
    public let pattern: String

    public init(_ category: GuardCategory, _ pattern: String) {
        self.category = category
        self.pattern = pattern
    }
}

/// Список того, что защищаем. На этапе 1 его берём у старого guard
/// (файл `config`, формат `CATEGORY|PATH`): Радарчик показывает ровно то,
/// что guard закрывает. Нет guard — встроенный список.
public enum GuardRules {
    /// Разбор конфига guard: пустые строки и `#` пропускаем, неизвестная
    /// категория уходит в «Другое», строка без пути — мимо. `exclude|…` —
    /// не правило, а исключение списка root-части (`GuardConfig`).
    public static func parse(_ text: String) -> [GuardRule] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let bar = line.firstIndex(of: "|") else { return nil }
            let name = line[..<bar].trimmingCharacters(in: .whitespaces).lowercased()
            let pattern = line[line.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, name != "exclude" else { return nil }
            return GuardRule(GuardCategory(rawValue: name) ?? .custom, pattern)
        }
    }

    /// Встроенный список для тех, у кого guard не было: то, что крадут первым.
    /// Ключи проектов (`config/master.key`) здесь не угадать — у каждого своя папка.
    public static let defaults: [GuardRule] = [
        GuardRule(.ssh, "~/.ssh/id_*"),
        GuardRule(.ssh, "~/.ssh/config"),
        GuardRule(.env, "~/.env"),
        GuardRule(.env, "~/.env.*"),
        GuardRule(.aws, "~/.aws/credentials"),
        GuardRule(.aws, "~/.aws/config"),
        GuardRule(.kube, "~/.kube/config"),
        GuardRule(.gpg, "~/.gnupg/private-keys-v1.d/*"),
    ]

    /// `~` в начале → домашняя папка. В середине пути `~` — просто символ.
    public static func expandHome(_ pattern: String, home: String) -> String {
        if pattern == "~" { return home }
        if pattern.hasPrefix("~/") { return home + pattern.dropFirst() }
        return pattern
    }

    /// Публичные ключи — не секрет: guard закрывал их заодно (`id_*`), Радарчик их не считает.
    public static func isPublicKey(_ path: String) -> Bool {
        path.hasSuffix(".pub")
    }
}

/// Кто владеет защищаемыми файлами — отсюда «закрыт» или «открыт».
/// Только чтение (`lstat`): для этого root не нужен.
public enum LockProbe {
    /// Файлы по правилу. Звёздочки раскрывает glob(3), папка — это все файлы
    /// внутри неё. Ссылки пропускаем: guard прошёл бы по ним и отдал бы
    /// тебе чужой файл, а Радарчик не должен их даже считать своими.
    public static func files(matching pattern: String, limit: Int = 200) -> [String] {
        var result: [String] = []
        for path in glob(pattern) {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: result.append(path)
            case S_IFDIR: result += regularFiles(in: path, limit: limit - result.count)
            default: continue
            }
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    /// Владелец обычного файла; nil — файла нет, или это ссылка, или папка.
    public static func owner(of path: String) -> uid_t? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return info.st_uid
    }

    /// root — закрыт, ты — открыт, кто-то третий — чужой.
    public static func state(ownerUID: uid_t, userUID: uid_t) -> LockState {
        if ownerUID == 0 { return .locked }
        return ownerUID == userUID ? .open : .foreign
    }

    private static func glob(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        // Без GLOB_NOSORT: порядок файлов на экране должен быть стабильным.
        guard Darwin.glob(pattern, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_matchc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }
    }

    private static func regularFiles(in folder: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys) else { return [] }
        var files: [String] = []
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            files.append(item.path)
            if files.count >= limit { break }
        }
        return files.sorted()
    }
}
