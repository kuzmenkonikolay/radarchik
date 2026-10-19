import SwiftUI
import RadarchikCore

/// Экран «Наблюдение»: включить или выключить, что пишется и что нет,
/// разрешения macOS, подключение терминала, исключения. Здесь же переход
/// к «Что записано сегодня».
struct ObservationView: View {
    let model: NotchViewModel
    let tracker: ActivityTracker
    @Bindable var settings: AppSettings

    @State private var newDomain = ""
    @State private var copied = false
    @FocusState private var domainFocused: Bool
    /// Исключений много (пароли, банки) — по умолчанию свёрнуты в одну строку.
    @State private var showsExclusions = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Наблюдение", "Activity tracking"), onBack: { model.pop() })
            FitOrScroll(maxHeight: 600) { content }
        }
        // Браузеры показываем сразу, даже пока наблюдение выключено.
        .task { tracker.refreshAutomation() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            mainSwitch
            privacy
            permissions
            terminal
            exclusions
            PillButton(L("Что записано сегодня", "What’s logged today"), systemImage: "list.bullet.rectangle") { model.push(.today) }
        }
    }

    // MARK: - Главный переключатель

    /// Крупно и с подписью: маленький тумблер в заголовке легко не заметить (скриншот 2026-10-18).
    private var mainSwitch: some View {
        let isOn = settings.observationEnabled
        return HStack(spacing: DS.Spacing.sm) {
            Image(systemName: isOn ? "eye" : "eye.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? DS.Money.positiveText : DS.Ink.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(isOn ? L("Наблюдение включено", "Activity tracking is on") : L("Наблюдение выключено", "Activity tracking is off"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Ink.primary)
                Text(isOn
                    ? L("Записываю день — из него будут советы.", "Logging the day — tips will come from it.")
                    : L("Ничего не пишу, только замечаю звонки, чтобы прятать цифры.", "Logging nothing, only noticing calls to hide the numbers."))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Ink.secondary)
            }
            Spacer(minLength: DS.Spacing.xs)
            Toggle(isOn: Binding(
                get: { settings.observationEnabled },
                set: { tracker.setEnabled($0) }
            )) { EmptyView() }
            .toggleStyle(.panel)
            .accessibilityLabel(L("Наблюдать", "Track activity"))
        }
        .padding(DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .fill(DS.Surface.card)
                .stroke(isOn ? DS.Surface.hairline : DS.antenna(.yellow).opacity(0.6))
        )
    }

    // MARK: - Что пишу и что нет

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hint(L("Пишу: приложения и время в них, заголовки окон, адреса вкладок без параметров, команды терминала без секретов, факт копирования, время звонков, запуск приложений.",
                   "Logged: apps and time in them, window titles, tab addresses without parameters, terminal commands without secrets, the fact of copying, call time, app launches."))
            Hint(L("Не пишу: экран, нажатия клавиш, содержимое буфера, звук. Ничего из исключений. Всё остаётся на этом маке и хранится 30 дней.",
                   "Never logged: the screen, keystrokes, clipboard contents, audio. Nothing from exclusions. Everything stays on this Mac and is kept for 30 days."))
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))
    }

    // MARK: - Разрешения

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("Доступы", "Permissions"))
            PermissionRow(
                title: L("Заголовки окон", "Window titles"),
                detail: "Accessibility",
                granted: tracker.accessibilityGranted
            ) {
                PillButton(L("Выдать", "Grant")) { tracker.requestAccessibility() }
                PillButton(L("Настройки", "Settings")) { Permissions.openAccessibilitySettings() }
            }
            // Только запущенные браузеры: у незапущенного macOS статус не скажет,
            // а лишние строки (Safari, которым не пользуешься) только путают.
            let running = tracker.automation.filter { $0.value != .notRunning }.keys.sorted { Self.appName($0) < Self.appName($1) }
            ForEach(running, id: \.self) { bundleId in
                let status = tracker.automation[bundleId] ?? .notAsked
                PermissionRow(
                    title: Self.appName(bundleId),
                    detail: Self.automationText(status),
                    granted: status == .granted
                ) {
                    switch status {
                    case .notAsked:
                        PillButton(L("Спросить", "Ask")) { tracker.refreshAutomation(ask: bundleId) }
                    case .denied:
                        PillButton(L("Настройки", "Settings")) { Permissions.openAutomationSettings() }
                    case .granted, .notRunning:
                        EmptyView()
                    }
                }
            }
            Hint(running.isEmpty
                ? L("Открой браузер (Arc, Chrome, Safari) — он появится здесь, и можно будет дать доступ к адресам вкладок.",
                    "Open a browser (Arc, Chrome, Safari) — it will show up here, and you can allow access to tab addresses.")
                : L("Другие браузеры появятся здесь, когда будут запущены.", "Other browsers will show up here once they’re running."))
            if running.contains(where: { Browsers.kind(of: $0) == .safari }) {
                Hint(L("Приватные окна Safari macOS не отличает от обычных. Если ими пользуешься — добавь Safari в исключения.",
                       "macOS can’t tell Safari’s private windows from normal ones. If you use them, add Safari to exclusions."))
            }
        }
    }

    // MARK: - Терминал

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("Терминал", "Terminal"))
            Hint(L("Добавь строку в конец ~/.zshrc и открой новое окно терминала:", "Add this line to the end of ~/.zshrc and open a new terminal window:"))
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Text(ShellHook.sourceLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Ink.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(DS.Surface.field))
                PillButton(copied ? L("Готово", "Copied") : L("Скопировать", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ShellHook.sourceLine, forType: .string)
                    tracker.ignoreOwnPasteboardChange()
                    copied = true
                }
            }
            Hint(tracker.lastCommandAt.map { L("Последняя команда: \(DurationFormat.ago($0)).", "Last command: \(DurationFormat.ago($0)).") }
                ?? L("Команд пока не было. Если строка добавлена, проверь, что наблюдение включено.",
                     "No commands yet. If the line is added, check that activity tracking is on."))
            Hint(L("Команду с пробелом в начале Радарчик не увидит. Выключить на время: export RADARCHIK_OFF=1.",
                   "Radarchik won’t see a command that starts with a space. To pause: export RADARCHIK_OFF=1."))
        }
    }

    // MARK: - Исключения

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("Исключения", "Exclusions"))
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showsExclusions.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Ink.secondary)
                        .frame(width: 18)
                    Text(exclusionsSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Ink.primary)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(showsExclusions ? L("свернуть", "hide") : L("показать", "show"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Ink.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.Ink.muted)
                        .rotationEffect(.degrees(showsExclusions ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsExclusions {
                exclusionLists
            }
        }
    }

    /// «7 приложений и 16 сайтов».
    private var exclusionsSummary: String {
        let apps = settings.excludedApps.count
        let sites = settings.excludedDomains.count
        let appsWord = Words.plural(apps, ru: ("приложение", "приложения", "приложений"), en: ("app", "apps"))
        let sitesWord = Words.plural(sites, ru: ("сайт", "сайта", "сайтов"), en: ("site", "sites"))
        return L("\(apps) \(appsWord) и \(sites) \(sitesWord)", "\(apps) \(appsWord) and \(sites) \(sitesWord)")
    }

    private var exclusionLists: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hint(L("Приложения, из которых не пишу ничего:", "Apps I log nothing from:"))
            FlowLayout(spacing: 6) {
                ForEach(settings.excludedApps.sorted(by: { Self.appName($0) < Self.appName($1) }), id: \.self) { bundleId in
                    RemovableChip(title: Self.appName(bundleId)) { settings.excludedApps.remove(bundleId) }
                }
                Menu {
                    ForEach(Self.runningAppsToExclude(except: settings.excludedApps), id: \.bundleId) { app in
                        Button(app.name) { settings.excludedApps.insert(app.bundleId) }
                    }
                } label: {
                    Label(L("Добавить", "Add"), systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(DS.Ink.secondary)
                .fixedSize()
            }

            Hint(L("Сайты, где пишу только время, без адреса и заголовка:", "Sites where I log only the time, without address or title:"))
            FlowLayout(spacing: 6) {
                ForEach(settings.excludedDomains.sorted(), id: \.self) { domain in
                    RemovableChip(title: domain) { settings.excludedDomains.remove(domain) }
                }
            }
            HStack(spacing: DS.Spacing.xs) {
                PanelTextField(L("например, mybank.ru", "e.g. mybank.com"), text: $newDomain, isFocused: domainFocused)
                    .focused($domainFocused)
                    .frame(width: 220)
                    .onSubmit(addDomain)
                PillButton(L("Добавить", "Add")) { addDomain() }
            }
        }
        .transition(.opacity)
    }

    private func addDomain() {
        // «https://www.MyBank.ru/login» → «mybank.ru».
        let raw = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = Payments.normalizedURL(raw)?.host() ?? raw
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard domain.contains("."), !domain.contains(" ") else { return }
        settings.excludedDomains.insert(domain)
        newDomain = ""
    }

    // MARK: - Названия

    /// Имя установленного приложения, иначе известное имя из списка по умолчанию, иначе bundle id.
    static func appName(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return ObservationRules.knownName(of: bundleId) ?? bundleId
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func automationText(_ status: Permissions.AutomationStatus) -> String {
        switch status {
        case .granted: L("адреса вкладок — есть доступ", "tab addresses — allowed")
        case .notAsked: L("адреса вкладок — ещё не спрашивали", "tab addresses — not asked yet")
        case .denied: L("адреса вкладок — запрещено", "tab addresses — denied")
        case .notRunning: L("запусти браузер, чтобы спросить доступ", "open the browser to ask for access")
        }
    }

    private struct RunningApp {
        let bundleId: String
        let name: String
    }

    private static func runningAppsToExclude(except excluded: Set<String>) -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, !excluded.contains(id), id != Bundle.main.bundleIdentifier else { return nil }
                return RunningApp(bundleId: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

/// Строка разрешения: значок-статус, название, пояснение, кнопки.
private struct PermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? DS.Money.positiveText : DS.antenna(.yellow))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Ink.muted)
            }
            Spacer(minLength: DS.Spacing.xs)
            if !granted { actions }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(DS.Surface.card))
    }
}

/// Чип с крестиком — элемент списка исключений.
private struct RemovableChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Ink.muted)
            .help(L("Убрать из исключений", "Remove from exclusions"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(DS.Surface.card))
    }
}
