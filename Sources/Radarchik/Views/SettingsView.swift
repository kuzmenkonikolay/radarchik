import SwiftUI
import RadarchikCore

/// Вкладка «Настройки» — группами, как в Системных настройках: название
/// слева, управление справа, переходы со стрелкой. Какая у Радарчика чёлка
/// (настоящая или нарисованная) — говорит облачко.
struct SettingsTab: View {
    let model: NotchViewModel
    @Bindable var settings: AppSettings
    let resources: ResourceMonitor
    let protection: GuardMonitor

    var body: some View {
        FitOrScroll(maxHeight: 440) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                appearance
                observation
                resourcesGroup
                guardGroup
                app
            }
        }
    }

    private var appearance: some View {
        PanelGroup(L("Вид", "Appearance")) {
            SettingRow(L("Язык", "Language")) {
                SegmentedPicker(selection: $settings.languageChoice, fills: false) { $0.title }
            }
            ToggleRow(
                L("Цифры по бокам чёлки", "Numbers beside the notch"),
                detail: L("Слева итог месяца, справа процессор и температура", "Month’s net on the left, CPU and temperature on the right"),
                isOn: $settings.showNumbersWhenCollapsed
            )
            ToggleRow(
                L("Звуки", "Sounds"),
                detail: L("Монетка за доход, звоночек «Пора платить», тревоги погромче, карандаш при записи. Раскрытие беззвучно.",
                          "A coin for income, a chime for “Time to pay”, louder alerts, a pencil on save. Opening is silent."),
                isOn: $settings.soundEnabled
            )
            SettingRow(L("«Пора платить»", "“Time to pay”"), detail: L("За сколько дней до списания напоминать", "How many days before the charge to remind")) {
                ValueStepper(
                    text: Words.plural(settings.payReminderDays, ru: ("\(settings.payReminderDays) день", "\(settings.payReminderDays) дня", "\(settings.payReminderDays) дней"), en: ("\(settings.payReminderDays) day", "\(settings.payReminderDays) days")),
                    minWidth: 64, previousHelp: L("Меньше", "Fewer"), nextHelp: L("Больше", "More"),
                    onPrevious: { settings.payReminderDays = max(settings.payReminderDays - 1, 0) },
                    onNext: { settings.payReminderDays = min(settings.payReminderDays + 1, 14) }
                )
            }
        }
    }

    private var observation: some View {
        PanelGroup(L("Наблюдение и советы", "Activity & tips")) {
            NavigationRow(
                L("Наблюдение", "Activity tracking"), icon: "eye",
                value: settings.observationEnabled ? L("включено", "on") : L("выключено", "off")
            ) {
                model.push(.observation)
            }
            if settings.observationEnabled {
                NavigationRow(L("Сегодня", "Today"), icon: "clock") { model.push(.today) }
            }
            NavigationRow(L("Разбор дня и Claude", "Daily review & Claude"), icon: "sparkles", value: String(format: "%02d:00", settings.reviewHour)) {
                model.push(.claudeSettings)
            }
        }
    }

    private var resourcesGroup: some View {
        // Тумблеры идут через монитор: он запускает замеры и спрашивает macOS
        // о разрешении на уведомления.
        PanelGroup(L("Ресурсы мака", "Mac resources")) {
            ToggleRow(
                L("Следить за ресурсами", "Watch resources"),
                detail: L("Процессор, память, батарея и температура — вкладка «Система»", "CPU, memory, battery and temperature — the System tab"),
                isOn: Binding(get: { settings.resourcesEnabled }, set: { resources.setEnabled($0) })
            )
            if settings.resourcesEnabled {
                ToggleRow(
                    L("Тревоги ещё и уведомлением", "Also send alerts as notifications"),
                    detail: settings.resourceNotifications && resources.notificationsDenied
                        ? L("Запрещены: Системные настройки → Уведомления", "Blocked: System Settings → Notifications")
                        : L("Кроме алерта в чёлке", "In addition to the alert in the notch"),
                    isOn: Binding(get: { settings.resourceNotifications }, set: { resources.setNotifications($0) })
                )
            }
        }
    }

    private var guardGroup: some View {
        // Тумблеры идут через монитор: он запускает проверки и сбрасывает слежку.
        PanelGroup(L("Защита", "Guard")) {
            ToggleRow(
                L("Защита", "Guard"),
                detail: L("Ключи, подозрительные процессы, код после git pull — вкладка «Защита»", "Keys, suspicious processes, code after git pull — the Guard tab"),
                isOn: Binding(get: { settings.guardEnabled }, set: { protection.setEnabled($0) })
            )
            if settings.guardEnabled {
                ToggleRow(
                    L("Следить за процессами", "Watch processes"),
                    detail: L("node -e, python -c, curl | sh и запуск из временных папок", "node -e, python -c, curl | sh, and launches from temp folders"),
                    isOn: Binding(get: { settings.guardWatchProcesses }, set: { protection.setWatchProcesses($0) })
                )
                ToggleRow(
                    L("Сетевой надзор", "Network watch"),
                    detail: L("Куда ходят скрипты, которые запустил не ты, и команды Claude Code — экран «Сеть»",
                              "Where scripts you didn’t start and Claude Code commands go — the Network screen"),
                    isOn: Binding(get: { settings.guardWatchNetwork }, set: { protection.setWatchNetwork($0) })
                )
                ToggleRow(
                    L("Проверять настройки Claude Code", "Check Claude Code settings"),
                    detail: L("Разрешения и хуки, пришедшие из чужих репозиториев", "Permissions and hooks that came from other people’s repositories"),
                    isOn: Binding(get: { settings.guardAuditClaude }, set: { protection.setAuditClaude($0) })
                )
            }
        }
    }

    private var app: some View {
        PanelGroup(L("Приложение", "App")) {
            ToggleRow(
                L("Запускать при входе в систему", "Open at login"),
                detail: settings.launchAtLoginError,
                isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })
            )
            NavigationRow(L("Выйти из Радарчика", "Quit Radarchik"), icon: "power", showsChevron: false) { NSApp.terminate(nil) }
        }
    }
}

extension LanguageChoice {
    /// Свои языки — своими словами, как в macOS: «English» и по-русски, и по-английски.
    var title: String {
        switch self {
        case .system: L("Как в системе", "System")
        case .ru: "Русский"
        case .en: "English"
        }
    }
}
