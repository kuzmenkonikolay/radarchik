import SwiftUI
import RadarchikCore

/// «Что записано сегодня» — сводка лога с полуночи. Нужна, чтобы проверить,
/// что пишется понятное и без лишнего (критерий готовности этапа 3).
/// Из этой же сводки на этапе 4 будет собираться разбор дня.
struct TodayView: View {
    let model: NotchViewModel
    let tracker: ActivityTracker

    @State private var summary: DaySummary?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Сегодня", "Today"), onBack: { model.pop() }) {
                if let summary, summary.activeSeconds > 0 {
                    Text(L("за компьютером ", "at the computer ") + DurationFormat.short(summary.activeSeconds))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Ink.secondary)
                }
            }
            if let summary {
                if summary.apps.isEmpty && summary.commands.isEmpty && summary.callCount == 0 {
                    Hint(L("Сегодня пока ничего не записано. Включи наблюдение и поработай немного — здесь появятся приложения, сайты и команды.",
                           "Nothing logged today yet. Turn on activity tracking and work for a bit — apps, sites and commands will show up here."))
                } else {
                    FitOrScroll(maxHeight: 600) { sections(summary) }
                }
            }
        }
        .task { summary = tracker.todaySummary() }
    }

    private func sections(_ summary: DaySummary) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if !summary.apps.isEmpty {
                section(L("Приложения", "Apps")) {
                    let top = summary.apps.prefix(8)
                    let longest = top.first?.seconds ?? 1
                    ForEach(Array(top), id: \.bundleId) { app in
                        BarRow(title: app.appName, value: DurationFormat.short(app.seconds), fraction: app.seconds / longest)
                    }
                }
            }
            if !summary.sites.isEmpty {
                section(L("Сайты", "Sites")) {
                    let top = summary.sites.prefix(6)
                    let longest = top.first?.seconds ?? 1
                    ForEach(Array(top), id: \.host) { site in
                        let visits = Words.plural(site.visits, ru: ("заход", "захода", "заходов"), en: ("visit", "visits"))
                        BarRow(
                            title: site.host,
                            value: "\(DurationFormat.short(site.seconds)) · \(site.visits) \(visits)",
                            fraction: site.seconds / longest
                        )
                    }
                }
            }
            if !summary.commands.isEmpty {
                section(L("Команды терминала", "Terminal commands")) {
                    ForEach(Array(summary.commands.prefix(6)), id: \.template) { command in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                            Text(command.template)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DS.Ink.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: DS.Spacing.xs)
                            Text(commandDetail(command))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(DS.Ink.secondary)
                        }
                    }
                }
            }
            if !summary.switches.isEmpty || !summary.pastes.isEmpty {
                section(L("Туда-обратно", "Back and forth")) {
                    ForEach(Array(summary.switches.prefix(3)), id: \.first) { pair in
                        Line(text: "\(pair.first) ↔ \(pair.second)", value: "×\(pair.count)")
                    }
                    ForEach(Array(summary.pastes.prefix(3)), id: \.fromApp) { flow in
                        Line(text: L("копировал: ", "copied: ") + "\(Self.shortName(flow.fromApp)) → \(Self.shortName(flow.toApp))", value: "×\(flow.count)")
                    }
                }
            }
            if summary.callCount > 0 {
                section(L("Звонки", "Calls")) {
                    Line(
                        text: "\(summary.callCount) " + Words.plural(summary.callCount, ru: ("звонок", "звонка", "звонков"), en: ("call", "calls")),
                        value: DurationFormat.short(summary.callSeconds)
                    )
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title)
            content()
        }
    }

    private func commandDetail(_ command: DaySummary.CommandCount) -> String {
        var parts = ["×\(command.count)"]
        if command.totalDurationMs >= 60_000 {
            parts.append(DurationFormat.short(Double(command.totalDurationMs) / 1000))
        }
        if command.failures > 0 {
            parts.append(L("ошибок: ", "failures: ") + "\(command.failures)")
        }
        return parts.joined(separator: " · ")
    }

    /// Bundle id без имени (приложение не попадало в сессии) — показываем последнюю часть.
    private static func shortName(_ name: String) -> String {
        name.contains(".") && !name.contains(" ") ? (name.split(separator: ".").last.map(String.init) ?? name) : name
    }
}

/// Строка с тонкой полоской длины: одна серия, один цвет, значение подписано.
private struct BarRow: View {
    let title: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Spacing.xs) {
                Text(title)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.secondary)
            }
            .font(.system(size: 12))
            Capsule()
                .fill(DS.Chart.bar)
                .frame(height: 4)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: max(min(fraction, 1), 0.02), y: 1, anchor: .leading)
        }
    }
}

private struct Line: View {
    let text: String
    let value: String

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(text)
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.xs)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(DS.Ink.secondary)
        }
        .font(.system(size: 12))
    }
}
