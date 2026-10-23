import Foundation

/// Какой это файл настроек Claude Code.
public enum ClaudeConfigKind: String, Sendable {
    /// `~/.claude/settings.json` и `settings.local.json` — твои.
    case userSettings
    /// `<проект>/.claude/settings.json` — обычно лежит в git, то есть приходит с чужими коммитами.
    case projectSettings
    /// `<проект>/.claude/settings.local.json` — пишет сам Claude Code, когда жмёшь «всегда».
    case projectLocalSettings
    /// `<проект>/.mcp.json` — MCP-серверы проекта.
    case mcp
    /// `<проект>/CLAUDE.md` — инструкции, которые Claude читает первыми.
    case claudeMd
}

public struct ClaudeConfigFile: Sendable, Equatable {
    public let path: String
    public let kind: ClaudeConfigKind
    public let content: String
    /// Лежит в git — значит, мог прийти чужим коммитом.
    public let inGit: Bool

    public init(path: String, kind: ClaudeConfigKind, content: String, inGit: Bool) {
        self.path = path
        self.kind = kind
        self.content = content
        self.inGit = inGit
    }
}

/// Что не так в настройках.
public enum AuditIssue: Sendable, Hashable {
    /// Любые команды или правки без спроса: `Bash(*)`, `Bash`, `Edit(*)`, `Write(*)`.
    case wildcard(String)
    /// `defaultMode: bypassPermissions` — Claude вообще ни о чём не спрашивает.
    case bypassMode
    /// Опасная команда без спроса: `rm`, `curl`, `sudo`…
    case dangerousCommand(String)
    /// Разрешения пришли из репозитория (файл в git).
    case permissionsFromRepository
    /// Хуки пришли из репозитория: они выполняют команды сами.
    case hooksFromRepository
    /// Хуки в твоих настройках проекта — стоит знать, что они есть.
    case localHooks
    /// Репозиторий предлагает MCP-серверы.
    case mcpFromRepository([String])
    /// Ключ открытым текстом (имя переменной, без значения).
    case secretInConfig(String)
    /// CLAUDE.md из репозитория просит скачать и запустить скрипт.
    case downloadAndRunInstructions
}

public struct AuditFinding: Sendable, Equatable, Identifiable {
    public var id: String { "\(path)|\(issue)" }
    public let path: String
    public let kind: ClaudeConfigKind
    public let issue: AuditIssue
    public let level: GuardLevel

    /// Подробность без значений: «Bash(*)», «rm», «browser, db», имя переменной.
    public var detail: String {
        switch issue {
        case .wildcard(let entry): entry
        case .dangerousCommand(let command): command
        case .mcpFromRepository(let names): names.joined(separator: ", ")
        case .secretInConfig(let name): name
        case .bypassMode: "bypassPermissions"
        case .permissionsFromRepository, .hooksFromRepository, .localHooks, .downloadAndRunInstructions: ""
        }
    }
}

/// Проверка настроек Claude Code (SPEC §3б) — замена `guard audit`.
///
/// В bash-версии тревогой было любое `"allow"` в настройках проекта. Но их пишет
/// сам Claude Code, когда жмёшь «всегда», — отсюда ложные тревоги. Опасно другое:
/// разрешения, хуки и MCP-серверы, пришедшие из репозитория, то есть файлы в git.
/// Чужой коммит может так выдать Claude права или запускать команды сам.
public enum ClaudeConfigAudit {
    /// Разрешения, которые снимают вопросы целиком.
    private static let wildcards: Set<String> = ["Bash", "Bash(*)", "Bash(*:*)", "Edit", "Edit(*)", "Edit(**)", "Write", "Write(*)", "Write(**)"]

    /// Команды, которым нельзя без спроса: удаляют, качают, повышают права, уносят данные.
    private static let dangerousCommands = [
        "rm", "curl", "wget", "chmod", "chown", "dd", "mkfs", "kill", "pkill", "launchctl", "defaults write", "osascript",
        "security", "ssh", "scp", "rsync", "nc", "git push", "git reset", "npm publish", "npx", "pip install", "brew install",
        "networksetup", "dscl", "crontab", "eval", "base64",
    ]

    public static func audit(_ files: [ClaudeConfigFile]) -> [AuditFinding] {
        files.flatMap(audit)
    }

    private static func audit(_ file: ClaudeConfigFile) -> [AuditFinding] {
        var found: [AuditFinding] = []
        // Одно и то же в одном файле — один раз: «curl» из двух разных разрешений — это всё ещё curl.
        func add(_ issue: AuditIssue, _ level: GuardLevel) {
            guard !found.contains(where: { $0.issue == issue }) else { return }
            found.append(AuditFinding(path: file.path, kind: file.kind, issue: issue, level: level))
        }
        if file.kind == .claudeMd {
            if file.inGit, downloadAndRun.firstMatch(in: file.content, range: NSRange(file.content.startIndex..., in: file.content)) != nil {
                add(.downloadAndRunInstructions, .warning)
            }
            return found
        }
        guard let data = file.content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        let fromRepository = file.inGit && file.kind != .userSettings
        let permissions = json["permissions"] as? [String: Any]
        let allow = (permissions?["allow"] as? [Any])?.compactMap { $0 as? String } ?? []

        if (permissions?["defaultMode"] as? String) == "bypassPermissions" { add(.bypassMode, .critical) }
        if fromRepository, !allow.isEmpty { add(.permissionsFromRepository, .critical) }
        for entry in allow {
            if wildcards.contains(entry) {
                add(.wildcard(entry), .critical)
            } else if let command = dangerousCommand(in: entry) {
                // sudo без спроса — то же самое, что разрешить всё.
                add(.dangerousCommand(command), command == "sudo" ? .critical : .warning)
            }
        }
        if let hooks = json["hooks"] as? [String: Any], hookCommands(hooks) > 0 {
            add(fromRepository ? .hooksFromRepository : .localHooks, fromRepository ? .critical : .warning)
        }
        let servers = json["mcpServers"] as? [String: Any] ?? [:]
        if file.kind == .mcp, fromRepository, !servers.isEmpty {
            add(.mcpFromRepository(servers.keys.sorted()), .warning)
        }
        // Ключи открытым текстом: в env самих настроек и в env MCP-серверов.
        let environments = [json["env"] as? [String: Any] ?? [:]]
            + servers.keys.sorted().compactMap { (servers[$0] as? [String: Any])?["env"] as? [String: Any] }
        for environment in environments {
            for name in environment.keys.sorted() where isSecret(name: name, value: environment[name] as? String ?? "") {
                add(.secretInConfig(name), .warning)
            }
        }
        return found
    }

    /// `Bash(rm:*)` → «rm», `Bash(git push:*)` → «git push»; nil — команда не из опасных.
    private static func dangerousCommand(in entry: String) -> String? {
        guard entry.hasPrefix("Bash("), entry.hasSuffix(")") else { return nil }
        let inner = entry.dropFirst(5).dropLast()
        let command = String(inner.split(separator: ":", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
        if command == "sudo" || command.hasPrefix("sudo ") { return "sudo" }
        return dangerousCommands.first { command == $0 || command.hasPrefix($0 + " ") }
    }

    /// Сколько команд в хуках: `{ "Stop": [ { "hooks": [ { "command": … } ] } ] }`.
    private static func hookCommands(_ hooks: [String: Any]) -> Int {
        hooks.values.reduce(0) { total, value in
            let matchers = value as? [Any] ?? []
            return total + matchers.reduce(0) { sum, matcher in
                sum + (((matcher as? [String: Any])?["hooks"] as? [Any])?.count ?? 0)
            }
        }
    }

    /// Похоже ли значение на ключ: известный формат токена или «секретное» имя и длинное значение.
    private static func isSecret(name: String, value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if ShellRedactor.redact(value) != value { return true }
        let upper = name.uppercased()
        let secretName = ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { upper.contains($0) }
        return secretName && value.count >= 16
    }

    private static let downloadAndRun = try! NSRegularExpression(
        pattern: #"\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|python[0-9.]*|node)\b"#, options: [.caseInsensitive]
    )
}
