import Foundation

/// Правила «Сетевого надзора» (SPEC §3б, 2026-10-22). Узкое наблюдение: не файрвол,
/// а второй глаз там, где LuLu слепа. LuLu решает по бинарнику, и node, curl, ssh,
/// python у пользователя разрешены «куда угодно» — значит, postinstall из npm и скрипт
/// под Claude Code выходят в сеть без вопросов. Радарчик смотрит по скрипту и цепочке
/// запуска: кто именно, кем запущен, куда и впервые ли.
///
/// Что наше:
/// - скрипт, который запустил не ты (postinstall под npm, всё под Claude Code);
/// - инструмент под ИИ-агентом (curl, git, ssh из Bash-инструмента Claude Code);
/// - сам агент: его API — известные хосты, одна запись; WebFetch на чужой сайт — записка;
/// - скрипт, набранный тобой (`npm install`, `kamal deploy`) — только запись, без алертов.
/// Что не наше: приложения, фон (autossh), команды терминала без интерпретатора,
/// локальная сеть и loopback, DNS. Это или LuLu, или не угроза.
public enum NetworkRules {
    /// Насколько это наше.
    public enum Scope: Equatable, Sendable {
        case ignore
        /// Скрипт набрал ты сам: `npm install` в терминале. Запись в журнал, тревог нет.
        case typed
        /// Скрипт или инструмент запустил не ты — смотрим внимательно.
        case watched
    }

    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// Адрес без имени: DNS не спрашивали, адрес зашит в код.
        case rawAddress
        case oddPort
        /// Туннель или ловушка для утечек: ngrok, interact.sh, webhook.site…
        case suspiciousHost
        /// Скрипт из зависимостей (node_modules, gems, site-packages) — сразу после установки.
        case freshDependency
        case tempScript
        case hiddenScript
    }

    public struct Assessment: Equatable, Sendable {
        public let level: GuardLevel
        public let reasons: [Reason]

        public init(level: GuardLevel, reasons: [Reason]) {
            self.level = level
            self.reasons = reasons
        }
    }

    /// Сколько после установки или git pull зависимость считается «свежей».
    public static let freshWindow: TimeInterval = 10 * 60

    // MARK: - Адреса

    public static func isLoopback(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.")
    }

    /// Частные и служебные сети: 10/8, 172.16/12, 192.168/16, link-local, CGNAT, ULA.
    public static func isPrivate(_ address: String) -> Bool {
        if isLoopback(address) { return true }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254), (0, _): return true
            case (172, let second) where (16...31).contains(second): return true
            case (100, let second) where (64...127).contains(second): return true
            default: return false
            }
        }
        let lower = address.lowercased()
        return lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb")
    }

    /// Порты, по которым ходят сами скрипты: DNS и mDNS — не соединения с сервисом.
    public static func isServicePort(_ port: UInt16) -> Bool { port == 53 || port == 5353 }

    public static func isCommonPort(_ port: UInt16) -> Bool {
        [80, 443, 22, 21, 25, 465, 587, 993, 995, 8080, 8443, 2222, 9418].contains(port)
    }

    /// Имя адреса: свежее из DNS, иначе сам адрес.
    public static func host(_ flow: NetworkFlow) -> String { flow.names.first ?? flow.address }

    // MARK: - Хосты

    /// Куда скрипты ходят по работе: реестры пакетов, git-хостинги, API агентов, Apple.
    /// Новый адрес отсюда — запись, а не записка.
    static let knownHosts: [String] = [
        "github.com", "githubusercontent.com", "githubassets.com", "gitlab.com", "bitbucket.org",
        "npmjs.org", "npmjs.com", "yarnpkg.com", "npm.im", "jsr.io", "deno.land", "bun.sh", "nodejs.org",
        "rubygems.org", "pypi.org", "pythonhosted.org", "crates.io", "golang.org", "pkg.go.dev",
        "repo1.maven.org", "maven.apache.org", "nuget.org", "packagist.org", "hex.pm", "cocoapods.org",
        "brew.sh", "ghcr.io", "docker.io", "docker.com", "quay.io", "gcr.io",
        "anthropic.com", "claude.ai", "openai.com", "huggingface.co",
        "apple.com", "icloud.com", "swift.org", "cdn.jsdelivr.net", "unpkg.com",
        "registry.terraform.io", "releases.hashicorp.com", "debian.org", "ubuntu.com", "sentry.io",
    ]

    /// Туннели и сервисы-ловушки, куда утекают секреты в отчётах о supply chain.
    static let suspiciousHosts: [String] = [
        "ngrok.io", "ngrok-free.app", "ngrok.app", "ngrok.dev", "serveo.net", "localhost.run", "lhr.life", "trycloudflare.com",
        "loca.lt", "localtunnel.me", "bore.pub", "pinggy.io", "zrok.io", "tunnelto.dev", "expose.dev", "pagekite.me",
        "burpcollaborator.net", "oastify.com", "oast.fun", "oast.live", "oast.me", "oast.online", "oast.pro", "oast.site",
        "interact.sh", "interactsh.com", "requestbin.net", "requestbin.com", "pipedream.net", "webhook.site", "beeceptor.com",
        "hookbin.com", "requestcatcher.com", "postb.in", "ptsv2.com", "ptsv3.com", "dnslog.cn", "ceye.io", "canarytokens.com", "mockbin.org",
    ]

    public static func isKnownHost(_ host: String) -> Bool { matches(host, knownHosts) }
    public static func isSuspiciousHost(_ host: String) -> Bool { matches(host, suspiciousHosts) }

    private static func matches(_ host: String, _ suffixes: [String]) -> Bool {
        let lower = host.lowercased()
        return suffixes.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }

    // MARK: - Кто

    /// Насколько наше это соединение: по источнику из цепочки (`AgentWatchRules.origin`).
    public static func scope(_ chain: [ProcessLink], origin: AgentOrigin) -> Scope {
        switch origin.kind {
        case .terminal, .app, .background: return .ignore
        case .script: return AgentWatchRules.isTypedScript(chain, origin: origin) ? .typed : .watched
        // Сам агент (WebFetch) и его инструменты — наше. Его API — известные хосты, одна запись на адрес.
        case .assistant: return .watched
        }
    }

    /// Сам агент — клиент и есть источник (WebFetch Claude Code); иначе — его инструмент.
    static func isAgentItself(_ chain: [ProcessLink], origin: AgentOrigin) -> Bool {
        origin.kind == .assistant && chain.first?.pid == origin.pid
    }

    /// Ключ источника для «видели ли» и «Всегда»: скрипт — с путём, инструмент агента — с именем инструмента.
    public static func identity(_ chain: [ProcessLink], origin: AgentOrigin) -> String {
        switch origin.kind {
        case .assistant where isAgentItself(chain, origin: origin): "net|assistant|\(origin.identity)"
        case .assistant: "net|assistant|\(origin.identity)|\(chain.first?.name ?? "?")"
        default: "net|\(origin.kind.rawValue)|\(origin.identity)"
        }
    }

    /// Как назвать источник: «node install.js», «Claude Code · curl», сам агент — «Claude Code».
    public static func name(_ chain: [ProcessLink], origin: AgentOrigin) -> String {
        switch origin.kind {
        case .assistant where isAgentItself(chain, origin: origin): origin.name
        case .assistant: origin.name + " · " + (chain.first.map { ($0.path as NSString).lastPathComponent } ?? "?")
        default: origin.name
        }
    }

    public static func allowKey(identity: String, host: String) -> String { identity + "|" + host }

    /// Путь скрипта из identity источника («/opt/homebrew/bin/node /…/install.js»).
    static func scriptPath(_ origin: AgentOrigin) -> String? {
        guard origin.kind == .script, let space = origin.identity.firstIndex(of: " ") else { return nil }
        let path = String(origin.identity[origin.identity.index(after: space)...])
        return path.isEmpty ? nil : path
    }

    /// Скрипт из зависимостей: его написал не ты и не твой коллега.
    static func isDependency(_ path: String) -> Bool {
        ["/node_modules/", "/vendor/bundle/", "/vendor/cache/", "/site-packages/", "/.gem/", "/gems/", "/.cargo/registry/", "/.npm/_npx/", "/.bun/install/", "/.pnpm/"]
            .contains { path.contains($0) }
    }

    /// Установка пакетов: после неё зависимости «свежие» на `freshWindow`.
    /// `npm install`, `pnpm add`, `pip install`, `bundle install`, `gem install`, `cargo install`…
    public static func isInstall(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        var program = (first as NSString).lastPathComponent.lowercased()
        var rest = arguments.dropFirst()
        // `node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js install`, `python -m pip install`.
        if program.hasPrefix("node") || program.hasPrefix("python") || program == "ruby" {
            guard let script = rest.first(where: { !$0.hasPrefix("-") || $0 == "-m" }) else { return false }
            if script == "-m" {
                rest = rest.dropFirst(rest.firstIndex(of: "-m").map { $0 - rest.startIndex + 1 } ?? 1)
                program = rest.first?.lowercased() ?? ""
                rest = rest.dropFirst()
            } else {
                program = (script as NSString).lastPathComponent.lowercased().replacingOccurrences(of: "-cli.js", with: "").replacingOccurrences(of: ".js", with: "")
                rest = rest.dropFirst(rest.firstIndex(of: script).map { $0 - rest.startIndex + 1 } ?? 1)
            }
        }
        let installers: Set<String> = ["npm", "pnpm", "yarn", "bun", "npx", "pip", "pip3", "gem", "bundle", "bundler", "poetry", "uv", "cargo", "composer", "pod", "mix"]
        guard installers.contains(program) else { return false }
        let verbs: Set<String> = ["install", "i", "add", "ci", "update", "upgrade", "sync", "deps.get"]
        return rest.first { !$0.hasPrefix("-") }.map { verbs.contains($0.lowercased()) } ?? false
    }

    // MARK: - Решение

    /// Новая пара «источник → адрес» у того, за кем смотрим. `fresh` — недавно был
    /// `npm install`, `git pull` или подобное. Известный хост — запись; остальное —
    /// записка «стоит глянуть», а с приметой утечки — тревога с «Убить». Голый адрес
    /// сам по себе — только записка: имя могло лежать в кэше резолвера, и в эфире
    /// ответа DNS не было (первая проверка 2026-10-22: curl на github — «без DNS»).
    /// Голый адрес с нестандартным портом — уже тревога.
    public static func assess(flow: NetworkFlow, origin: AgentOrigin, scope: Scope, fresh: Bool, home: String) -> Assessment? {
        guard scope != .ignore else { return nil }
        let host = host(flow)
        let hasName = !flow.names.isEmpty
        if scope == .typed || (hasName && isKnownHost(host)) { return Assessment(level: .info, reasons: []) }
        var reasons: [Reason] = []
        if !hasName { reasons.append(.rawAddress) }
        if !isCommonPort(flow.port) { reasons.append(.oddPort) }
        if hasName && isSuspiciousHost(host) { reasons.append(.suspiciousHost) }
        if let script = scriptPath(origin) {
            if ProcessWatchRules.isTemp(script) { reasons.append(.tempScript) }
            if ProcessWatchRules.isInUnknownHiddenFolder(script, home: home) { reasons.append(.hiddenScript) }
            if fresh && isDependency(script) { reasons.append(.freshDependency) }
        }
        let strong: Set<Reason> = [.suspiciousHost, .tempScript, .hiddenScript, .freshDependency]
        let critical = reasons.contains(where: strong.contains) || (reasons.contains(.rawAddress) && reasons.contains(.oddPort))
        return Assessment(level: critical ? .critical : .warning, reasons: reasons)
    }
}

/// Что видели за сутки: пара «источник → адрес» со счётчиком — для экрана «Сеть».
public struct NetworkSeen: Equatable, Sendable, Identifiable {
    public let identity: String
    public let name: String
    public let host: String
    public let project: String?
    public let firstSeen: Date
    public let lastSeen: Date
    public let count: Int
    public let level: GuardLevel

    public var id: String { identity + "|" + host }

    public init(identity: String, name: String, host: String, project: String?, firstSeen: Date, lastSeen: Date, count: Int, level: GuardLevel) {
        self.identity = identity
        self.name = name
        self.host = host
        self.project = project
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
        self.level = level
    }
}

/// Экран «Сеть»: что видели и что сказали за сутки.
public struct NetworkSummary: Equatable, Sendable {
    public var seen: [NetworkSeen] = []
    public var events: [GuardEvent] = []

    public init(seen: [NetworkSeen] = [], events: [GuardEvent] = []) {
        self.seen = seen
        self.events = events
    }

    public var hostCount: Int { Set(seen.map(\.host)).count }
    public var sourceCount: Int { Set(seen.map(\.identity)).count }

    /// Группы для экрана: по проекту, без проекта — по источнику. Внутри — адреса, свежие первыми.
    public var groups: [NetworkGroup] {
        var order: [String] = []
        var buckets: [String: [NetworkSeen]] = [:]
        for item in seen.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let key = item.project ?? item.name
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { NetworkGroup(title: $0, hosts: buckets[$0] ?? []) }
    }
}

public struct NetworkGroup: Equatable, Sendable, Identifiable {
    public let title: String
    public let hosts: [NetworkSeen]
    public var id: String { title }

    public init(title: String, hosts: [NetworkSeen]) {
        self.title = title
        self.hosts = hosts
    }
}
