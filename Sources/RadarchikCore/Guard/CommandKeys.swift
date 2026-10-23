import Foundation

/// Какие ключи нужны команде: категория и, для ключей проекта, его папка.
public struct KeyNeed: Hashable, Sendable {
    public let category: GuardCategory
    /// Папка проекта: открыть ключи только его. nil — всю категорию (ssh).
    public let scope: String?

    public init(category: GuardCategory, scope: String?) {
        self.category = category
        self.scope = scope
    }
}

/// Подпись коммитов и тегов в git: чем и что подписывается само.
/// У пользователя — SSH-ключом (`gpg.format = ssh`, `commit.gpgsign = true`):
/// без открытого ключа `git commit` падает.
public struct GitSigning: Equatable, Sendable {
    public enum Format: Sendable {
        case ssh
        /// openpgp (по умолчанию) и x509 — ключом GPG.
        case gpg
    }

    public let format: Format
    /// `commit.gpgsign`: коммиты (и merge, rebase, cherry-pick) подписываются сами.
    public let commits: Bool
    /// `tag.gpgsign`: теги подписываются сами.
    public let tags: Bool

    public init(format: Format, commits: Bool, tags: Bool) {
        self.format = format
        self.commits = commits
        self.tags = tags
    }

    public static let off = GitSigning(format: .gpg, commits: false, tags: false)

    /// Каким ключом подписывать.
    public var category: GuardCategory { format == .ssh ? .ssh : .gpg }

    /// Из конфигов git по порядку: общий первым, репозитория последним —
    /// последнее значение главнее, как у самого git.
    public static func read(_ configs: [String]) -> GitSigning {
        func value(_ section: String, _ key: String) -> String? {
            configs.compactMap { GitConfigFile.value($0, section: section, key: key) }.last
        }
        func flag(_ section: String, _ key: String) -> Bool {
            ["true", "yes", "on", "1"].contains(value(section, key)?.lowercased() ?? "")
        }
        return GitSigning(format: value("gpg", "format")?.lowercased() == "ssh" ? .ssh : .gpg, commits: flag("commit", "gpgsign"), tags: flag("tag", "gpgsign"))
    }
}

/// Что известно о месте, где запускают команду. Файлы (`.git/config`, папки
/// проекта) читает приложение — правилам достаются готовые ответы.
public struct CommandContext: Sendable {
    public let cwd: String
    /// Папка проекта: ближайшая вверх, где есть `config/credentials`,
    /// `config/master.key` или `.env`; nil — команда не в проекте.
    public let projectRoot: String?
    /// Подпись коммитов и тегов из конфигов git.
    public let signing: GitSigning
    /// URL удалённого репозитория по имени; имя nil — основной (origin или первый).
    public let remoteURL: @Sendable (String?) -> String?

    public init(cwd: String, projectRoot: String?, signing: GitSigning = .off, remoteURL: @escaping @Sendable (String?) -> String?) {
        self.cwd = cwd
        self.projectRoot = projectRoot
        self.signing = signing
        self.remoteURL = remoteURL
    }
}

/// Этап 3 «Защиты» (SPEC §3б): каким ключам нужна команда терминала.
/// zsh-хук перед командой спрашивает Радарчик. Нужны и закрыты — root-часть
/// показывает Touch ID и открывает их на время команды, потом закрывает.
///
/// Правила — по тому, что реально читает ключи:
/// - ssh: `git push/pull/fetch/clone` по SSH-адресу, `ssh`, `scp`/`rsync`
///   на другой хост, `kamal`, `cap`, `ansible`;
/// - ключ подписи (SSH или GPG): `git commit`, `merge`, `rebase`, `cherry-pick`,
///   `revert`, `am` и `tag`, когда подпись включена в конфиге или флагом;
/// - ключи проекта: `rails credentials:*` и всё, что поднимает приложение
///   (`rails c`, `s`, `db:*`), `docker build` и `compose build/up --build`
///   (сборка читает всю папку), `kamal`.
/// Команды внутри контейнера (`docker compose run … -e RAILS_MASTER_KEY=…`)
/// ничего на маке не читают — им не нужно.
public enum CommandKeys {
    public static func needs(_ command: String, context: CommandContext) -> [KeyNeed] {
        var result: [KeyNeed] = []
        for words in segments(command) {
            for need in needs(words: normalize(words), context: context) where !result.contains(need) {
                result.append(need)
            }
        }
        return result
    }

    /// Коротко, для окна Touch ID: «git push», «rails credentials:edit». Берём
    /// первую часть цепочки, которой нужны ключи; nil — таких нет или подпись
    /// не проходит проверку (`GuardHelper.isSafeCommandLabel`).
    public static func label(_ command: String) -> String? {
        // Контекст «всё возможно»: здесь важно только, какая часть цепочки про ключи.
        let anything = CommandContext(cwd: "/", projectRoot: "/", signing: GitSigning(format: .ssh, commits: true, tags: true)) { _ in
            "git@host:repository"
        }
        for words in segments(command) {
            let normalized = normalize(words)
            guard !needs(words: normalized, context: anything).isEmpty else { continue }
            let full = segmentLabel(normalized)
            if GuardHelper.isSafeCommandLabel(full) { return full }
            return normalized.first.flatMap { GuardHelper.isSafeCommandLabel($0) ? $0 : nil }
        }
        return nil
    }

    /// Адрес по SSH: `git@host:path`, `host:path`, `ssh://…`. https, file:// и локальные пути — нет.
    public static func isSSHURL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        if ["ssh://", "git+ssh://", "ssh+git://"].contains(where: lowered.hasPrefix) { return true }
        if url.contains("://") || ["/", ".", "~"].contains(where: url.hasPrefix) { return false }
        guard let colon = url.firstIndex(of: ":") else { return false }
        let host = url[..<colon]
        return !host.isEmpty && !host.contains("/")
    }

    // MARK: - Правила

    private static func needs(words: [String], context: CommandContext) -> [KeyNeed] {
        guard let program = words.first else { return [] }
        let args = Array(words.dropFirst())
        let ssh = KeyNeed(category: .ssh, scope: nil)
        let project = context.projectRoot.map { KeyNeed(category: .env, scope: $0) }
        switch program {
        case "git":
            return gitNeeds(args, context: context)
        case "ssh", "sftp", "mosh", "ssh-copy-id", "sshfs", "cap", "ansible", "ansible-playbook":
            return [ssh]
        case "scp":
            return args.contains(where: isRemotePath) ? [ssh] : []
        case "rsync":
            let viaSSH = args.contains(where: isRemotePath) || args.contains { $0 == "-e" || $0.hasPrefix("--rsh") }
            return viaSSH ? [ssh] : []
        case "kamal":
            let sub = args.first { !$0.hasPrefix("-") }
            guard let sub, !["version", "help", "init", "docs"].contains(sub) else { return [] }
            return [ssh] + (project.map { [$0] } ?? [])
        case "rails":
            guard let sub = args.first, railsBootsWithKeys(sub), let project else { return [] }
            return [project]
        case "docker":
            return dockerReadsFolder(args) ? (project.map { [$0] } ?? []) : []
        default:
            return []
        }
    }

    /// Что нужно git: SSH-ключ для обмена с удалённым по SSH-адресу (push, pull,
    /// fetch, ls-remote, clone, remote update) и ключ подписи, если команда
    /// создаёт подписанный коммит или тег.
    private static func gitNeeds(_ args: [String], context: CommandContext) -> [KeyNeed] {
        var index = 0
        // Глобальные флаги git до подкоманды: -C <папка>, -c <ключ=значение>, --git-dir=…
        while index < args.count, args[index].hasPrefix("-") {
            index += ["-C", "-c"].contains(args[index]) ? 2 : 1
        }
        guard index < args.count else { return [] }
        let sub = args[index]
        let options = Array(args.dropFirst(index + 1))
        var needs: [KeyNeed] = []
        if gitTalksToSSHRemote(sub, options, context: context) { needs.append(KeyNeed(category: .ssh, scope: nil)) }
        if gitSigns(sub, options, context: context) {
            let signing = KeyNeed(category: context.signing.category, scope: nil)
            if !needs.contains(signing) { needs.append(signing) }
        }
        return needs
    }

    private static func gitTalksToSSHRemote(_ sub: String, _ options: [String], context: CommandContext) -> Bool {
        let rest = options.filter { !$0.hasPrefix("-") }
        switch sub {
        case "clone":
            return rest.first.map(isSSHURL) ?? false
        case "push", "pull", "fetch", "ls-remote":
            // Первый позиционный — имя удалённого (или сразу адрес); нет — основной.
            if let first = rest.first {
                if isSSHURL(first) { return true }
                if let url = context.remoteURL(first) { return isSSHURL(url) }
            }
            return context.remoteURL(nil).map(isSSHURL) ?? false
        case "remote":
            return rest.first == "update" && (context.remoteURL(nil).map(isSSHURL) ?? false)
        default:
            return false
        }
    }

    /// Создаст ли команда подписанный коммит или тег. `-S` / `--gpg-sign` — подписать,
    /// `--no-gpg-sign` — нет; без флагов — как в конфиге (`commit.gpgsign`, `tag.gpgsign`).
    /// `-s` у commit — это Signed-off-by, а не подпись.
    private static func gitSigns(_ sub: String, _ options: [String], context: CommandContext) -> Bool {
        switch sub {
        case "commit", "merge", "rebase", "cherry-pick", "revert", "am", "pull":
            if options.contains("--no-gpg-sign") { return false }
            let explicit = options.contains { $0 == "-S" || $0.hasPrefix("--gpg-sign") || ($0.hasPrefix("-S") && !$0.hasPrefix("--")) }
            return explicit || context.signing.commits
        case "tag":
            // Список, удаление и проверка тегов ничего не подписывают.
            let readOnly: Set<String> = ["-l", "--list", "-d", "--delete", "-v", "--verify"]
            guard !options.contains(where: readOnly.contains), options.contains(where: { !$0.hasPrefix("-") }) else { return false }
            if options.contains("--no-sign") { return false }
            return options.contains("-s") || options.contains("--sign") || options.contains("-u") || context.signing.tags
        default:
            return false
        }
    }

    /// Подкоманды Rails, которые читают ключи: правка секретов и всё, что поднимает приложение.
    private static func railsBootsWithKeys(_ sub: String) -> Bool {
        if sub.hasPrefix("credentials:") || sub.hasPrefix("encrypted:") || sub.hasPrefix("db:") { return true }
        return ["c", "console", "s", "server", "r", "runner", "dbconsole", "assets:precompile"].contains(sub)
    }

    /// docker build и compose build/up --build читают всю папку проекта — и закрытые ключи в ней.
    private static func dockerReadsFolder(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if first == "build" { return true }
        if ["buildx", "image", "builder"].contains(first) { return args.dropFirst().first == "build" }
        guard first == "compose" else { return false }
        let sub = composeSubcommand(Array(args.dropFirst()))
        return sub == "build" || (sub == "up" && args.contains("--build"))
    }

    /// Подкоманда compose после его флагов (`-f файл`, `-p имя`, `--profile x`).
    private static func composeSubcommand(_ args: [String]) -> String? {
        let withValue: Set<String> = ["-f", "--file", "-p", "--project-name", "--profile", "--env-file", "--project-directory", "--ansi", "--parallel"]
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            index += withValue.contains(args[index]) ? 2 : 1
        }
        return index < args.count ? args[index] : nil
    }

    /// `host:путь` или `user@host:путь` — копия на другой хост.
    private static func isRemotePath(_ argument: String) -> Bool {
        guard !argument.hasPrefix("-"), !["/", ".", "~"].contains(where: argument.hasPrefix), !argument.contains("://"),
              let colon = argument.firstIndex(of: ":")
        else { return false }
        let host = argument[..<colon]
        return !host.isEmpty && !host.contains("/")
    }

    // MARK: - Разбор командной строки

    /// Части цепочки (`&&`, `||`, `;`, `|`, `&`, скобки) — каждая словами,
    /// кавычки сняты: `echo 'git push'` — это echo с одним словом, а не git.
    static func segments(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        let characters = Array(command)
        var index = 0
        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", index + 1 < characters.count {
                    index += 1
                    word.append(characters[index])
                } else {
                    word.append(character)
                }
                index += 1
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                inWord = true
            case "\\":
                if index + 1 < characters.count {
                    index += 1
                    word.append(characters[index])
                    inWord = true
                }
            case " ", "\t":
                endWord()
            case "\n", ";", "&", "|", "(", ")":
                endSegment()
            default:
                word.append(character)
                inWord = true
            }
            index += 1
        }
        endSegment()
        return segments
    }

    /// Программа — первым словом и коротко: без `VAR=…`, `sudo`, `env`, `bundle exec`;
    /// `bin/rails` → «rails», `docker-compose` → «docker compose».
    static func normalize(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            if first.contains("="), !first.hasPrefix("-"), first.first.map({ $0.isLetter || $0 == "_" }) == true {
                rest = rest.dropFirst()
            } else if ["sudo", "env", "command", "exec", "time", "nohup", "noglob"].contains(first) {
                rest = rest.dropFirst()
                // Флаги самой обёртки: sudo -E, env -i.
                while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }
            } else if first == "bundle", rest.dropFirst().first == "exec" {
                rest = rest.dropFirst(2)
            } else {
                break
            }
        }
        guard let program = rest.first else { return [] }
        let name = (program as NSString).lastPathComponent
        if name == "docker-compose" { return ["docker", "compose"] + rest.dropFirst() }
        return [name] + rest.dropFirst()
    }

    /// «git push», «rails credentials:edit», «docker compose up», «ssh».
    private static func segmentLabel(_ words: [String]) -> String {
        guard let program = words.first else { return "" }
        let positional = words.dropFirst().filter { !$0.hasPrefix("-") }
        switch program {
        case "git", "rails", "kamal", "cap":
            return ([program] + positional.prefix(1)).joined(separator: " ")
        case "docker":
            if positional.first == "compose" {
                let sub = composeSubcommand(Array(words.dropFirst(2)))
                return (["docker", "compose"] + (sub.map { [$0] } ?? [])).joined(separator: " ")
            }
            return (["docker"] + positional.prefix(1)).joined(separator: " ")
        default:
            return program
        }
    }
}

/// `.git/config`: удалённые репозитории и их адреса.
public enum GitConfigFile {
    /// Имена удалённых в порядке файла.
    public static func remoteNames(_ text: String) -> [String] {
        remotes(text).map(\.name)
    }

    /// Значение `секция.ключ` (последнее, как у git). Имена секций и ключей git
    /// сравнивает без учёта регистра: `gpgSign` и `gpgsign` — одно и то же.
    public static func value(_ text: String, section: String, key: String) -> String? {
        var current = ""
        var found: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                current = line[line.index(after: line.startIndex)..<end].trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard current == section.lowercased(), let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
                found = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return found
    }

    /// Адрес удалённого по имени; nil-имя — origin, а нет его — первый.
    public static func remoteURL(_ text: String, name: String?) -> String? {
        let all = remotes(text)
        if let name { return all.first { $0.name == name }?.url }
        return (all.first { $0.name == "origin" } ?? all.first)?.url
    }

    private static func remotes(_ text: String) -> [(name: String, url: String?)] {
        var result: [(name: String, url: String?)] = []
        var current: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                // [remote "origin"]
                if line.hasPrefix("[remote \""), let end = line.lastIndex(of: "\"") {
                    let start = line.index(line.startIndex, offsetBy: 9)
                    if start < end {
                        result.append((String(line[start..<end]), nil))
                        current = result.count - 1
                    }
                }
                continue
            }
            guard let index = current, result[index].url == nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            if key == "url" {
                result[index].url = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}
