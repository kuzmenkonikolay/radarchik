import AppKit
import SwiftUI
import RadarchikCore

/// Все экраны раскрытой чёлки в PNG — для моей проверки вёрстки (экран мне
/// не виден) и для README. Данные выдуманные и живут только в памяти: база
/// ":memory:", свой набор UserDefaults, Связка ключей не трогается, сеть тоже.
///
/// Запуск: `.build/debug/Radarchik --render-screens <папка> [--language en|ru]`.
/// Поля ввода и системные меню из AppKit в картинку не рисуются — на их месте
/// будет жёлтая заглушка; всё своё (переключатели, тумблеры, кнопки) — рисуется.
@MainActor
enum ScreensRenderer {
    static func render(to folder: URL, language: Language) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // В листе для проверки вёрстки «Защита» включена: её экраны тоже надо видеть.
        let world = try PreviewWorld(language: language, withGuard: true)
        defer { world.cleanUp() }

        let screens: [(String, [Route])] = [
            ("home", []),
            ("project", [.project(world.mainProject.id)]),
            ("tips", [.tips]),
            ("review", [.review]),
            ("payments", [.payments]),
            ("entry-new", [.entryForm(.new(.recurring, projectId: nil))]),
            ("entry-income", [.entryForm(.new(.income, projectId: world.mainProject.id))]),
            ("entry-edit", [.entryForm(.editRecurring(world.serverId))]),
            ("project-form", [.projectForm(editing: world.mainProject.id)]),
            ("system", [.system]),
            ("protection", [.protection]),
            ("settings", [.settings]),
            ("observation", [.observation]),
            ("today", [.today]),
            ("claude", [.claudeSettings]),
            ("prompt", [.reviewPrompt]),
            ("alert-income", [.alert(.income(world.incomeNews))]),
            ("alert-pay", [.alert(.pay(world.payReminder))]),
        ]
        for (name, path) in screens {
            try write(world.panel(path), to: folder.appendingPathComponent("screen-\(name).png"))
        }
        // Свёрнутая чёлка: лицо слева, цифры, бейдж советов.
        try write(world.collapsed(), to: folder.appendingPathComponent("screen-collapsed.png"))
        // Тревога о ресурсах: на главной вместо фразы и как алерт.
        world.showAlert()
        try write(world.panel([]), to: folder.appendingPathComponent("screen-home-alert.png"))
        try write(world.panel([.alert(.resource(1))]), to: folder.appendingPathComponent("screen-alert-resource.png"))
        // «Что это?»: думаю (ползунок с мини-лицом) и ответ Claude.
        world.review.explain.preview("resource:1", .thinking(step: 2))
        try write(world.panel([.alert(.resource(1))]), to: folder.appendingPathComponent("screen-alert-resource-thinking.png"))
        world.review.explain.preview("resource:1", .answer(world.explainedResource))
        try write(world.panel([.alert(.resource(1))]), to: folder.appendingPathComponent("screen-alert-resource-explained.png"))
        world.review.explain.reset("resource:1")
        // «Защита» (SPEC §3б): открыт ssh — замок с отсчётом; node -e — тревога с кнопками.
        world.showGuardAlert()
        try write(world.collapsed(), to: folder.appendingPathComponent("screen-collapsed-guard.png"))
        try write(world.panel([]), to: folder.appendingPathComponent("screen-home-guard.png"))
        try write(world.panel([.alert(.guardEvent(world.guardEvent(900)))]), to: folder.appendingPathComponent("screen-alert-guard.png"))
        // «Стоит глянуть» после git pull: жёлтый алерт с «Показать / Понятно», ответа «Защите» не нужно.
        try write(world.panel([.alert(.guardEvent(world.guardEvent(903)))]), to: folder.appendingPathComponent("screen-alert-guard-note.png"))
        try write(world.panel([.protection]), to: folder.appendingPathComponent("screen-protection-alert.png"))
        // «Сеть»: куда за сутки ходили скрипты и команды Claude Code.
        try write(world.panel([.network]), to: folder.appendingPathComponent("screen-network.png"))
        // Чужой взял SSH-ключ: глаза wide и красные, кнопки «Убить / Понятно / Всегда».
        world.showAgentAlarm()
        try write(world.collapsed(), to: folder.appendingPathComponent("screen-collapsed-agent.png"))
        try write(world.panel([.alert(.guardEvent(world.guardEvent(910)))]), to: folder.appendingPathComponent("screen-alert-agent.png"))
        // postinstall пошёл на голый адрес сразу после npm install: тревога сети с «Убить».
        world.showNetworkAlarm()
        try write(world.panel([.alert(.guardEvent(world.guardEvent(920)))]), to: folder.appendingPathComponent("screen-alert-network.png"))
        world.review.explain.preview("guard:920", .answer(world.explainedNetwork))
        try write(world.panel([.alert(.guardEvent(world.guardEvent(920)))]), to: folder.appendingPathComponent("screen-alert-network-explained.png"))
        world.review.explain.reset("guard:920")
        try write(world.panel([.network]), to: folder.appendingPathComponent("screen-network-alert.png"))
    }

    /// Картинки для README (`--render-docs <папка> --language en|ru`): главные
    /// экраны, каждый по высоте своего содержимого.
    static func renderDocs(to folder: URL, language: Language) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let world = try PreviewWorld(language: language)
        defer { world.cleanUp() }
        // Главная раньше советов: экран советов отмечает их прочитанными.
        try write(world.panel([]), to: folder.appendingPathComponent("summary.png"), tight: true)
        try write(world.panel([.project(world.mainProject.id)]), to: folder.appendingPathComponent("project.png"), tight: true)
        for (name, route) in [("system", Route.system), ("tips", .tips), ("settings", .settings)] {
            try write(world.panel([route]), to: folder.appendingPathComponent("\(name).png"), tight: true)
        }
        try write(world.collapsed(), to: folder.appendingPathComponent("collapsed.png"), tight: true)
        try write(world.panel([.alert(.income(world.incomeNews))]), to: folder.appendingPathComponent("income.png"), tight: true)
        world.showAlert()
        try write(world.panel([]), to: folder.appendingPathComponent("summary-alert.png"), tight: true)
    }

    /// Экраны для ролика (`--render-sting <папка>`): по-английски, с «Защитой»,
    /// по высоте содержимого и без «стола» — фон прозрачный. Плюс слово «Radarchik».
    static func renderSting(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let world = try PreviewWorld(language: .en, withGuard: true)
        defer { world.cleanUp() }
        let file = { (name: String) in folder.appendingPathComponent("\(name).png") }
        try write(world.collapsed(), to: file("collapsed"), tight: true, transparent: true)
        try write(world.panel([]), to: file("summary"), tight: true, transparent: true)
        try write(world.panel([.project(world.mainProject.id)]), to: file("project"), tight: true, transparent: true)
        let screens: [(String, Route)] = [
            ("payments", .payments), ("tips", .tips), ("review", .review), ("observation", .observation), ("today", .today),
            ("system", .system), ("protection", .protection), ("settings", .settings), ("entry", .entryForm(.new(.recurring, projectId: nil))),
            ("income", .alert(.income(world.incomeNews))), ("pay", .alert(.pay(world.payReminder))),
        ]
        for (name, route) in screens {
            try write(world.panel([route]), to: file(name), tight: true, transparent: true)
        }
        world.showAlert()
        try write(world.panel([]), to: file("summary-alert"), tight: true, transparent: true)
        world.showGuardAlert()
        try write(world.collapsed(), to: file("collapsed-guard"), tight: true, transparent: true)
        try write(world.panel([.alert(.guardEvent(world.guardEvent(900)))]), to: file("guard-alert"), tight: true, transparent: true)
        for (name, color) in [("wordmark-white", Color.white), ("wordmark-dark", Color(hex: "#1E2F52"))] {
            let word = Text("Radarchik")
                .font(.system(size: 200, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .padding(24)
            let renderer = ImageRenderer(content: word)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw RenderFailure(description: "not rendered: \(name)") }
            try data.write(to: file(name))
        }
    }

    /// `tight` — холст по высоте экрана (для README), иначе с запасом под самый длинный.
    /// `transparent` — без «стола», для ролика.
    private static func write(_ view: some View, to url: URL, tight: Bool = false, transparent: Bool = false) throws {
        // «Рабочий стол» под чёлкой — видно границы панели и её тень.
        let desk = LinearGradient(colors: [Color(hex: "#1C2040"), Color(hex: "#111327")], startPoint: .top, endPoint: .bottom)
        let content = Group {
            if tight {
                view
                    .padding(.bottom, 36)
                    .frame(width: DS.Size.panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background { if !transparent { desk } }
            } else {
                ZStack(alignment: .top) {
                    if !transparent { desk }
                    view
                }
                // Холст выше окна: длинные экраны видны целиком.
                .frame(width: DS.Size.panelWidth, height: 760)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.unrollsScrolling, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderFailure(description: "not rendered: \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}

/// Рендер не удался: что именно.
struct RenderFailure: Error, CustomStringConvertible {
    let description: String
}

/// Выдуманный мак для листа экранов: два проекта с полугодом истории,
/// разбор дня с двумя советами, нагрузка мака за час. По-русски — в рублях,
/// по-английски — в долларах и со своими названиями.
@MainActor
final class PreviewWorld {
    let settings: AppSettings
    let store: MoneyStore
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor
    let model: NotchViewModel
    let mainProject: Project
    let serverId: UUID

    private static let suite = "dev.kuzmenko.radarchik.screens"
    private let gib = 1_073_741_824.0
    private let now = Date()

    /// `withGuard` — включить «Защиту» (SPEC §3б). README и ролик рисуются без неё:
    /// она пока только в сборке автора.
    init(language: Language, withGuard: Bool = false) throws {
        let defaults = UserDefaults(suiteName: Self.suite) ?? .standard
        defaults.removePersistentDomain(forName: Self.suite)
        settings = AppSettings(defaults: defaults)
        // Язык — до данных: из него названия, валюта и советы.
        settings.languageChoice = language == .ru ? .ru : .en
        settings.observationEnabled = true
        settings.showNumbersWhenCollapsed = true
        settings.guardEnabled = withGuard

        // Деньги — прямо в базу, а потом в MoneyStore: так нет события «доход добавлен»
        // (иначе на всех картинках глаза-монетки).
        let ledger = try LedgerRepository(database: Database(path: ":memory:"))
        let money = Self.money(language)
        mainProject = try Self.fill(ledger, with: money, month: YearMonth(now), today: LocalDate(now))
        serverId = money.serverId
        store = try MoneyStore(repository: ledger)

        let activity = try ActivityRepository(database: Database(path: ":memory:"))
        tracker = ActivityTracker(repository: activity, settings: settings)
        let reviews = try ReviewRepository(database: Database(path: ":memory:"))
        _ = try reviews.save(
            periodStart: now.addingTimeInterval(-86_400), periodEnd: now.addingTimeInterval(-3_600), createdAt: now.addingTimeInterval(-3_600),
            prompt: L("Сводка дня: Arc 3 ч 10 мин, Терминал 2 ч 05 мин, Xcode 40 мин…\nКоманды: make run ×12, swift test ×9…",
                      "Day summary: Arc 3h 10m, Terminal 2h 5m, Xcode 40m…\nCommands: make run ×12, swift test ×9…"),
            result: ReviewResult(tips: Self.tips, model: "claude-opus-5-5", inputTokens: 2_017, outputTokens: 1_680, costUSD: 0.042)
        )
        review = ReviewService(reviews: reviews, activity: activity, settings: settings, tracker: tracker)
        review.loadForPreview()

        resources = ResourceMonitor(worker: try ResourceWorker(databasePath: ":memory:"), settings: settings, tracker: tracker)
        protection = GuardMonitor(worker: try GuardWorker(databasePath: ":memory:"), settings: settings, tracker: tracker)
        model = NotchViewModel(geometry: NotchGeometry(notchRect: CGRect(x: 0, y: 0, width: 220, height: 38), isHardware: true))
        resources.preview(state(alerts: []))
        protection.preview(keys: guardKeys(sshOpen: false), alerts: [], recent: guardJournal, scans: guardScans, audit: guardAudit, hooksConnected: false,
                           helper: .notInstalled, now: now)
    }

    /// Раскрытая панель на нужном экране — тот же `NotchRootView`, что в приложении.
    func panel(_ path: [Route]) -> some View {
        model.collapse(animated: false)
        model.expand(animated: false)
        for route in path { model.push(route) }
        if path.contains(.review) { review.previewProgress(ReviewProgress(step: 2, summary: L("8 ч 40 мин, 23 приложения", "8 h 40 min, 23 apps"))) }
        return NotchRootView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
    }

    /// Свёрнутая чёлка с лицом и цифрами.
    func collapsed() -> some View {
        model.collapse(animated: false)
        return NotchRootView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
    }

    /// Алерт «Пришли деньги»: сегодняшняя подписка главного проекта.
    var incomeNews: IncomeNews {
        let total = store.monthTotals.first { $0.currency == mainProject.currency }?.amount ?? 0
        let amount: Int64 = mainProject.currency == .rub ? 290_000 : 29_000
        return IncomeNews(
            id: UUID(), amount: amount, currency: mainProject.currency, projectName: mainProject.name,
            title: L("новая подписка", "new subscription"), before: total - amount, after: total, month: store.month
        )
    }

    /// Алерт «Пора платить»: сервер главного проекта через два дня.
    var payReminder: PayReminder {
        let cost = store.ledger.recurringCosts.first { $0.id == serverId }!
        let due = Calendar.current.date(byAdding: .day, value: 2, to: now)!
        return PayReminder(
            costId: cost.id, costName: cost.name, projectName: mainProject.name,
            payee: Payments.payeeKey(for: cost.url).map(Payments.payeeTitle(forKey:)) ?? cost.name,
            url: Payments.normalizedURL(cost.url), amount: cost.price(at: store.month) ?? 0, currency: mainProject.currency,
            dueDate: LocalDate(due), daysLeft: 2
        )
    }

    /// Открыт ssh (осталось 4:12) и только что поймали node -e из Cursor.
    func showGuardAlert() {
        resources.preview(state(alerts: []))
        let alert = GuardEvent(
            id: 900, kind: .process, level: .critical, at: now.addingTimeInterval(-40),
            title: L("node -e — запустил Cursor", "node -e — started by Cursor"),
            detail: "node -e const _$_1e42=[\"\\x63\\x68\\x69\\x6c\\x64\",\"\\x5f\\x70\\x72\"];global[_$_1e42[0]]…",
            allowKey: "inlineNode|/opt/homebrew/bin/node|/Applications/Cursor.app/Contents/MacOS/Cursor", status: .active, statusChangedAt: nil
        )
        protection.preview(keys: guardKeys(sshOpen: true), alerts: [alert], recent: [alert] + guardJournal, scans: guardScans, audit: guardAudit, hooksConnected: true,
                           helper: .ready, now: now, network: networkSummary(alarm: nil), networkWatching: true)
    }

    /// Ответы Claude на «Что это?» — для листа экранов.
    var explainedResource: ExplainResult {
        ExplainResult(
            explanation: Explanation(
                what: L("Arc — браузер на Chromium; 4 ГБ при десятках вкладок и расширениях для него обычное дело, память растёт с открытыми вкладками.",
                        "Arc is a Chromium browser; 4 GB with dozens of tabs and extensions is ordinary for it, memory grows with open tabs."),
                verdict: .normal,
                advice: L("Закрой лишние вкладки или перезапусти Arc, если тормозит.", "Close spare tabs or restart Arc if it lags.")
            ),
            model: ClaudeModel.opus.rawValue, costUSD: 0.012
        )
    }

    var explainedNetwork: ExplainResult {
        ExplainResult(
            explanation: Explanation(
                what: L("install.js из пакета evil — postinstall-скрипт зависимости; честным пакетам незачем ходить на голый адрес с портом 4444, это типичный приём утечки.",
                        "install.js from the evil package is a dependency’s postinstall script; honest packages have no reason to reach a bare address on port 4444 — a typical exfiltration pattern."),
                verdict: .attention,
                advice: L("Убей процесс, удали пакет и смени ключи, которые лежали в проекте.", "Kill the process, remove the package and rotate any keys kept in the project.")
            ),
            model: ClaudeModel.opus.rawValue, costUSD: 0.014
        )
    }

    /// Зависимость из node_modules сразу после npm install пошла на голый адрес с нестандартным портом.
    func showNetworkAlarm() {
        resources.preview(state(alerts: []))
        let alarm = networkAlarm
        protection.preview(keys: guardKeys(sshOpen: false), alerts: [alarm], recent: [alarm] + guardJournal, scans: guardScans, audit: guardAudit, hooksConnected: true,
                           helper: .ready, now: now, announcement: alarm, network: networkSummary(alarm: alarm), networkWatching: true)
    }

    private var networkAlarm: GuardEvent {
        GuardEvent(
            id: 920, kind: .network, level: .critical, at: now.addingTimeInterval(-15),
            title: L("node install.js пошёл на 45.59.120.176:4444 — без DNS, по адресу, нестандартный порт, зависимость сразу после установки",
                     "node install.js went to 45.59.120.176:4444 — no DNS, straight to an address, unusual port, a dependency right after install"),
            detail: "node install.js ← sh ← node npm ← zsh ← Terminal",
            allowKey: "net|script|/opt/homebrew/bin/node /Users/me/work/notely/node_modules/evil/install.js|45.59.120.176", status: .active, statusChangedAt: nil
        )
    }

    /// Что видели за сутки: npm проекта, curl из Claude Code и, если есть, тревога.
    private func networkSummary(alarm: GuardEvent?) -> NetworkSummary {
        let npm = "net|script|/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js"
        let curl = "net|assistant|claude|curl"
        var seen = [
            NetworkSeen(identity: npm, name: "node npm", host: "registry.npmjs.org", project: "notely", firstSeen: now.addingTimeInterval(-3 * 3_600), lastSeen: now.addingTimeInterval(-40), count: 14, level: .info),
            NetworkSeen(identity: npm, name: "node npm", host: "github.com", project: "notely", firstSeen: now.addingTimeInterval(-3 * 3_600), lastSeen: now.addingTimeInterval(-3 * 3_600), count: 2, level: .info),
            NetworkSeen(identity: curl, name: "Claude Code · curl", host: "docs.python.org", project: "storefront", firstSeen: now.addingTimeInterval(-50 * 60), lastSeen: now.addingTimeInterval(-50 * 60), count: 1, level: .warning),
            NetworkSeen(identity: curl, name: "Claude Code · curl", host: "api.stripe.com", project: "storefront", firstSeen: now.addingTimeInterval(-26 * 3_600 + 3_600), lastSeen: now.addingTimeInterval(-20 * 60), count: 3, level: .info),
        ]
        var events = [
            GuardEvent(
                id: 921, kind: .network, level: .warning, at: now.addingTimeInterval(-50 * 60),
                title: L("Новый адрес у Claude Code · curl: docs.python.org", "New address for Claude Code · curl: docs.python.org"),
                detail: "151.101.1.223 · curl ← zsh ← Claude Code ← zsh ← Terminal", allowKey: curl + "|docs.python.org", status: .logged, statusChangedAt: nil
            ),
        ]
        if let alarm {
            seen.insert(NetworkSeen(identity: "net|script|/opt/homebrew/bin/node /Users/me/work/notely/node_modules/evil/install.js", name: "node install.js", host: "45.59.120.176", project: "notely", firstSeen: alarm.at, lastSeen: alarm.at, count: 1, level: .critical), at: 0)
            events.insert(alarm, at: 0)
        }
        return NetworkSummary(seen: seen, events: events)
    }

    /// postinstall пакета при npm install сходил SSH-ключом на GitHub.
    func showAgentAlarm() {
        resources.preview(state(alerts: []))
        let alarm = GuardEvent(
            id: 910, kind: .agent, level: .critical, at: now.addingTimeInterval(-20),
            title: L("SSH-ключом пользуется node install.js: вход на git@github.com", "node install.js is using your SSH key: login to git@github.com"),
            detail: L("ключ id_ed25519", "key id_ed25519") + " · ssh ← git ← sh ← node install.js ← sh ← node npm ← zsh ← Terminal",
            allowKey: "agent|script|/opt/homebrew/bin/node /Users/me/work/notely/node_modules/evil/install.js", status: .active, statusChangedAt: nil
        )
        protection.preview(keys: guardKeys(sshOpen: false), alerts: [alarm], recent: [alarm] + guardJournal, scans: guardScans, audit: guardAudit, hooksConnected: true,
                           helper: .ready, now: now, announcement: alarm)
    }

    /// Событие «Защиты» из подготовленного состояния — для маршрута алерта.
    func guardEvent(_ id: Int64) -> GuardEvent {
        guard let event = (protection.alerts + protection.recent).first(where: { $0.id == id }) else {
            fatalError("в листе экранов нет события «Защиты» \(id)")
        }
        return event
    }

    func showAlert() {
        let browser = AppIdentity(key: "company.thebrowser.Browser", name: "Arc")
        let alert = ResourceAlert(
            id: 1, kind: .memory, app: browser, value: 4.1 * gib, usual: 1.4 * gib, startedAt: now.addingTimeInterval(-420), createdAt: now,
            title: ResourcePhrase.memory(app: "Arc", bytes: 4.1 * gib, usual: 1.4 * gib, totalBytes: 48 * gib), detail: nil,
            status: .active, statusChangedAt: nil
        )
        resources.preview(state(alerts: [alert]))
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suite)
    }

    // MARK: - Деньги

    /// Полгода двух проектов: главный растёт, второй — подработка, которая тает.
    private struct Money {
        var main: Project
        var side: Project
        var server: (name: String, url: String, amount: Int64)
        var domain: (name: String, url: String, amount: Int64)
        var sideServer: (name: String, url: String, amount: Int64)
        /// `today` — доходы, пришедшие в этом месяце (сегодня).
        var mainIncome: (name: String, base: Int64, step: Int64, today: [Int64])
        var sideIncome: (name: String, base: Int64, step: Int64)
        var ad: (name: String, amount: Int64)
        let serverId = UUID()
    }

    private static func money(_ language: Language) -> Money {
        switch language {
        case .ru:
            Money(
                main: Project(name: "Курсы", colorHex: "#7FB2FF", currency: .rub),
                side: Project(name: "Бот", colorHex: "#C9BFF0", currency: .rub),
                server: ("Сервер Selectel", "my.selectel.ru", 1_550_000),
                domain: ("Домен kursy.ru", "reg.ru", 240_000),
                sideServer: ("Hetzner", "console.hetzner.cloud", 450_000),
                mainIncome: ("Подписки", 3_000_000, 450_000, [1_200_000]),
                sideIncome: ("Клиент", 600_000, 100_000),
                ad: ("Реклама в Telegram", 500_000)
            )
        case .en:
            Money(
                main: Project(name: "Notely", colorHex: "#7FB2FF", currency: .usd),
                side: Project(name: "PingBot", colorHex: "#C9BFF0", currency: .usd),
                server: ("Vercel Pro", "vercel.com", 48_000),
                domain: ("notely.app domain", "namecheap.com", 2_400),
                sideServer: ("Hetzner", "console.hetzner.cloud", 4_500),
                // Месяц уже в плюсе: так его показывают README и ролик (−$1k → +$173 → +$2.9k).
                mainIncome: ("Subscriptions", 300_000, 45_000, [120_000, 275_000]),
                sideIncome: ("Client", 60_000, 10_000),
                ad: ("Ads on X", 50_000)
            )
        }
    }

    private static func fill(_ ledger: LedgerRepository, with money: Money, month: YearMonth, today: LocalDate) throws -> Project {
        try ledger.save(money.main)
        try ledger.save(money.side)
        try ledger.save(RecurringCost(
            id: money.serverId, projectId: money.main.id, name: money.server.name, url: money.server.url,
            period: .monthly, startMonth: month.adding(months: -6), amount: money.server.amount, dueDay: 22
        ))
        try ledger.save(RecurringCost(
            projectId: money.main.id, name: money.domain.name, url: money.domain.url,
            period: .yearly, startMonth: month.adding(months: -3), amount: money.domain.amount
        ))
        try ledger.save(RecurringCost(
            projectId: money.side.id, name: money.sideServer.name, url: money.sideServer.url,
            period: .monthly, startMonth: month.adding(months: -4), amount: money.sideServer.amount
        ))
        for offset in 1...6 {
            let past = month.adding(months: -offset)
            let amount = money.mainIncome.base + Int64(6 - offset) * money.mainIncome.step
            try ledger.save(Income(projectId: money.main.id, name: money.mainIncome.name, amount: amount, date: LocalDate(year: past.year, month: past.month, day: 12)))
        }
        for offset in 1...3 {
            let past = month.adding(months: -offset)
            let amount = money.sideIncome.base - Int64(offset) * money.sideIncome.step
            try ledger.save(Income(projectId: money.side.id, name: money.sideIncome.name, amount: amount, date: LocalDate(year: past.year, month: past.month, day: 5)))
        }
        try ledger.save(OneOffCost(projectId: money.main.id, name: money.ad.name, amount: money.ad.amount, date: today))
        for amount in money.mainIncome.today {
            try ledger.save(Income(projectId: money.main.id, name: money.mainIncome.name, amount: amount, date: today))
        }
        return money.main
    }

    // MARK: - Ресурсы

    private func state(alerts: [ResourceAlert]) -> ResourceState {
        let snapshot = SystemSnapshot(
            at: now, cpuPercent: 16,
            memory: MemoryReading(usedBytes: UInt64(30 * gib), totalBytes: UInt64(48 * gib), pressure: .normal),
            battery: BatteryReading(level: 100, isCharging: false, onAC: true, amperage: 0, capacityMah: 8_811, minutesLeft: nil),
            drainRate: nil, temperature: 54, thermal: .nominal
        )
        let apps: [(String, String, Double, Double, Double)] = [
            ("company.thebrowser.Browser", "Arc", 53, 3.2, 2.1), ("com.docker.docker", "Docker", 20, 6, 1.2),
            ("process:bash", "bash", 11, 0.05, 0.3), ("dev.kuzmenko.radarchik", L("Радарчик", "Radarchik"), 3, 0.12, 0.1),
            ("com.apple.dt.Xcode", "Xcode", 2, 2.4, 0.2), ("process:siriactionsd", "siriactionsd", 4, 0.08, 0.05),
        ]
        let rows = apps.map { app in
            AppUsageRow(
                usage: AppUsage(app: AppIdentity(key: app.0, name: app.1), cpuPercent: app.2, memoryBytes: UInt64(app.3 * gib), powerWatts: app.4, processCount: 1),
                usualCPU: app.1 == "Docker" ? 30 : nil, usualMemory: app.1 == "Docker" ? 3 * gib : nil, usualPower: nil
            )
        }
        let history = (0..<60).map { minute -> SystemMinute in
            let cpu = minute > 40 && minute < 48 ? 62 + Double(minute % 3) * 5 : 12 + 6 * sin(Double(minute) / 6)
            return SystemMinute(
                start: now.addingTimeInterval(-Double(59 - minute) * 60), cpu: cpu, memoryUsed: (27 + Double(minute) / 20) * gib,
                pressure: .normal, batteryLevel: 100, onBattery: false, drainRate: nil, temperature: 52, thermal: .nominal
            )
        }
        return ResourceState(system: snapshot, apps: rows, history: history, alerts: alerts, normsCount: 0)
    }

    // MARK: - Защита

    /// Ключи выдуманного мака: ssh, два проекта и AWS. test.key лежит в git — как в жизни.
    private func guardKeys(sshOpen: Bool) -> GuardKeysState {
        let home = NSHomeDirectory()
        let files = [
            ProtectedFile(path: home + "/.ssh/id_ed25519", category: .ssh, state: sshOpen ? .open : .locked),
            ProtectedFile(path: home + "/.ssh/config", category: .ssh, state: sshOpen ? .open : .locked),
            ProtectedFile(path: home + "/work/notely/config/master.key", category: .env, state: .locked),
            ProtectedFile(path: home + "/work/notely/config/credentials/production.key", category: .env, state: .locked),
            ProtectedFile(path: home + "/work/notely/config/credentials/test.key", category: .env, state: .locked, inGit: true),
            ProtectedFile(path: home + "/work/pingbot/.env", category: .env, state: .locked),
            ProtectedFile(path: home + "/.aws/credentials", category: .aws, state: .locked),
        ]
        let window = UnlockWindow(openedAt: now.addingTimeInterval(-48), mode: .timer, closesAt: now.addingTimeInterval(252))
        return GuardKeysState(
            categories: GuardStatus.categories(files, windows: sshOpen ? [.ssh: window] : [:]),
            unlocksToday: [.ssh: 6, .env: 2], source: sshOpen ? .helper : .legacyGuard
        )
    }

    private var guardJournal: [GuardEvent] {
        [
            // Слежка за SSH-ключом: вход и подпись из терминала — просто записи; Claude Code — после Touch ID.
            GuardEvent(
                id: 906, kind: .agent, level: .info, at: now.addingTimeInterval(-2 * 60),
                title: L("Подпись коммита в notely — через Claude Code · подтвердил по Touch ID", "Commit signature in notely — via Claude Code · confirmed via Touch ID"),
                detail: L("ключ id_ed25519", "key id_ed25519") + " · ssh-keygen ← git ← zsh ← Claude Code ← zsh ← Terminal", allowKey: nil, status: .logged, statusChangedAt: nil
            ),
            GuardEvent(
                id: 904, kind: .agent, level: .info, at: now.addingTimeInterval(-6 * 60),
                title: L("Вход на root@45.59.120.176 — из терминала", "Login to root@45.59.120.176 — from the terminal"),
                detail: L("ключ id_ed25519", "key id_ed25519") + " · ssh ← zsh ← Terminal", allowKey: nil, status: .logged, statusChangedAt: nil
            ),
            GuardEvent(
                id: 905, kind: .agent, level: .info, at: now.addingTimeInterval(-38 * 60),
                title: L("Подпись коммита в notely — из терминала", "Commit signature in notely — from the terminal"),
                detail: L("ключ id_ed25519", "key id_ed25519") + " · ssh-keygen ← git ← zsh ← Terminal", allowKey: nil, status: .logged, statusChangedAt: nil
            ),
            GuardEvent(
                id: 901, kind: .process, level: .warning, at: now.addingTimeInterval(-3 * 3_600),
                title: L("python -c — запустил zsh", "python -c — started by zsh"), detail: "python3 -c print(42)", allowKey: nil,
                status: .logged, statusChangedAt: nil
            ),
        ] + guardScans
    }

    private var guardScans: [GuardEvent] {
        [
            GuardEvent(
                id: 902, kind: .code, level: .info, at: now.addingTimeInterval(-25 * 60),
                title: L("Проверил 47 файлов в notely — чисто", "Checked 47 files in notely — all clean"), detail: nil, allowKey: nil,
                status: .logged, statusChangedAt: nil
            ),
            GuardEvent(
                id: 903, kind: .code, level: .warning, at: now.addingTimeInterval(-26 * 3_600),
                title: L("Проверил 12 файлов в pingbot — 1 место стоит глянуть", "Checked 12 files in pingbot — 1 spot worth a look"),
                detail: "scripts/build.js:1 — child_process", allowKey: nil, status: .logged, statusChangedAt: nil
            ),
        ]
    }

    private var guardAudit: [AuditFinding] {
        let home = NSHomeDirectory()
        return ClaudeConfigAudit.audit([
            ClaudeConfigFile(path: home + "/work/notely/.claude/settings.local.json", kind: .projectLocalSettings,
                             content: #"{ "permissions": { "allow": ["Bash(git push:*)"] } }"#, inGit: false),
        ])
    }

    // MARK: - Советы

    private static var tips: [ReviewTip] {
        [
            ReviewTip(
                title: L("Touch ID вместо пароля для sudo", "Touch ID instead of a password for sudo"),
                observation: L("6 переключений SecurityAgent ↔ Терминал и 3 копирования из Терминала в окно SecurityAgent. Похоже, ты вводишь пароль руками.",
                               "6 switches SecurityAgent ↔ Terminal and 3 copies from Terminal into the SecurityAgent window. Looks like you type the password by hand."),
                suggestion: L("Включи Touch ID: `sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local` и раскомментируй строку `auth sufficient pam_tid.so`.",
                              "Turn on Touch ID: `sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local` and uncomment the line `auth sufficient pam_tid.so`."),
                effort: TipEffort.low.word, timeSavedPerWeekMin: 10, toolHint: "pam_tid"
            ),
            ReviewTip(
                title: L("API-ключ в Связке ключей, а не в буфере", "Keep the API key in Keychain, not the clipboard"),
                observation: L("16 заходов на platform.claude.com и 3 копирования Arc → Терминал. Похоже, ты переносишь ключ руками.",
                               "16 visits to platform.claude.com and 3 copies Arc → Terminal. Looks like you move the key by hand."),
                suggestion: L("Сохрани ключ один раз: `security add-generic-password -a $USER -s anthropic_api_key -w`. В **~/.zshrc** добавь экспорт из Связки ключей.",
                              "Save the key once: `security add-generic-password -a $USER -s anthropic_api_key -w`. In **~/.zshrc**, export it from Keychain."),
                effort: TipEffort.low.word, timeSavedPerWeekMin: 10, toolHint: "zsh + security"
            ),
        ]
    }
}
