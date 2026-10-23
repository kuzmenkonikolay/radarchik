import AppKit
import SwiftUI
import RadarchikCore

/// Вкладка «Защита» (SPEC §3б) — всё, что раньше было в терминале у guard:
/// - ключи по категориям: закрыты ли и сколько осталось до автозакрытия;
/// - кто пользовался SSH-ключом;
/// - процессы за сутки;
/// - проверка кода после git pull и подключены ли хуки;
/// - настройки Claude Code.
/// Что с ключами сейчас — говорит облачко; тревога, которая ждёт ответа, —
/// тоже в нём, с кнопками.
///
/// Открывает ключи root-часть Радарчика (этап 2): «Открыть» → окно Touch ID,
/// которое показывает и проверяет она сама. Пока root-части нет — вкладка
/// подсказывает, как её поставить, а открывает старый `sudo guard`.
struct ProtectionTab: View {
    let protection: GuardMonitor
    @Bindable var settings: AppSettings

    var body: some View {
        FitOrScroll(maxHeight: 560) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                KeysGroup(protection: protection)
                keyUses
                processes
                code
                if settings.guardAuditClaude { claude }
            }
        }
        // Root-часть могли поставить или переставить, пока вкладка была закрыта.
        .task { protection.checkHelper() }
    }

    // MARK: - Кто пользовался SSH-ключом

    /// Слежка за ssh-agent: последние входы и подписи за сутки, с цепочкой «кто кого запустил».
    private var keyUses: some View {
        let events = protection.recent.filter { $0.kind == .agent }
        return VStack(alignment: .leading, spacing: 6) {
            PanelGroup(L("Кто пользовался SSH-ключом", "Who used the SSH key")) {
                if protection.agentWatching {
                    SettingRow(
                        L("Слежу за ssh-agent", "Watching ssh-agent"),
                        detail: protection.canConfirm
                            ? L("Вижу каждый вход и подпись; скриптам, приложениям и Claude Code ключ даю только по Touch ID",
                                "I see every login and signature; scripts, apps and Claude Code get the key only via Touch ID")
                            : L("Вижу каждый вход и каждую подпись из терминала", "I see every login and signature from the terminal"),
                        icon: "eye"
                    ) { EmptyView() }
                    if events.isEmpty {
                        EventRow(text: L("За сутки ключом не пользовались", "The key wasn’t used in the last 24 hours"), time: nil, level: .info, status: nil)
                    } else {
                        ForEach(events.prefix(5)) { event in
                            EventRow(text: event.title, time: event.at, level: event.level, status: event.status, secondary: event.detail)
                        }
                    }
                } else {
                    SettingRow(
                        L("Не слежу за ключом", "Not watching the key"),
                        detail: L("Не нашёл ssh-agent: у Радарчика нет SSH_AUTH_SOCK", "Couldn’t find ssh-agent: Radarchik has no SSH_AUTH_SOCK"),
                        icon: "eye.slash"
                    ) { EmptyView() }
                }
            }
            if protection.agentWatching {
                Hint(L("Через меня ходят вкладки терминала, открытые после запуска Радарчика. Старые — напрямую, пока их не переоткроешь.",
                       "Terminal tabs opened after Radarchik started go through me. Older ones go straight to the agent until you reopen them."))
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Процессы

    private var processes: some View {
        let events = protection.recent.filter { $0.kind == .process }
        return PanelGroup(L("Процессы", "Processes")) {
            if settings.guardWatchProcesses {
                SettingRow(
                    L("Слежу за процессами", "Watching processes"),
                    detail: L("node -e, python -c, curl | sh, запуск из временных папок — раз в 2 секунды",
                              "node -e, python -c, curl | sh, launches from temp folders — every 2 seconds"),
                    icon: "eye"
                ) { EmptyView() }
                if events.isEmpty {
                    EventRow(text: L("За сутки ничего подозрительного", "Nothing suspicious in the last 24 hours"), time: nil, level: .info, status: nil)
                } else {
                    ForEach(events.prefix(4)) { EventRow(event: $0) }
                }
            } else {
                ToggleRow(
                    L("Следить за процессами", "Watch processes"),
                    detail: L("Выключено", "Off"),
                    isOn: Binding(get: { settings.guardWatchProcesses }, set: { protection.setWatchProcesses($0) })
                )
            }
        }
    }

    // MARK: - Проверка кода

    private var code: some View {
        PanelGroup(L("Проверка кода", "Code checks")) {
            if protection.hooksConnected {
                SettingRow(
                    L("Git-хуки подключены", "Git hooks are on"),
                    detail: L("Проверяю код после git pull, checkout и clone", "I check code after git pull, checkout and clone"),
                    icon: "checkmark.seal"
                ) { EmptyView() }
            } else {
                HooksRow()
            }
            ForEach(protection.scans) { EventRow(event: $0) }
        }
    }

    // MARK: - Claude Code

    private var claude: some View {
        PanelGroup("Claude Code") {
            if protection.audit.isEmpty {
                EventRow(text: L("В настройках ничего опасного", "Nothing dangerous in the settings"), time: nil, level: .info, status: nil)
            } else {
                ForEach(protection.audit.sorted { $0.level > $1.level }.prefix(5)) { finding in
                    EventRow(
                        text: GuardPhrase.auditText(finding), time: nil, level: finding.level, status: nil,
                        secondary: ShellRedactor.shortenHome(finding.path, home: NSHomeDirectory())
                    )
                }
            }
        }
    }
}

/// Ключи по категориям; по клику — файлы категории. Пока что-то открыто —
/// в заголовке «Закрыть всё». Таймер тикает в строках — отдельный вид,
/// чтобы раз в секунду перерисовывалась только эта группа.
private struct KeysGroup: View {
    let protection: GuardMonitor
    @State private var expanded: Set<GuardCategory> = []

    var body: some View {
        let open = protection.keys.categories.contains(where: \.isOpen)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Spacing.xs) {
                SectionTitle(L("Ключи", "Keys")).padding(.leading, 4)
                Spacer(minLength: 0)
                if open && protection.canUnlock {
                    if protection.inFlight.contains("all") {
                        ProgressView().controlSize(.small)
                    } else {
                        PillButton(L("Закрыть всё", "Lock all"), systemImage: "lock.fill", prominent: true) { protection.lock(nil) }
                    }
                }
            }
            PanelGroup {
                ForEach(protection.keys.categories) { status in
                    CategoryRow(status: status, protection: protection, isExpanded: expanded.contains(status.category)) {
                        withAnimation(.smooth(duration: 0.25)) {
                            if expanded.contains(status.category) {
                                expanded.remove(status.category)
                            } else {
                                expanded.insert(status.category)
                            }
                        }
                    }
                    if expanded.contains(status.category) {
                        ForEach(status.files) { FileRow(file: $0) }
                    }
                }
                if let row = HelperRow(status: protection.helper) { row }
            }
            Hint(hint).padding(.horizontal, 4)
        }
    }

    private var hint: String {
        if protection.canUnlock {
            return L("Открыть — Touch ID, закроется само. Команды в терминале (git push, rails credentials:edit) спросят Touch ID сами и закроют после себя.",
                     "Open with Touch ID, it locks by itself. Terminal commands (git push, rails credentials:edit) ask for Touch ID themselves and lock afterwards.")
        }
        switch protection.keys.source {
        case .helper:
            return L("Root-часть стоит — как только ответит, здесь появятся кнопки.", "The root part is installed — buttons appear here once it answers.")
        case .legacyGuard:
            return L("Пока открыть можно из терминала: sudo guard unlock ssh.", "For now, open from the terminal: sudo guard unlock ssh.")
        case .builtIn:
            return L("Список встроенный: ssh, aws, kube, gpg и ~/.env.", "Built-in list: ssh, aws, kube, gpg and ~/.env.")
        }
    }
}

/// Строка категории: значок, название, состояние словами, замок, а справа —
/// «Открыть» или «+5 мин» и «Закрыть», если root-часть на месте.
/// По клику на строку — файлы категории.
private struct CategoryRow: View {
    let status: CategoryStatus
    let protection: GuardMonitor
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            // Кнопки действий — рядом, а не внутри: кнопка в кнопке не нажимается.
            Button(action: onToggle) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: status.category.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Ink.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.category.title)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Ink.primary)
                        Text(Typography.bind(detail))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(DS.Ink.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Spacing.xs)
                    Image(systemName: status.isOpen ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status.isOpen ? DS.antenna(.yellow) : DS.Ink.muted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Ink.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if protection.canUnlock { actions }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(hovering ? DS.Surface.rowHover : .clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var actions: some View {
        let name = status.category.rawValue
        if protection.inFlight.contains(name) || protection.inFlight.contains("all") {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else if status.isOpen {
            HStack(spacing: 6) {
                if let closesAt = status.window?.closesAt, closesAt > protection.now {
                    PillButton(L("+5 мин", "+5 min")) { protection.extend(status.category) }
                        .help(L("Ещё 5 минут от сейчас — снова Touch ID", "5 more minutes from now — Touch ID again"))
                }
                PillButton(L("Закрыть", "Lock"), systemImage: "lock.fill") { protection.lock(status.category) }
            }
        } else {
            UnlockButton(category: status.category, protection: protection)
        }
    }

    /// «3 файла · закрыты», «открыты · ещё 4:12», «1 из 3 открыт · в git: 1».
    private var detail: String {
        let guarded = status.guarded.count
        let files = Words.plural(guarded, ru: ("файл", "файла", "файлов"), en: ("file", "files"))
        var parts: [String] = []
        if !status.isOpen {
            parts.append(L("\(guarded) \(files) · закрыты", "\(guarded) \(files) · locked"))
        } else if status.openFiles.count == guarded {
            parts.append("\(guarded) \(files) · " + openState)
        } else {
            parts.append(L("\(status.openFiles.count) из \(guarded) открыты", "\(status.openFiles.count) of \(guarded) open") + " · " + openState)
        }
        let inGit = status.files.count - guarded
        if inGit > 0 { parts.append(L("в git: \(inGit), не закрываю", "in git: \(inGit), not locking")) }
        return parts.joined(separator: " · ")
    }

    private var openState: String {
        let now = protection.now
        guard let window = status.window else { return L("не закрыты", "not locked") }
        guard let closesAt = window.closesAt else { return L("открыты вручную", "opened manually") }
        if closesAt > now { return L("ещё \(GuardWing.clock(closesAt.timeIntervalSince(now)))", "\(GuardWing.clock(closesAt.timeIntervalSince(now))) left") }
        return L("открыты дольше таймера", "open past the timer")
    }
}

/// «Открыть» — на 5 минут, «⌄» рядом — на сколько: 15 минут, час, до ручной блокировки.
private struct UnlockButton: View {
    let category: GuardCategory?
    let protection: GuardMonitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            PillButton(L("Открыть", "Open"), systemImage: "touchid") { protection.unlock(category) }
                .help(L("На 5 минут — Touch ID", "For 5 minutes — Touch ID"))
            Menu {
                Button(L("На 5 минут", "For 5 minutes")) { protection.unlock(category, minutes: 5) }
                Button(L("На 15 минут", "For 15 minutes")) { protection.unlock(category, minutes: 15) }
                Button(L("На час", "For an hour")) { protection.unlock(category, minutes: 60) }
                Divider()
                Button(L("До ручной блокировки", "Until I lock it")) { protection.unlock(category, minutes: 0) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? DS.Ink.primary : DS.Ink.secondary)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help(L("На сколько открыть", "How long to open"))
        }
    }
}

/// Root-части нет, она старая или молчит — что делать, одной командой с кнопкой «Скопировать».
struct HelperRow: View {
    let title: String
    let detail: String
    let command: String
    @State private var copied = false

    /// nil — root-часть на месте (или ещё не проверяли): строка не нужна.
    init?(status: GuardMonitor.HelperStatus) {
        // В тексте дефис неразрывный: «install-guard» не должен переноситься.
        // Копируется настоящая команда — `command`.
        let make = "make install\u{2011}guard"
        switch status {
        case .notInstalled:
            title = L("Открывать по Touch ID", "Open with Touch ID")
            detail = L("Один раз поставь root-часть: \(make) в папке Радарчика", "Install the root part once: \(make) in the Radarchik folder")
            command = "make install-guard"
        case .outdated(let version):
            title = L("Обнови root-часть", "Update the root part")
            detail = L("Стоит версия \(version), нужна \(GuardHelper.version): \(make)", "Version \(version) is installed, \(GuardHelper.version) is needed: \(make)")
            command = "make install-guard"
        case .unreachable:
            title = L("Root-часть не отвечает", "The root part isn’t responding")
            detail = L("Перезапусти её этой командой в терминале", "Restart it with this terminal command")
            command = "sudo launchctl kickstart -k system/\(GuardHelper.label)"
        case .unknown, .ready:
            return nil
        }
    }

    var body: some View {
        SettingRow(title, detail: detail, icon: "touchid") {
            PillButton(copied ? L("Готово", "Copied") : L("Скопировать", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .help(command)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Файл категории: путь от домашней папки и чей он сейчас.
private struct FileRow: View {
    let file: ProtectedFile

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.inGit ? "arrow.triangle.branch" : file.state == .locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(file.state == .locked || file.inGit ? DS.Ink.muted : DS.antenna(.yellow))
                .frame(width: 14)
            Text(ShellRedactor.shortenHome(file.path, home: NSHomeDirectory()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Spacing.xs)
            Text(state)
                .font(.system(size: 11))
                .foregroundStyle(DS.Ink.muted)
        }
        .padding(.leading, 42)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .help(file.inGit ? L("Файл в git: он и так есть в истории, а закрытым git видит его изменённым", "This file is in git: it’s in the history anyway, and git sees it as modified when locked") : "")
    }

    private var state: String {
        if file.inGit { return L("в git", "in git") }
        switch file.state {
        case .locked: return L("закрыт", "locked")
        case .open: return L("открыт", "open")
        case .foreign: return L("чужой", "foreign")
        }
    }
}

/// Хуки не подключены: одна команда, которую человек вставит в терминал сам.
private struct HooksRow: View {
    @State private var copied = false

    var body: some View {
        SettingRow(
            L("Git-хуки не подключены", "Git hooks are off"),
            detail: L("Вставь команду в терминал — и проверю код после git pull", "Paste the command in a terminal, and I’ll check code after git pull"),
            icon: "exclamationmark.circle"
        ) {
            PillButton(copied ? L("Готово", "Copied") : L("Скопировать", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(GitHooks.connectCommand, forType: .string)
                copied = true
            }
            .help(GitHooks.connectCommand)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Запись журнала: время, фраза, что с ней стало. Опасное — со значком, не только цветом.
struct EventRow: View {
    let text: String
    let time: Date?
    let level: GuardLevel
    let status: GuardEventStatus?
    /// Вторая строка мельче — например, путь к файлу настроек.
    var secondary: String?

    init(text: String, time: Date?, level: GuardLevel, status: GuardEventStatus?, secondary: String? = nil) {
        self.text = text
        self.time = time
        self.level = level
        self.status = status
        self.secondary = secondary
    }

    init(event: GuardEvent) {
        self.init(text: event.title, time: event.at, level: event.level, status: event.status)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            if let time {
                Text(Self.time(time))
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.muted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DS.Ink.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            if let status, let word = Self.word(status) {
                Text(word).foregroundStyle(DS.Ink.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// «12:05» сегодня, «вчера, 10:06», дальше «17 окт., 10:06» — без года.
    private static func time(_ date: Date) -> String {
        let clock = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return clock }
        if Calendar.current.isDateInYesterday(date) { return L("вчера, ", "yesterday, ") + clock }
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", " + clock
    }

    private var icon: String {
        switch level {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "checkmark.circle"
        }
    }

    private var color: Color {
        switch level {
        case .critical: DS.antenna(.orange)
        case .warning: DS.antenna(.yellow)
        case .info: DS.Ink.muted
        }
    }

    private static func word(_ status: GuardEventStatus) -> String? {
        switch status {
        case .active: L("ждёт ответа", "waiting")
        case .killed: L("убит", "killed")
        case .allowedOnce: L("разрешил раз", "allowed once")
        case .allowedAlways: L("разрешил всегда", "always allowed")
        case .dismissed: L("понятно", "got it")
        case .resolved: L("прошло само", "went away")
        case .logged: nil
        }
    }
}
