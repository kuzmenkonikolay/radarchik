import AppKit
import SwiftUI
import RadarchikCore

/// Экран «Система» (этап 6, SPEC §3а): мак сейчас, график за час, кто больше
/// всех ест и тревоги за сутки. Читает `ResourceMonitor`, а рисует
/// `SystemScreen` — он без моделей, поэтому его рисует и лист картинок.
struct SystemView: View {
    let model: NotchViewModel
    let resources: ResourceMonitor
    let settings: AppSettings
    let focus: SystemFocus?

    @State private var recent: [ResourceAlert] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Система", "System"), onBack: { model.pop() }) {
                PillButton(L("Мониторинг системы", "Activity Monitor"), systemImage: "arrow.up.right") { Self.openActivityMonitor() }
                    .help(L("Там можно закрыть приложение, которое ест слишком много", "Quit an app that uses too much from there"))
            }
            if !settings.resourcesEnabled {
                Hint(L("Слежение за ресурсами выключено. Включить — в настройках.", "Resource watching is off. Turn it on in settings."))
                PillButton(L("Включить", "Turn on"), prominent: true) { resources.setEnabled(true) }
            } else if let system = resources.system {
                SystemScreen(
                    system: system, apps: resources.apps, history: resources.history,
                    recent: recent, normsCount: resources.normsCount, focus: focus
                ) {
                    // Записку видно только у свёрнутой чёлки — сворачиваем и показываем.
                    model.requestCollapse()
                    resources.showExample()
                }
            } else {
                Hint(L("Первый замер — через пару секунд.", "First reading in a couple of seconds."))
            }
        }
        .task(id: resources.alerts.map(\.id)) { recent = await resources.recentAlerts() }
    }

    private static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Сам экран: плитки, вкладки, график, список и тревоги. Только данные на входе.
struct SystemScreen: View {
    let system: SystemSnapshot
    let apps: [AppUsageRow]
    let history: [SystemMinute]
    let recent: [ResourceAlert]
    let normsCount: Int
    var focus: SystemFocus?
    var onExample: () -> Void = {}

    @State private var metric: SystemMetric = .cpu

    init(system: SystemSnapshot, apps: [AppUsageRow], history: [SystemMinute], recent: [ResourceAlert], normsCount: Int, focus: SystemFocus? = nil, onExample: @escaping () -> Void = {}) {
        self.system = system
        self.apps = apps
        self.history = history
        self.recent = recent
        self.normsCount = normsCount
        self.focus = focus
        self.onExample = onExample
        _metric = State(initialValue: focus?.metric ?? .cpu)
    }

    var body: some View {
        FitOrScroll(maxHeight: 600) { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            tiles
            SegmentedPicker(selection: $metric) { $0.title }
                .padding(.top, 4)
            chart
            topApps
            if !recent.isEmpty { alertsList }
            footer
        }
    }

    // MARK: - Плитки «сейчас»

    private var tiles: some View {
        HStack(spacing: DS.Spacing.xs) {
            SystemTile(title: L("Процессор", "CPU"), value: ResourceFormat.percent(system.cpuPercent), detail: L("весь мак", "whole Mac"))
            if let memory = system.memory {
                SystemTile(
                    title: L("Память", "Memory"),
                    value: ResourceFormat.memoryUsage(used: Double(memory.usedBytes), total: Double(memory.totalBytes)),
                    detail: ResourceFormat.pressure(memory.pressure),
                    warning: memory.pressure == .critical
                )
            }
            SystemTile(
                title: L("Температура", "Temperature"),
                value: system.temperature.map(ResourceFormat.temperature) ?? ResourceFormat.thermal(system.thermal),
                detail: system.temperature == nil ? L("датчиков нет", "no sensors") : ResourceFormat.thermal(system.thermal),
                warning: system.thermal >= .serious
            )
            if let battery = system.battery {
                SystemTile(title: L("Батарея", "Battery"), value: "\(Int(battery.level.rounded()))%", detail: batteryDetail(battery))
            }
        }
    }

    private func batteryDetail(_ battery: BatteryReading) -> String {
        if battery.isCharging { return L("заряжается", "charging") }
        if battery.onAC { return L("от сети", "on power") }
        guard let drain = system.drainRate else { return L("считаю…", "measuring…") }
        return "−" + ResourceFormat.drainPerHour(drain)
    }

    // MARK: - График за час

    @ViewBuilder
    private var chart: some View {
        switch metric {
        case .cpu:
            HourChart(
                title: L("Процессор за час", "CPU, last hour"), points: history.map { ($0.start, $0.cpu) }, maxValue: 100,
                format: ResourceFormat.percent
            )
        case .memory:
            let total = Double(system.memory?.totalBytes ?? 0)
            HourChart(
                title: L("Память за час", "Memory, last hour"), points: history.compactMap { minute in minute.memoryUsed.map { (minute.start, $0) } },
                maxValue: max(total, 1), format: ResourceFormat.bytes
            )
        case .energy:
            if system.battery != nil {
                HourChart(
                    title: L("Заряд за час", "Charge, last hour"), points: history.compactMap { minute in minute.batteryLevel.map { (minute.start, $0) } },
                    maxValue: 100, format: { "\(Int($0.rounded()))%" }
                )
            } else {
                Hint(L("Батареи нет — энергия только по приложениям.", "No battery — energy by app only."))
            }
        }
    }

    // MARK: - Кто больше всех ест

    private var topApps: some View {
        let rows = sortedApps.prefix(6)
        let top = rows.first.map(value) ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(L("Сейчас больше всех", "Top right now"))
            ForEach(Array(rows)) { row in
                AppLoadRow(
                    name: row.usage.app.name, value: formatted(value(row)), usual: usual(row).map(formatted),
                    fraction: top > 0 ? value(row) / top : 0, highlighted: row.id == focus?.appKey
                )
            }
        }
    }

    private var sortedApps: [AppUsageRow] {
        apps.sorted { value($0) > value($1) }
    }

    private func value(_ row: AppUsageRow) -> Double {
        switch metric {
        case .cpu: row.usage.cpuPercent
        case .memory: Double(row.usage.memoryBytes)
        case .energy: row.usage.powerWatts
        }
    }

    private func usual(_ row: AppUsageRow) -> Double? {
        switch metric {
        case .cpu: row.usualCPU
        case .memory: row.usualMemory
        case .energy: row.usualPower
        }
    }

    private func formatted(_ value: Double) -> String {
        switch metric {
        case .cpu: ResourceFormat.percent(value)
        case .memory: ResourceFormat.bytes(value)
        case .energy: ResourceFormat.watts(value)
        }
    }

    // MARK: - Тревоги за сутки

    private var alertsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(L("Тревоги за сутки", "Alerts, last 24 hours"))
            ForEach(recent.prefix(4)) { alert in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    Text(alert.createdAt.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                        .foregroundStyle(DS.Ink.muted)
                    Text(alert.title)
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(Self.statusText(alert.status))
                        .foregroundStyle(DS.Ink.secondary)
                }
                .font(.system(size: 11))
            }
        }
    }

    private static func statusText(_ status: AlertStatus) -> String {
        switch status {
        case .active: L("сейчас", "now")
        case .later: L("позже", "later")
        case .normal: L("это нормально", "normal")
        case .resolved: L("прошло само", "went away")
        }
    }

    // MARK: - Подсказка

    private var footer: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            Hint(normsHint)
            Spacer(minLength: DS.Spacing.xs)
            PillButton(L("Пример тревоги", "Sample alert"), action: onExample)
                .help(L("Показать, как Радарчик скажет о перерасходе", "See how Radarchik tells you about overuse"))
        }
    }

    private var normsHint: String {
        let cores = L("У приложения 100% — одно ядро целиком.", "For an app, 100% is one whole core.")
        guard normsCount > 0 else {
            return cores + L(" Нормы копятся неделю: пока их нет, тревожу только при очень большой нагрузке.",
                             " Norms take a week to learn: until then I alert only on very heavy load.")
        }
        let apps = Words.plural(normsCount, ru: ("приложения", "приложений", "приложений"), en: ("app", "apps"))
        return cores + L(" Нормы за неделю есть у \(normsCount) \(apps).", " Weekly norms are learned for \(normsCount) \(apps).")
    }
}

/// Плитка «сейчас»: подпись, крупное значение, пояснение. Тревожное — со значком, не только цветом.
private struct SystemTile: View {
    let title: String
    let value: String
    let detail: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(DS.Ink.muted)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 3) {
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(DS.antenna(.yellow))
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(warning ? DS.Ink.primary : DS.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Surface.card))
    }
}

/// Строка приложения: имя, сколько сейчас и сколько обычно, полоска длины.
/// Одна серия — один цвет; значение подписано, полоска только помогает сравнить.
private struct AppLoadRow: View {
    let name: String
    let value: String
    let usual: String?
    let fraction: Double
    /// С этим приложением открыли экран («Показать» у тревоги).
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Spacing.xs) {
                if highlighted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.antenna(.yellow))
                }
                Text(name)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                if let usual {
                    Text(L("обычно ", "usually ") + usual)
                        .foregroundStyle(DS.Ink.muted)
                }
                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.primary)
            }
            .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
            Capsule()
                .fill(DS.Chart.bar)
                .frame(height: 4)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: max(min(fraction, 1), 0.02), y: 1, anchor: .leading)
        }
        .padding(.vertical, highlighted ? 4 : 0)
        .padding(.horizontal, highlighted ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(highlighted ? DS.Surface.card : .clear))
    }
}

/// График одной величины за последний час: линия 2 pt и лёгкая заливка под ней.
/// Ось времени — ровно час до последнего замера, поэтому пропуски (мак спал) видны.
/// Наведение — вертикальная линия, точка и значение в строке заголовка.
/// Одна серия, поэтому легенды нет: её заменяет заголовок.
struct HourChart: View {
    let title: String
    let points: [(Date, Double)]
    let maxValue: Double
    let format: (Double) -> String

    @State private var width: CGFloat = 0
    @State private var hoverX: CGFloat?
    private let plotHeight: CGFloat = 64

    private struct Placed {
        let at: Date
        let value: Double
        let point: CGPoint
    }

    var body: some View {
        let placed = place(width: width)
        let hovered = hoverX.flatMap { x in placed.min { abs($0.point.x - x) < abs($1.point.x - x) } }
        VStack(alignment: .leading, spacing: 4) {
            readout(hovered ?? placed.last, isHovered: hovered != nil)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(DS.Surface.baseline).frame(height: 1).offset(y: plotHeight - 1)
                if placed.count > 1 {
                    area(placed).fill(DS.Chart.bar.opacity(0.18))
                    line(placed).stroke(DS.Chart.bar, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let hovered {
                    Rectangle().fill(DS.Ink.muted.opacity(0.6)).frame(width: 1, height: plotHeight).offset(x: hovered.point.x)
                    // Точка с кольцом цвета фона — отделяется от линии.
                    Circle()
                        .fill(DS.Chart.bar)
                        .overlay(Circle().stroke(DS.Surface.panel, lineWidth: 2))
                        .frame(width: 8, height: 8)
                        .offset(x: hovered.point.x - 4, y: hovered.point.y - 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: plotHeight)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
            HStack {
                Text(L("час назад", "an hour ago"))
                Spacer()
                Text(L("сейчас", "now"))
            }
            .font(.system(size: 10))
            .foregroundStyle(DS.Ink.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(points.last.map { L("сейчас ", "now ") + format($0.1) } ?? L("нет данных", "no data"))
    }

    /// Строка над графиком: название и значение — последнее или под курсором, со временем точки.
    private func readout(_ shown: Placed?, isHovered: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DS.Ink.muted)
            Spacer(minLength: 0)
            if let shown {
                Text(format(shown.value))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.primary)
                Text(isHovered ? shown.at.formatted(date: .omitted, time: .shortened) : L("сейчас", "now"))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.secondary)
            }
        }
    }

    /// Точки на плоскости: x — время в пределах часа, y — доля от `maxValue`.
    private func place(width: CGFloat) -> [Placed] {
        guard let end = points.last?.0 else { return [] }
        let start = end.addingTimeInterval(-3_600)
        return points.filter { $0.0 >= start }.map { item in
            let x = width * CGFloat(item.0.timeIntervalSince(start) / 3_600)
            let share = CGFloat(min(max(item.1 / max(maxValue, .ulpOfOne), 0), 1))
            return Placed(at: item.0, value: item.1, point: CGPoint(x: x, y: min(plotHeight - plotHeight * share, plotHeight - 1)))
        }
    }

    private func line(_ placed: [Placed]) -> Path {
        var path = Path()
        path.addLines(placed.map(\.point))
        return path
    }

    /// Заливка под линией. Точки — через addLine: `addLines` начал бы новый
    /// подконтур, и заливка замкнулась бы по диагонали клином.
    private func area(_ placed: [Placed]) -> Path {
        var path = Path()
        guard let first = placed.first, let last = placed.last else { return path }
        path.move(to: CGPoint(x: first.point.x, y: plotHeight))
        for item in placed { path.addLine(to: item.point) }
        path.addLine(to: CGPoint(x: last.point.x, y: plotHeight))
        path.closeSubpath()
        return path
    }
}
