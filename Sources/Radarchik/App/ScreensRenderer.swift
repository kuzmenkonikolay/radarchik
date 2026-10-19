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
        let world = try PreviewWorld(language: language)
        defer { world.cleanUp() }

        let screens: [(String, [Route])] = [
            ("summary", []),
            ("project", [.project(world.mainProject.id)]),
            ("entry-new", [.entryForm(.new(.recurring, projectId: nil))]),
            ("entry-oneoff", [.entryForm(.new(.oneOff, projectId: world.mainProject.id))]),
            ("entry-edit", [.entryForm(.editRecurring(world.serverId))]),
            ("project-form", [.projectForm(editing: world.mainProject.id)]),
            ("payments", [.payments]),
            ("settings", [.settings]),
            ("observation", [.observation]),
            ("claude", [.claudeSettings]),
            ("prompt", [.reviewPrompt]),
            ("system", [.system(nil)]),
            ("tips", [.tips]),
        ]
        for (name, path) in screens {
            try write(world.panel(path), to: folder.appendingPathComponent("screen-\(name).png"))
        }
        // Свёрнутая чёлка: слева итог месяца, справа процессор и температура.
        try write(world.collapsed(), to: folder.appendingPathComponent("screen-collapsed.png"))
        // Сводка с тревогой о ресурсах вместо фразы о деньгах.
        world.showAlert()
        try write(world.panel([]), to: folder.appendingPathComponent("screen-summary-alert.png"))
    }

    /// Картинки для README (`--render-docs <папка> --language en|ru`): главные
    /// экраны, каждый по высоте своего содержимого.
    static func renderDocs(to folder: URL, language: Language) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let world = try PreviewWorld(language: language)
        defer { world.cleanUp() }
        // Сводка раньше советов: экран советов отмечает их прочитанными.
        let screens: [(String, [Route])] = [
            ("summary", []),
            ("project", [.project(world.mainProject.id)]),
            ("system", [.system(nil)]),
            ("tips", [.tips]),
            ("settings", [.settings]),
        ]
        for (name, path) in screens {
            try write(world.panel(path), to: folder.appendingPathComponent("\(name).png"), tight: true)
        }
        try write(world.collapsed(), to: folder.appendingPathComponent("collapsed.png"), tight: true)
        world.showAlert()
        try write(world.panel([]), to: folder.appendingPathComponent("summary-alert.png"), tight: true)
    }

    /// `tight` — холст по высоте экрана (для README), иначе с запасом под самый длинный.
    private static func write(_ view: some View, to url: URL, tight: Bool = false) throws {
        // «Рабочий стол» под чёлкой — видно границы панели.
        let desk = LinearGradient(colors: [Color(hex: "#3B3F4A"), Color(hex: "#22252C")], startPoint: .top, endPoint: .bottom)
        let content = Group {
            if tight {
                view
                    .padding(.bottom, 28)
                    .frame(width: DS.Size.panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(desk)
            } else {
                ZStack(alignment: .top) {
                    desk
                    view
                }
                // Холст выше окна: длинные экраны (наблюдение) видны целиком.
                .frame(width: DS.Size.panelWidth, height: 1_100)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.unrollsScrolling, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw MascotSheetRenderer.Failure(description: "not rendered: \(url.lastPathComponent)") }
        try data.write(to: url)
    }
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
    let model: NotchViewModel
    let mainProject: Project
    let serverId: UUID

    private static let suite = "dev.kuzmenko.radarchik.screens"
    private let gib = 1_073_741_824.0
    private let now = Date()

    init(language: Language) throws {
        let defaults = UserDefaults(suiteName: Self.suite) ?? .standard
        defaults.removePersistentDomain(forName: Self.suite)
        settings = AppSettings(defaults: defaults)
        // Язык — до данных: из него названия, валюта и советы.
        settings.languageChoice = language == .ru ? .ru : .en
        settings.observationEnabled = true
        settings.showNumbersWhenCollapsed = true

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
        model = NotchViewModel(geometry: NotchGeometry(notchRect: CGRect(x: 0, y: 0, width: 220, height: 38), isHardware: true))
        resources.preview(state(alerts: []))
    }

    /// Раскрытая панель на нужном экране — тот же `NotchRootView`, что в приложении.
    func panel(_ path: [Route]) -> some View {
        model.collapse()
        model.expand()
        for route in path { model.push(route) }
        return NotchRootView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources)
    }

    /// Свёрнутая чёлка с крыльями.
    func collapsed() -> some View {
        model.collapse()
        return NotchRootView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources)
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
                main: Project(name: "Курсы", colorHex: "#3987E5", currency: .rub),
                side: Project(name: "Бот", colorHex: "#9085E9", currency: .rub),
                server: ("Сервер Selectel", "my.selectel.ru", 1_550_000),
                domain: ("Домен kursy.ru", "reg.ru", 240_000),
                sideServer: ("Hetzner", "console.hetzner.cloud", 450_000),
                mainIncome: ("Подписки", 3_000_000, 450_000, [1_200_000]),
                sideIncome: ("Клиент", 600_000, 100_000),
                ad: ("Реклама в Telegram", 500_000)
            )
        case .en:
            Money(
                main: Project(name: "Notely", colorHex: "#3987E5", currency: .usd),
                side: Project(name: "PingBot", colorHex: "#9085E9", currency: .usd),
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
            period: .monthly, startMonth: month.adding(months: -6), amount: money.server.amount
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
