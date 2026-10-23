import SwiftUI
import RadarchikCore

/// Экран «Сеть» — «Сетевой надзор» (SPEC §3б, 2026-10-22). Узкое наблюдение за тем,
/// куда ходят скрипты, которые запустил не ты (postinstall под npm, всё под Claude Code),
/// и инструменты ИИ-агентов. Не файрвол: соединение не придерживаем — это умеет LuLu, —
/// но видим за секунду, с цепочкой запуска, и можем убить процесс. Что видели за сутки —
/// по проектам. Захват делает root-часть (pktap), без неё экран подсказывает `make install-guard`.
struct NetworkTab: View {
    let model: NotchViewModel
    let protection: GuardMonitor
    @Bindable var settings: AppSettings

    var body: some View {
        FitOrScroll(maxHeight: 560) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                watch
                seen
                Hint(L("Соединение не придерживаю: первый пакет уже ушёл. Вижу за секунду, с цепочкой запуска, и могу убить процесс. Спросить до коннекта умеет LuLu.",
                       "I don’t hold the connection: the first packet is already out. I see it within a second, with the launch chain, and can kill the process. Asking before the connection is LuLu’s job."))
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Что заметили

    private var watch: some View {
        let events = protection.network.events
        return PanelGroup(L("Скрипты и агенты в сети", "Scripts and agents online")) {
            if let row = HelperRow(status: protection.helper) {
                row
            } else if let error = protection.networkError {
                SettingRow(L("Захват не идёт", "Capture isn’t running"), detail: error, icon: "exclamationmark.triangle") { EmptyView() }
            } else if protection.networkWatching {
                SettingRow(
                    L("Слежу за сетью", "Watching the network"),
                    detail: L("Новые адреса у скриптов под npm, у команд Claude Code и у всего, что запустил не ты. Твои команды и приложения — это LuLu",
                              "New addresses for scripts under npm, Claude Code commands and anything you didn’t start. Your own commands and apps are LuLu’s"),
                    icon: "eye"
                ) { EmptyView() }
            } else {
                SettingRow(L("Включаю", "Starting"), detail: L("Первый ответ root-части — через пару секунд", "The root part answers in a couple of seconds"), icon: "eye") {
                    EmptyView()
                }
            }
            if events.isEmpty {
                EventRow(text: L("За сутки ничего нового", "Nothing new in the last 24 hours"), time: nil, level: .info, status: nil)
            } else {
                ForEach(events.prefix(6)) { event in
                    EventRow(text: event.title, time: event.at, level: event.level, status: event.status, secondary: event.detail)
                }
            }
        }
    }

    // MARK: - Куда ходили

    private var seen: some View {
        let groups = protection.network.groups
        return PanelGroup(L("Куда ходили за сутки", "Where they went today")) {
            if groups.isEmpty {
                EventRow(text: L("Пока никуда", "Nowhere yet"), time: nil, level: .info, status: nil)
            } else {
                ForEach(groups.prefix(6)) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Ink.primary)
                        FlowLayout(spacing: 6) {
                            ForEach(group.hosts.prefix(12)) { item in
                                Chip(
                                    text: item.host + (item.count > 1 ? " ×\(item.count)" : ""),
                                    systemImage: item.level == .critical ? "exclamationmark.triangle.fill" : nil,
                                    background: Self.chipBackground(item.level), foreground: Self.chipForeground(item.level)
                                )
                                .help(item.name + " · " + L("впервые", "first seen") + " " + item.firstSeen.formatted(date: .omitted, time: .shortened))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private static func chipBackground(_ level: GuardLevel) -> Color {
        switch level {
        case .critical: DS.Tone.alarm.opacity(0.18)
        case .warning: DS.Tone.tips.opacity(0.18)
        case .info: DS.Surface.chip
        }
    }

    private static func chipForeground(_ level: GuardLevel) -> Color {
        switch level {
        case .critical: DS.Tone.alarm
        case .warning: DS.Tone.tips
        case .info: DS.Ink.primary
        }
    }
}
