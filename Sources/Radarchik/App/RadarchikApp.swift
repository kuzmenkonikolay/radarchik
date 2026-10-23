import AppKit
import RadarchikCore

/// Точка входа. Радарчик — accessory-приложение: без иконки в Dock и без
/// своего меню, всё живёт в панели над чёлкой (`NotchController`).
@main
enum RadarchikApp {
    @MainActor
    static func main() {
        // `--codescan post-merge|post-checkout|scan …` — проверка кода из git-хука (SPEC §3б).
        // Раньше всего остального: окну и AppKit здесь делать нечего, git ждёт.
        if let flag = CommandLine.arguments.firstIndex(of: "--codescan") {
            exit(CodeScanCommand.run(Array(CommandLine.arguments.dropFirst(flag + 1))))
        }
        // `--guard-status` — «Защита» одним взглядом, как `guard status`.
        if CommandLine.arguments.contains("--guard-status") {
            exit(GuardStatusCommand.run())
        }
        // `--guard unlock ssh` / `lock` / `status` — как старый guard, но без sudo: Touch ID.
        if let flag = CommandLine.arguments.firstIndex(of: "--guard") {
            exit(GuardCommand.run(Array(CommandLine.arguments.dropFirst(flag + 1))))
        }
        // Отладка: кто пишет в закрытое соединение — стек в ~/Library/Logs/Radarchik/sigpipe.log,
        // а Радарчик не падает (см. `SigpipeTrap`).
        SigpipeTrap.install()
        let app = NSApplication.shared
        // `--render-mascots <папка>` — нарисовать лист чёлки и глаз (PNG и петля GIF) и выйти (без панели).
        if let flag = CommandLine.arguments.firstIndex(of: "--render-mascots") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.temporaryDirectory.path
            finish { try MascotSheetRenderer.render(to: URL(fileURLWithPath: path)) }
        }
        // `--render-screens <папка> [--language en|ru]` — все экраны панели на выдуманных данных, в PNG.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-screens") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.temporaryDirectory.path
            finish { try ScreensRenderer.render(to: URL(fileURLWithPath: path), language: requestedLanguage) }
        }
        // `--render-docs <папка> [--language en|ru]` — главные экраны для README, по высоте содержимого.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-docs") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? "docs"
            finish { try ScreensRenderer.renderDocs(to: URL(fileURLWithPath: path), language: requestedLanguage) }
        }
        // `--render-sting <папка>` — экраны для 12-секундного ролика: прозрачный фон, по-английски, с «Защитой».
        if let flag = CommandLine.arguments.firstIndex(of: "--render-sting") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.temporaryDirectory.path
            finish { try ScreensRenderer.renderSting(to: URL(fileURLWithPath: path)) }
        }
        // `--render-sting-clips <папка>` — живые клипы чёлки и панели для ролика-стинга: PNG, 59.94 к/с, прозрачные.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-sting-clips") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.temporaryDirectory.path
            finish { try StingClips.render(to: URL(fileURLWithPath: path)) }
        }
        // `--render-icon <папка>` — AppIcon.iconset; `--render-social <файл.png>` — превью ссылки.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-icon") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? FileManager.default.temporaryDirectory.path
            finish { try BrandRenderer.renderIcon(to: URL(fileURLWithPath: path)) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-social") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? "social.png"
            finish {
                Language.setAppWide(.en)
                try BrandRenderer.renderSocial(to: URL(fileURLWithPath: path))
            }
        }
        // Ролик: `--render-promo <файл.mp4> [--voice <голос.wav>]`, кадры для проверки: `--promo-frames <папка> --times 1,3.5`,
        // петля для README: `--render-gif <файл.gif>`. Формат — `--format wide|square`.
        if let flag = CommandLine.arguments.firstIndex(of: "--render-promo") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? "radarchik.mp4"
            let voice = CommandLine.arguments.firstIndex(of: "--voice").flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
            finish { try PromoRenderer.renderVideo(to: URL(fileURLWithPath: path), format: requestedFormat, voice: voice.map(URL.init(fileURLWithPath:))) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--promo-frames") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? "frames"
            finish { try PromoRenderer.renderFrames(to: URL(fileURLWithPath: path), format: requestedFormat, times: requestedTimes) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-gif") {
            let path = CommandLine.arguments.dropFirst(flag + 1).first ?? "radarchik.gif"
            finish { try PromoRenderer.renderGIF(to: URL(fileURLWithPath: path)) }
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// `--language en` или `--language ru` для рендеров; без флага — русский, как раньше.
    @MainActor
    private static var requestedLanguage: Language {
        guard let flag = CommandLine.arguments.firstIndex(of: "--language"),
              let value = CommandLine.arguments.dropFirst(flag + 1).first,
              let language = Language(rawValue: value)
        else { return .ru }
        return language
    }

    /// `--format square` — квадратный ролик; по умолчанию широкий.
    @MainActor
    private static var requestedFormat: PromoFormat {
        guard let flag = CommandLine.arguments.firstIndex(of: "--format"),
              let value = CommandLine.arguments.dropFirst(flag + 1).first
        else { return .wide }
        return PromoFormat(rawValue: value) ?? .wide
    }

    /// `--times 1,3.5,10` — какие секунды ролика нарисовать кадрами.
    @MainActor
    private static var requestedTimes: [Double] {
        guard let flag = CommandLine.arguments.firstIndex(of: "--times"),
              let value = CommandLine.arguments.dropFirst(flag + 1).first
        else { return [1, 3.5, 6, 8.6, 12.5, 17, 22, 26] }
        return value.split(separator: ",").compactMap { Double($0) }
    }

    /// Рендер для разработки: выполнить, сказать, где результат, и выйти.
    @MainActor
    private static func finish(_ render: () throws -> Void) -> Never {
        do {
            try render()
            print("Done")
            exit(0)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var tracker: ActivityTracker?
    private var review: ReviewService?
    private var resources: ResourceMonitor?
    private var protection: GuardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Второй экземпляр (запустили ещё раз) — молча выходим, Радарчик уже в чёлке.
        if let bundleId = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count > 1 {
            NSApp.terminate(nil)
            return
        }
        do {
            // Одна база на всё; у денег, наблюдения, советов и ресурсов свои соединения.
            let databasePath = try LedgerRepository.defaultDatabaseURL().path
            let store = try MoneyStore(repository: LedgerRepository(database: Database(path: databasePath)))
            let settings = AppSettings()
            let activity = try ActivityRepository(database: Database(path: databasePath))
            let tracker = ActivityTracker(repository: activity, settings: settings)
            tracker.start()
            let review = ReviewService(
                reviews: try ReviewRepository(database: Database(path: databasePath)),
                activity: activity, settings: settings, tracker: tracker
            )
            review.start()
            // Ресурсы мака (этап 6): замеры и база — в фоновом акторе.
            let resources = ResourceMonitor(worker: try ResourceWorker(databasePath: databasePath), settings: settings, tracker: tracker)
            // «Защита» (SPEC §3б): ключи, процессы, код после git pull, настройки Claude Code.
            let protection = GuardMonitor(worker: try GuardWorker(databasePath: databasePath), settings: settings, tracker: tracker)
            let notch = NotchController(store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
            resources.start()
            protection.start()
            notch.start()
            self.tracker = tracker
            self.review = review
            self.resources = resources
            self.protection = protection
            self.notch = notch
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Радарчик не смог открыть свою базу", "Radarchik couldn’t open its database")
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// Закрываемся: терминал должен снова ходить в ssh-agent напрямую, а не в сокет,
    /// который никто не слушает. Если Радарчик убили (`pkill`), сюда не попадём — тогда
    /// хук сам увидит по метке, что процесса больше нет.
    func applicationWillTerminate(_ notification: Notification) {
        protection?.stopAgentRelay()
    }
}
