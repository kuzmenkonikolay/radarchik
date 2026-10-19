import SwiftUI
import RadarchikCore

/// Настройки — группами, как в Системных настройках: название слева,
/// управление справа, переходы со стрелкой. Наблюдение, разбор дня и
/// экран «Система» — на своих экранах.
struct SettingsView: View {
    let model: NotchViewModel
    @Bindable var settings: AppSettings
    let resources: ResourceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Настройки", "Settings"), onBack: { model.pop() })
            FitOrScroll(maxHeight: 600) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    appearance
                    observation
                    resourcesGroup
                    app
                    // Видно, нашёл ли Радарчик настоящий вырез или рисует свой.
                    Hint(notchDescription)
                        .padding(.leading, 4)
                }
            }
        }
    }

    private var appearance: some View {
        PanelGroup(L("Вид", "Appearance")) {
            // Живая чёлка — основной облик, Домовой и Радарчик — запасные.
            SettingRow(L("Облик", "Look")) {
                SegmentedPicker(selection: $settings.mascotSkin, fills: false) { $0.title }
            }
            SettingRow(L("Язык", "Language")) {
                SegmentedPicker(selection: $settings.languageChoice, fills: false) { $0.title }
            }
            ToggleRow(
                L("Цифры по бокам чёлки", "Numbers beside the notch"),
                detail: L("Слева итог месяца, справа процессор и температура", "Month’s net on the left, CPU and temperature on the right"),
                isOn: $settings.showNumbersWhenCollapsed
            )
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
                detail: L("Процессор, память, батарея и температура", "CPU, memory, battery and temperature"),
                isOn: Binding(get: { settings.resourcesEnabled }, set: { resources.setEnabled($0) })
            )
            if settings.resourcesEnabled {
                ToggleRow(
                    L("Тревоги ещё и уведомлением", "Also send alerts as notifications"),
                    detail: settings.resourceNotifications && resources.notificationsDenied
                        ? L("Запрещены: Системные настройки → Уведомления", "Blocked: System Settings → Notifications")
                        : L("Кроме записки под чёлкой", "In addition to the note under the notch"),
                    isOn: Binding(get: { settings.resourceNotifications }, set: { resources.setNotifications($0) })
                )
                NavigationRow(L("Экран «Система»", "System screen")) { model.push(.system(nil)) }
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
            NavigationRow(L("Выйти из Радарчика", "Quit Radarchik"), showsChevron: false) { NSApp.terminate(nil) }
        }
    }

    private var notchDescription: String {
        let rect = model.geometry.notchRect
        let size = "\(Int(rect.width))×\(Int(rect.height)) pt"
        return model.geometry.isHardware
            ? L("Чёлка настоящая, \(size).", "Real notch, \(size).")
            : L("Выреза на этом экране нет — рисую виртуальную чёлку по центру, \(size).",
                "This screen has no notch — drawing a virtual one in the center, \(size).")
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
