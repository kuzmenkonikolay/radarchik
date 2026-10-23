import Foundation

/// Что говорит Радарчик про «Защиту»: в записке под чёлкой, в облачке
/// и на экране «Защита». Всё на двух языках и без секретов.
public enum GuardPhrase {
    // MARK: - Ключи

    /// Фраза о ключах целиком: главное и, если всё закрыто, сколько раз открывал сегодня.
    public static func keys(_ categories: [CategoryStatus], now: Date, unlocksToday: [GuardCategory: Int], home: String = NSHomeDirectory()) -> String {
        let headline = keysHeadline(categories, now: now, home: home)
        guard !categories.contains(where: \.isOpen), let today = today(unlocksToday) else { return headline }
        return headline + ". " + today
    }

    /// Короткая строка для сводки: «Все ключи закрыты · сегодня открывал 8 раз»
    /// или то, что открыто сейчас.
    public static func keysLine(_ categories: [CategoryStatus], now: Date, unlocksToday: [GuardCategory: Int], home: String = NSHomeDirectory()) -> String {
        let headline = keysHeadline(categories, now: now, home: home)
        let total = unlocksToday.values.reduce(0, +)
        guard !categories.contains(where: \.isOpen), total > 0 else { return headline }
        let times = total == 1 ? L("один раз", "once") : "\(total) \(Words.plural(total, ru: ("раз", "раза", "раз"), en: ("time", "times")))"
        return headline + L(" · сегодня открывал \(times)", " · opened \(times) today")
    }

    /// «Сегодня открывал: ssh — 6 раз, env — 2 раза»; nil — сегодня не открывал.
    public static func today(_ unlocksToday: [GuardCategory: Int]) -> String? {
        let parts = GuardCategory.allCases.compactMap { category -> String? in
            guard let count = unlocksToday[category], count > 0 else { return nil }
            return L("\(category.shortName) — \(count) \(Words.plural(count, ru: ("раз", "раза", "раз"), en: ("time", "times")))",
                     count == 1 ? "\(category.shortName) once" : "\(category.shortName) \(count) times")
        }
        guard !parts.isEmpty else { return nil }
        return L("Сегодня открывал: ", "Opened today: ") + parts.joined(separator: ", ")
    }

    /// Главное о ключах. Сначала то, что требует действия: открыто слишком долго →
    /// идёт таймер → открыто вручную → новый незакрытый ключ → всё закрыто.
    public static func keysHeadline(_ categories: [CategoryStatus], now: Date, home: String = NSHomeDirectory()) -> String {
        let open = categories.filter(\.isOpen)
        let overdue = open.filter { status in
            guard let closesAt = status.window?.closesAt else { return false }
            return now > closesAt.addingTimeInterval(GuardStatus.overdueGrace)
        }
        if let first = overdue.min(by: { ($0.window?.openedAt ?? now) < ($1.window?.openedAt ?? now) }), let openedAt = first.window?.openedAt {
            let lasting = DurationFormat.short(now.timeIntervalSince(openedAt))
            let names = overdue.map(\.category.shortName).joined(separator: " ")
            return L("Открыто уже \(lasting): \(titles(overdue)). Закрой: sudo guard lock \(names)",
                     "Open for \(lasting): \(titles(overdue)). Lock it: sudo guard lock \(names)")
        }
        let timed = open.filter { ($0.window?.closesAt).map { $0 > now } ?? false }
        if let closesAt = timed.compactMap(\.window?.closesAt).min() {
            let left = GuardWing.clock(closesAt.timeIntervalSince(now))
            return L("Открыто: \(titles(timed)) — закроются через \(left)", "Open: \(titles(timed)) — locking in \(left)")
        }
        let manual = open.filter { $0.window != nil }
        if !manual.isEmpty {
            return L("Открыто до ручной блокировки: \(titles(manual))", "Open until you lock it: \(titles(manual))")
        }
        let fresh = open.flatMap(\.openFiles)
        if fresh.count == 1 {
            let path = ShellRedactor.shortenHome(fresh[0].path, home: home)
            return L("Не закрыт ключ \(path) — его закроет sudo guard init", "Key \(path) isn’t locked — sudo guard init will lock it")
        }
        if fresh.count > 1 {
            return L("Не закрыто ключей: \(fresh.count) — их закроет sudo guard init", "\(fresh.count) keys aren’t locked — sudo guard init will lock them")
        }
        return L("Все ключи закрыты", "All keys are locked")
    }

    private static func titles(_ categories: [CategoryStatus]) -> String {
        categories.map(\.category.title).joined(separator: ", ")
    }

    // MARK: - Окно Touch ID

    /// Текст системного окна Touch ID. Пишет его root-часть, а не Радарчик:
    /// подделанный клиент не сможет попросить «открыть ssh», показав «закрыть».
    /// «Радарчик откроет SSH-ключи на 5 минут.» Под команду терминала —
    /// «…на время команды «git push»», ключи одного проекта — «ключи проекта storefront».
    /// В конце — кто просит: «Просит: zsh ← Terminal.» (`GuardHelper.requester`).
    public static func unlockPrompt(
        _ categories: [GuardCategory], minutes: Int?, project: String? = nil, command: String? = nil, requester: String? = nil
    ) -> String {
        let sentence = unlockSentence(categories, minutes: minutes, project: project, command: command)
        guard let requester else { return sentence }
        return sentence + " " + L("Просит: \(requester).", "Requested by: \(requester).")
    }

    private static func unlockSentence(_ categories: [GuardCategory], minutes: Int?, project: String?, command: String?) -> String {
        let what: String
        if let project, categories == [.env] {
            what = L("ключи проекта \(project)", "the keys of project \(project)")
        } else if Set(categories) == Set(GuardCategory.allCases) {
            what = L("все ключи", "all keys")
        } else {
            let names = categories.map(\.inSentence)
            what = names.count > 1 ? names.dropLast().joined(separator: ", ") + L(" и ", " and ") + names[names.count - 1] : names.first ?? ""
        }
        if let command, GuardHelper.isSafeCommandLabel(command) {
            return L("Радарчик откроет \(what) на время команды «\(command)».", "Radarchik will open \(what) while “\(command)” runs.")
        }
        guard let minutes else {
            return L("Радарчик откроет \(what) до ручной блокировки.", "Radarchik will open \(what) until you lock them.")
        }
        let how: String
        if minutes % 60 == 0 {
            let hours = minutes / 60
            how = "\(hours) " + Words.plural(hours, ru: ("час", "часа", "часов"), en: ("hour", "hours"))
        } else {
            how = "\(minutes) " + Words.plural(minutes, ru: ("минуту", "минуты", "минут"), en: ("minute", "minutes"))
        }
        return L("Радарчик откроет \(what) на \(how).", "Radarchik will open \(what) for \(how).")
    }

    /// Текст окна Touch ID для просьбы к ssh-agent (2026-10-21). Тоже пишет root-часть,
    /// из проверенных кусков: «Радарчик даст ключ id_ed25519 для подписи коммита
    /// в storefront. Просит: Claude Code ← zsh ← Terminal.»
    public static func signPrompt(key: String?, action: GuardHelper.SignAction, place: String?, requester: String?) -> String {
        let what = key.map { L("ключ \($0)", "key \($0)") } ?? L("SSH-ключ", "the SSH key")
        let purpose: String = switch action {
        case .commit: place.map { L("для подписи коммита в \($0)", "to sign a commit in \($0)") } ?? L("для подписи коммита", "to sign a commit")
        case .login: place.map { L("для входа на \($0)", "to log in to \($0)") } ?? L("для входа по SSH", "to log in over SSH")
        case .sign: L("для подписи", "to sign data")
        }
        let sentence = L("Радарчик даст \(what) \(purpose).", "Radarchik will hand over \(what) \(purpose).")
        guard let requester else { return sentence }
        return sentence + " " + L("Просит: \(requester).", "Requested by: \(requester).")
    }

    // MARK: - Ключи под команду (этап 3)

    /// «SSH-ключи», «ключи проекта storefront».
    public static func need(_ need: KeyNeed) -> String {
        if need.category == .env, let scope = need.scope {
            return L("ключи проекта \((scope as NSString).lastPathComponent)", "the keys of project \((scope as NSString).lastPathComponent)")
        }
        return need.category.inSentence
    }

    /// В терминал, когда ключи нужны, а root-части нет: что и как это починить.
    public static func commandHint(command: String?, needs: [KeyNeed]) -> String {
        let what = needs.map(need).joined(separator: L(" и ", " and "))
        let who = command.map { L("\($0) нужны", "\($0) needs") } ?? L("Команде нужны", "This command needs")
        return L("Радарчик: \(who) \(what), а они закрыты. Открывать по Touch ID сам я смогу, когда поставишь root-часть: make install-guard",
                 "Radarchik: \(who) \(what), and they’re locked. I can open them with Touch ID once the root part is installed: make install-guard")
    }

    // MARK: - Кто пользуется SSH-ключом

    /// Что сделали ключом: «Вход на root@45.59.120.176», «Подпись коммита в storefront».
    public static func agentAction(_ purpose: SSHSignPurpose, destination: String?, place: String?) -> String {
        switch purpose {
        case .login(let user):
            if let destination { return L("Вход на \(destination)", "Login to \(destination)") }
            return L("Вход как \(user)", "Login as \(user)")
        case .signature("git"):
            if let place { return L("Подпись коммита в \(place)", "Commit signature in \(place)") }
            return L("Подпись коммита", "Commit signature")
        case .signature("file"):
            return L("Подпись файла", "File signature")
        case .signature(let namespace):
            return L("Подпись (\(namespace))", "Signature (\(namespace))")
        case .other:
            return L("Подпись", "Signature")
        }
    }

    /// Запись журнала: «Вход на root@45.59.120.176 — из терминала».
    public static func agentUse(_ action: String, origin: AgentOrigin) -> String {
        switch origin.kind {
        case .terminal: L("\(action) — из терминала", "\(action) — from the terminal")
        case .script: L("\(action) — запустил \(origin.name)", "\(action) — started by \(origin.name)")
        case .app: L("\(action) — из \(origin.name)", "\(action) — from \(origin.name)")
        case .assistant: L("\(action) — через \(origin.name)", "\(action) — via \(origin.name)")
        case .background: L("\(action) — \(origin.name) в фоне", "\(action) — \(origin.name) in the background")
        }
    }

    /// Запись журнала, когда ты не подтвердил окно: «Не дал SSH-ключ Claude Code: подпись коммита в storefront».
    public static func agentRefused(_ action: String, origin: AgentOrigin) -> String {
        let what = action.prefix(1).lowercased() + action.dropFirst()
        return L("Не дал SSH-ключ \(origin.name): \(what)", "Refused the SSH key to \(origin.name): \(what)")
    }

    /// Тревога: «SSH-ключом пользуется node install.js: вход на git@github.com».
    public static func agentAlarm(_ action: String, origin: AgentOrigin) -> String {
        let what = action.prefix(1).lowercased() + action.dropFirst()
        return L("SSH-ключом пользуется \(origin.name): \(what)", "\(origin.name) is using your SSH key: \(what)")
    }

    /// Программа из записи — для «Что это?»: первое имя цепочки во второй строке
    /// («151.101.1.223 · curl ← zsh ← …» → «curl»), у процесса — программа из командной
    /// строки, иначе — первое слово заголовка.
    public static func programName(_ event: GuardEvent) -> String {
        if let detail = event.detail {
            let chain = detail.split(separator: " · ").last.map(String.init) ?? detail
            if event.kind == .process {
                if let program = chain.split(separator: " ").first { return (String(program) as NSString).lastPathComponent }
            } else if let first = chain.split(separator: " ← ").first {
                let name = first.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return String(event.title.split(separator: " ").first ?? "")
    }

    // MARK: - Сеть (2026-10-22)

    /// «node install.js → 45.59.120.176:4444»; обычный порт не пишем.
    public static func networkTitle(name: String, host: String, port: UInt16) -> String {
        name + " → " + place(host, port)
    }

    /// Записка: «Новый адрес у Claude Code · curl: docs.python.org»; с пометкой — «… — без DNS, по адресу».
    public static func networkNote(name: String, host: String, port: UInt16, reasons: [NetworkRules.Reason] = []) -> String {
        let note = L("Новый адрес у \(name): \(place(host, port))", "New address for \(name): \(place(host, port))")
        guard !reasons.isEmpty else { return note }
        return note + " — " + reasons.map(networkReason).joined(separator: ", ")
    }

    /// Тревога: «node install.js пошёл на 45.59.120.176:4444 — без DNS, по адресу».
    public static func networkAlarm(name: String, host: String, port: UInt16, reasons: [NetworkRules.Reason]) -> String {
        let why = reasons.map(networkReason).joined(separator: ", ")
        return L("\(name) пошёл на \(place(host, port)) — \(why)", "\(name) went to \(place(host, port)) — \(why)")
    }

    private static func place(_ host: String, _ port: UInt16) -> String {
        host + (port == 443 || port == 80 ? "" : ":\(port)")
    }

    public static func networkReason(_ reason: NetworkRules.Reason) -> String {
        switch reason {
        case .rawAddress: L("без DNS, по адресу", "no DNS, straight to an address")
        case .oddPort: L("нестандартный порт", "unusual port")
        case .suspiciousHost: L("туннель или ловушка для утечек", "a tunnel or a leak catcher")
        case .freshDependency: L("зависимость сразу после установки", "a dependency right after install")
        case .tempScript: L("скрипт из временной папки", "a script from a temp folder")
        case .hiddenScript: L("скрипт из скрытой папки", "a script from a hidden folder")
        }
    }

    /// Фраза лица на экране «Сеть».
    public static func networkHeadline(_ summary: NetworkSummary, watching: Bool, helperInstalled: Bool) -> String {
        guard helperInstalled else {
            return L("Сетевой надзор ждёт root-часть: make install-guard.", "The network watch needs the root part: make install-guard.")
        }
        guard watching else { return L("Сеть пока не слушаю.", "Not listening to the network yet.") }
        if let alarm = summary.events.first(where: { $0.level == .critical && $0.status == .active }) { return alarm.title + "." }
        guard !summary.seen.isEmpty else { return L("Пока ни один скрипт никуда не ходил.", "No script has gone anywhere yet.") }
        let hosts = summary.hostCount
        let hostsText = "\(hosts) " + Words.plural(hosts, ru: ("адрес", "адреса", "адресов"), en: ("address", "addresses"))
        let fresh = summary.events.filter { $0.level >= .warning }.count
        if fresh == 0 {
            return L("За сутки скрипты ходили на \(hostsText), всё знакомое.", "Scripts reached \(hostsText) today, all familiar.")
        }
        let freshText = "\(fresh) " + Words.plural(fresh, ru: ("новый", "новых", "новых"), en: ("new", "new"))
        return L("За сутки — \(hostsText), из них \(freshText).", "\(hostsText) today, \(freshText) among them.")
    }

    // MARK: - Процессы

    /// «node -e — запустил Cursor»; родителя нет — просто что случилось.
    public static func process(_ finding: ProcessFinding) -> String {
        guard let parent = finding.process.parentPath.map(programName) else { return finding.threat.title }
        return L("\(finding.threat.title) — запустил \(parent)", "\(finding.threat.title) — started by \(parent)")
    }

    /// Имя программы: приложение по `.app` в пути («Cursor»), иначе имя файла («zsh»).
    public static func programName(_ path: String) -> String {
        if let app = AppIdentityResolver.outermostAppBundle(inExecutablePath: path) {
            let name = (app as NSString).lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Проверка кода

    /// «Проверил 47 файлов в storefront — чисто» или про опасное — первым.
    public static func scan(_ report: CodeScanReport) -> String {
        let name = report.repositoryName
        let files = Words.plural(report.filesChecked, ru: ("файл", "файла", "файлов"), en: ("file", "files"))
        switch report.level {
        case .critical:
            let count = report.critical.count
            let spots = Words.plural(count, ru: ("опасное место", "опасных места", "опасных мест"), en: ("dangerous spot", "dangerous spots"))
            let after = report.trigger == .manual ? "" : L(" после \(report.trigger.command)", " after \(report.trigger.command)")
            return L("В \(name)\(after) — \(count) \(spots). Не запускай код, пока не посмотришь",
                     "\(count) \(spots) in \(name)\(after). Don’t run the code until you look")
        case .warning:
            let count = report.warnings.count
            let spots = Words.plural(count, ru: ("место", "места", "мест"), en: ("spot", "spots"))
            return L("Проверил \(report.filesChecked) \(files) в \(name) — \(count) \(spots) стоит глянуть",
                     "Checked \(report.filesChecked) \(files) in \(name) — \(count) \(spots) worth a look")
        case .info:
            return L("Проверил \(report.filesChecked) \(files) в \(name) — чисто", "Checked \(report.filesChecked) \(files) in \(name) — all clean")
        }
    }

    /// Находка одной строкой: «babel.config.js:2 — конфиг сборки ходит в сеть… · eval(d)».
    public static func finding(_ finding: CodeFinding) -> String {
        group(CodeFindingGroup(file: finding.file, line: finding.line, threats: [finding.threat], excerpt: finding.excerpt))
    }

    /// Место в коде со всем, что на нём нашлось: «babel.config.js:2 — конфиг сборки…, eval(), адрес сервера по IP · …».
    public static func group(_ group: CodeFindingGroup) -> String {
        let place = group.line.map { "\(group.file):\($0)" } ?? group.file
        let code = group.excerpt.isEmpty ? "" : " · " + group.excerpt
        return "\(place) — \(group.threats.map(\.title).joined(separator: ", "))\(code)"
    }

    // MARK: - Настройки Claude Code

    /// «Claude Code разрешено без спроса: Bash(*) — ~/.claude/settings.json».
    public static func audit(_ finding: AuditFinding, home: String) -> String {
        auditText(finding) + " — " + ShellRedactor.shortenHome(finding.path, home: home)
    }

    /// То же без пути — на экране путь идёт второй строкой.
    public static func auditText(_ finding: AuditFinding) -> String {
        let repository = repositoryName(finding.path)
        return switch finding.issue {
        case .wildcard(let entry):
            L("Claude Code разрешено без спроса: \(entry)", "Claude Code may do this without asking: \(entry)")
        case .dangerousCommand(let command):
            L("Claude Code разрешено без спроса: \(command)", "Claude Code may run this without asking: \(command)")
        case .bypassMode:
            L("Claude Code работает, ни о чём не спрашивая (bypassPermissions)", "Claude Code runs without asking anything (bypassPermissions)")
        case .permissionsFromRepository:
            L("Репозиторий \(repository) выдаёт Claude Code разрешения", "Repository \(repository) grants Claude Code permissions")
        case .hooksFromRepository:
            L("Репозиторий \(repository) включает хуки Claude Code", "Repository \(repository) turns on Claude Code hooks")
        case .localHooks:
            L("В \(repository) есть хуки Claude Code — проверь, что они твои", "\(repository) has Claude Code hooks — make sure they’re yours")
        case .mcpFromRepository(let names):
            L("Репозиторий \(repository) предлагает MCP-серверы: \(names.joined(separator: ", "))",
              "Repository \(repository) offers MCP servers: \(names.joined(separator: ", "))")
        case .secretInConfig(let name):
            L("Ключ \(name) лежит в настройках открытым текстом", "Key \(name) sits in the settings in plain text")
        case .downloadAndRunInstructions:
            L("CLAUDE.md в \(repository) просит скачать и запустить скрипт", "CLAUDE.md in \(repository) asks to download and run a script")
        }
    }

    /// Папка проекта: для `…/app/.claude/settings.json` — «app», для `…/app/CLAUDE.md` — тоже «app».
    static func repositoryName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let claude = parts.lastIndex(of: ".claude"), claude > 0 { return parts[claude - 1] }
        return parts.dropLast().last ?? path
    }
}
