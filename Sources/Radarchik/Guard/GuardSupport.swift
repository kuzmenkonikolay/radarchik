import Darwin
import Foundation
import RadarchikCore

/// Старый bash-guard (`~/work/guard`). Его список и журнал читаем, пока не
/// поставлена root-часть Радарчика (SPEC §3б). Его же список установщик root-части
/// переносит к себе.
enum LegacyGuard {
    static var folder: String { NSHomeDirectory() + "/work/guard" }
    static var configPath: String { folder + "/config" }
    static var logPath: String { folder + "/logs/access.log" }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: configPath) }
}

/// Откуда «Защита» берёт список и журнал:
/// - стоит root-часть — её файлы в `/var/db/…` (пишет туда только root);
/// - нет, но есть старый guard — его `config` и `logs/access.log`;
/// - ничего нет — встроенный список, а журнала нет.
enum GuardSource: Sendable, Equatable {
    case helper
    case legacyGuard
    case builtIn

    static var current: GuardSource {
        if GuardHelper.isInstalled { return .helper }
        return LegacyGuard.isInstalled ? .legacyGuard : .builtIn
    }

    private var configPath: String? {
        switch self {
        case .helper: GuardHelper.configPath
        case .legacyGuard: LegacyGuard.configPath
        case .builtIn: nil
        }
    }

    private var logPath: String? {
        switch self {
        case .helper: GuardHelper.journalPath
        case .legacyGuard: LegacyGuard.logPath
        case .builtIn: nil
        }
    }

    /// Список и исключения; файла нет или он пустой — встроенный список.
    func config() -> GuardConfig {
        guard let path = configPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return GuardConfig(rules: GuardRules.defaults, excluded: [])
        }
        let config = GuardConfig.parse(text)
        return config.rules.isEmpty ? GuardConfig(rules: GuardRules.defaults, excluded: config.excluded) : config
    }

    /// Хвост журнала: для таймера и счётчиков за день хватает последних 128 КБ
    /// (около 1500 строк — несколько дней), а весь журнал старого guard — больше полумегабайта.
    func logTail(maxBytes: UInt64 = 128 * 1_024) -> String? {
        guard let path = logPath, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        // Начали с середины строки — первую, обрезанную, выбрасываем.
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }

    /// Размер и время изменения журнала: перечитываем, только если он менялся.
    func logStamp() -> String? {
        var info = stat()
        guard let path = logPath, stat(path, &info) == 0 else { return nil }
        return "\(path)-\(info.st_size)-\(info.st_mtimespec.tv_sec)"
    }
}

/// Git из Радарчика: лежит ли файл в репозитории, куда смотрят хуки.
/// Запускается от твоего имени — как если бы ты сам набрал команду. Хуки и
/// fsmonitor репозитория выключаем на всякий случай: `ls-files` их и так не зовёт.
enum Git {
    static let executable = "/usr/bin/git"

    /// Корень репозитория, в котором лежит путь; nil — не в git.
    static func repositoryRoot(containing path: String) -> String? {
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > 1 {
            if FileManager.default.fileExists(atPath: folder + "/.git") { return folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Лежит ли файл в git (`ls-files --error-unmatch`).
    static func isTracked(_ path: String) -> Bool {
        guard let root = repositoryRoot(containing: path) else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        return run(["-C", root, "-c", "core.fsmonitor=false", "ls-files", "--error-unmatch", "--", relative])?.status == 0
    }

    /// Запустить git и дождаться; nil — git не запустился.
    static func run(_ arguments: [String], in folder: String? = nil) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Где запущена команда терминала (этап 3): папка проекта и адреса удалённых
/// репозиториев. Только чтение файлов (`.git/config`), git не запускаем:
/// это происходит перед каждой подходящей командой и должно быть мгновенным.
enum ShellContext {
    static func make(cwd: String) -> CommandContext {
        let config = Git.repositoryRoot(containing: cwd + "/.").flatMap(gitConfig)
        // Подпись коммитов: общий конфиг, потом репозитория — последнее главнее, как у git.
        let home = NSHomeDirectory()
        let global = [home + "/.gitconfig", home + "/.config/git/config"].compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let signing = GitSigning.read(global + (config.map { [$0] } ?? []))
        return CommandContext(cwd: cwd, projectRoot: projectRoot(cwd), signing: signing) { name in
            config.flatMap { GitConfigFile.remoteURL($0, name: name) }
        }
    }

    /// Ближайшая папка вверх, где есть ключи проекта: `config/credentials`,
    /// `config/master.key` или `.env`. Выше домашней папки не поднимаемся.
    static func projectRoot(_ cwd: String) -> String? {
        let home = NSHomeDirectory()
        var folder = cwd
        while folder.hasPrefix(home + "/") {
            for marker in ["config/credentials", "config/master.key", ".env"] where FileManager.default.fileExists(atPath: folder + "/" + marker) {
                return folder
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `.git/config`; у worktree и подмодулей `.git` — файл со ссылкой на настоящую папку.
    private static func gitConfig(_ root: String) -> String? {
        let dotGit = root + "/.git"
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { return try? String(contentsOfFile: dotGit + "/config", encoding: .utf8) }
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        var gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitDir.hasPrefix("/") { gitDir = root + "/" + gitDir }
        // Worktree: общий конфиг — в папке из commondir.
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            let commonDir = common.hasPrefix("/") ? common : gitDir + "/" + common
            return try? String(contentsOfFile: commonDir + "/config", encoding: .utf8)
        }
        return try? String(contentsOfFile: gitDir + "/config", encoding: .utf8)
    }
}

/// Сокет «строка — ответ» для zsh-хука: «нужны ли команде ключи» и «команда закончилась».
enum GuardShellSocket {
    static var path: String { ShellHook.folder.appendingPathComponent("guard-shell.sock").path }
}

/// Посредник перед ssh-agent (слежка за SSH-ключом) и метка для zsh-хука.
/// Хук ставит `SSH_AUTH_SOCK` на посредника, только если метка есть, агент в ней
/// тот же, что у терминала, и Радарчик из неё жив. Иначе терминал ходит в агент
/// напрямую: убитый Радарчик не должен оставить ssh без ключей.
enum AgentSocket {
    static var path: String { ShellHook.folder.appendingPathComponent("agent.sock").path }
    static var markerPath: String { ShellHook.folder.appendingPathComponent("agent.upstream").path }

    /// Настоящий агент — из окружения Радарчика: launchd даёт его всем программам
    /// сессии, и Терминалу тоже. Запустили Радарчик из терминала, который уже ходит
    /// через посредника, — берём агента, которого хук запомнил (`RADARCHIK_REAL_AUTH_SOCK`).
    static func upstream() -> String? {
        let environment = ProcessInfo.processInfo.environment
        for candidate in [environment["RADARCHIK_REAL_AUTH_SOCK"], environment["SSH_AUTH_SOCK"]] {
            guard let candidate, !candidate.isEmpty, candidate != path else { continue }
            var info = stat()
            if stat(candidate, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK { return candidate }
        }
        return nil
    }

    /// Две строки: сокет агента за посредником и pid Радарчика.
    static func writeMarker(upstream: String) throws {
        try "\(upstream)\n\(getpid())\n".write(toFile: markerPath, atomically: true, encoding: .utf8)
    }

    static func removeMarker() {
        unlink(markerPath)
    }
}

/// Git-хуки Радарчика: после `git pull`, `git checkout` и `git clone` они зовут
/// Радарчик проверить код (`--codescan`). Лежат рядом с базой и переписываются
/// при каждом запуске — путь к приложению мог поменяться. Подключаются одной
/// командой: `git config --global core.hooksPath …` (показываем на экране «Защита»).
enum GitHooks {
    static var folder: String { ShellHook.folder.appendingPathComponent("git-hooks").path }

    /// Команда, которую человек вставляет в терминал сам.
    static var connectCommand: String { "git config --global core.hooksPath \"\(folder)\"" }

    /// Подключены ли: глобальный `core.hooksPath` смотрит в нашу папку.
    static func isConnected() -> Bool {
        guard let result = Git.run(["config", "--global", "--get", "core.hooksPath"]), result.status == 0 else { return false }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = value.hasPrefix("~") ? NSHomeDirectory() + value.dropFirst() : value
        return URL(fileURLWithPath: expanded).standardizedFileURL.path == URL(fileURLWithPath: folder).standardizedFileURL.path
    }

    /// Записать хуки с путём к этому приложению.
    static func install() throws {
        guard let binary = Bundle.main.executablePath else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for hook in ["post-merge", "post-checkout"] {
            let path = folder + "/" + hook
            try script(hook: hook, binary: binary).write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
        }
    }

    /// Хук: проверка кода и свой хук репозитория, если он есть (`.git/hooks/…`):
    /// глобальный `core.hooksPath` иначе отключил бы его.
    private static func script(hook: String, binary: String) -> String {
        """
        #!/bin/sh
        # Радарчик: проверка кода после git pull / checkout / clone (SPEC.md, §3б).
        # Файл перезаписывается при каждом запуске Радарчика — правки сюда не вносить.
        RADARCHIK='\(binary.replacingOccurrences(of: "'", with: "'\\''"))'
        [ -x "$RADARCHIK" ] && "$RADARCHIK" --codescan \(hook) "$@"
        LOCAL="$(git rev-parse --git-dir 2>/dev/null)/hooks/\(hook)"
        [ -x "$LOCAL" ] && "$LOCAL" "$@"
        exit 0

        """
    }
}
