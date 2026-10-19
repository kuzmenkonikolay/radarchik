import Foundation
import Observation
import ServiceManagement
import RadarchikCore

/// Настройки в UserDefaults: язык, деньги, облик, наблюдение (этап 3), разбор дня (этап 4),
/// ресурсы мака (этап 6). Ключ Claude — не здесь, а в Связке ключей.
@MainActor
@Observable
final class AppSettings {
    /// Язык интерфейса (решение 2026-10-19): по умолчанию как в системе —
    /// русская система даёт русский, любая другая английский.
    var languageChoice: LanguageChoice {
        didSet {
            defaults.set(languageChoice.rawValue, forKey: Key.language)
            Language.setAppWide(language)
        }
    }
    /// Язык, на котором Радарчик говорит сейчас.
    var language: Language { languageChoice.resolved() }

    /// Цифры по бокам свёрнутой чёлки: слева деньги («к оплате», итог месяца),
    /// справа система (процессор, температура). По умолчанию выключено.
    var showNumbersWhenCollapsed: Bool {
        didSet { defaults.set(showNumbersWhenCollapsed, forKey: Key.showNumbers) }
    }
    private(set) var launchAtLogin: Bool
    var launchAtLoginError: String?

    /// Облик маскота (этап 5). Финальный — Живая чёлка, Домовой и Радарчик — запасные.
    var mascotSkin: MascotSkin {
        didSet { defaults.set(mascotSkin.rawValue, forKey: Key.mascotSkin) }
    }

    // MARK: - Наблюдение (этап 3)

    /// Пока выключено, Радарчик ничего не пишет, только замечает звонки, чтобы прятать цифры.
    var observationEnabled: Bool {
        didSet { defaults.set(observationEnabled, forKey: Key.observationEnabled) }
    }
    /// Bundle id приложений, из которых не пишем ничего.
    var excludedApps: Set<String> {
        didSet { defaults.set(excludedApps.sorted(), forKey: Key.excludedApps) }
    }
    /// Домены, на которых не пишем адрес и заголовок (поддомены тоже).
    var excludedDomains: Set<String> {
        didSet { defaults.set(excludedDomains.sorted(), forKey: Key.excludedDomains) }
    }

    // MARK: - Разбор дня (этап 4)

    /// Час разбора по часам компьютера (решение 2026-10-18: 22:00).
    var reviewHour: Int {
        didSet { defaults.set(reviewHour, forKey: Key.reviewHour) }
    }
    var claudeModel: ClaudeModel {
        didSet { defaults.set(claudeModel.rawValue, forKey: Key.claudeModel) }
    }
    /// Отправлять ли в Claude заголовки окон (самые долгие). Без них советы беднее, но приватнее.
    var sendWindowTitles: Bool {
        didSet { defaults.set(sendWindowTitles, forKey: Key.sendWindowTitles) }
    }
    /// Прокси для Claude API. Пусто — напрямую (решение 2026-10-19); с адресом
    /// запросы идут только через него (SPEC §5).
    var proxyAddress: String {
        didSet { defaults.set(proxyAddress, forKey: Key.proxyAddress) }
    }
    /// Последний разбор или осознанный пропуск (слишком тихий день) — от него считается «пора».
    var lastReviewAttemptAt: Date? {
        didSet { defaults.set(lastReviewAttemptAt, forKey: Key.lastReviewAttemptAt) }
    }
    /// Когда последний раз открывал советы: что новее — «новые».
    var tipsSeenAt: Date? {
        didSet { defaults.set(tipsSeenAt, forKey: Key.tipsSeenAt) }
    }

    // MARK: - Ресурсы мака (этап 6)

    /// Следить за процессором, памятью, батареей и температурой. По умолчанию включено:
    /// замер раз в 5 секунд почти ничего не стоит.
    var resourcesEnabled: Bool {
        didSet { defaults.set(resourcesEnabled, forKey: Key.resourcesEnabled) }
    }
    /// Дублировать тревоги уведомлением macOS. По умолчанию выключено: хватает чёлки.
    var resourceNotifications: Bool {
        didSet { defaults.set(resourceNotifications, forKey: Key.resourceNotifications) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Прокси стал необязательным (2026-10-19). Один раз переносим старое
        // поведение: кто уже пользовался Радарчиком, получает прежний адрес явно
        // и дальше ходит только через прокси. Должно идти до любой записи
        // в настройки — иначе новая установка покажется старой.
        if !defaults.bool(forKey: Key.proxyOptionalMigrated) {
            let isExistingInstall = [Key.livingNotchChosen, Key.mascotSkin, Key.showNumbers, Key.proxyAddress, Key.observationEnabled]
                .contains { defaults.object(forKey: $0) != nil }
            let proxy = ClaudeRoute.migratedProxySetting(stored: defaults.string(forKey: Key.proxyAddress), isExistingInstall: isExistingInstall)
            defaults.set(proxy, forKey: Key.proxyAddress)
            defaults.set(true, forKey: Key.proxyOptionalMigrated)
        }
        self.languageChoice = defaults.string(forKey: Key.language).flatMap(LanguageChoice.init(rawValue:)) ?? .system
        self.showNumbersWhenCollapsed = defaults.bool(forKey: Key.showNumbers)
        // Живую чёлку выбрали финальной 2026-10-18. Один раз включаем её,
        // даже если при сравнении последним остался другой облик; дальше — как выберешь.
        if !defaults.bool(forKey: Key.livingNotchChosen) {
            defaults.set(true, forKey: Key.livingNotchChosen)
            defaults.set(MascotSkin.livingNotch.rawValue, forKey: Key.mascotSkin)
        }
        self.mascotSkin = defaults.string(forKey: Key.mascotSkin).flatMap(MascotSkin.init(rawValue:)) ?? .livingNotch
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.observationEnabled = defaults.bool(forKey: Key.observationEnabled)
        self.excludedApps = (defaults.stringArray(forKey: Key.excludedApps)).map(Set.init) ?? ObservationRules.defaultExcludedApps
        self.excludedDomains = (defaults.stringArray(forKey: Key.excludedDomains)).map(Set.init) ?? ObservationRules.defaultExcludedDomains
        self.reviewHour = (defaults.object(forKey: Key.reviewHour) as? Int) ?? 22
        self.claudeModel = defaults.string(forKey: Key.claudeModel).flatMap(ClaudeModel.init(rawValue:)) ?? .opus
        self.sendWindowTitles = (defaults.object(forKey: Key.sendWindowTitles) as? Bool) ?? true
        self.proxyAddress = defaults.string(forKey: Key.proxyAddress) ?? ""
        self.lastReviewAttemptAt = defaults.object(forKey: Key.lastReviewAttemptAt) as? Date
        self.tipsSeenAt = defaults.object(forKey: Key.tipsSeenAt) as? Date
        self.resourcesEnabled = (defaults.object(forKey: Key.resourcesEnabled) as? Bool) ?? true
        self.resourceNotifications = defaults.bool(forKey: Key.resourceNotifications)
        // didSet в init не срабатывает — язык ставим сами, до первого экрана.
        Language.setAppWide(language)
    }

    /// Автозапуск через SMAppService. Работает только у собранного .app
    /// (лучше из ~/Applications: `make install`), не у `swift run`.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = L(
                "Не вышло: \(error.localizedDescription). Поставь приложение через make install и попробуй ещё раз.",
                "That didn’t work: \(error.localizedDescription). Install the app with make install and try again."
            )
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private enum Key {
        static let language = "language"
        static let proxyOptionalMigrated = "proxyOptionalMigrated"
        static let showNumbers = "showNumbersWhenCollapsed"
        static let mascotSkin = "mascotSkin"
        static let livingNotchChosen = "livingNotchChosen"
        static let observationEnabled = "observationEnabled"
        static let excludedApps = "excludedApps"
        static let excludedDomains = "excludedDomains"
        static let reviewHour = "reviewHour"
        static let claudeModel = "claudeModel"
        static let sendWindowTitles = "sendWindowTitles"
        static let proxyAddress = "proxyAddress"
        static let lastReviewAttemptAt = "lastReviewAttemptAt"
        static let tipsSeenAt = "tipsSeenAt"
        static let resourcesEnabled = "resourcesEnabled"
        static let resourceNotifications = "resourceNotifications"
    }
}
