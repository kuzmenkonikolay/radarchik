import SwiftUI
import RadarchikCore

/// Экран проекта (C): слева лицо в настроении проекта, шапка «● Название · октябрь»,
/// крупный итог месяца с мини-графиком за полгода и чипом тренда, ниже лента записей
/// «сумма | название | дата». Справа — проекты, выбранный подсвечен.
/// Месяц переключается кликом по столбику мини-графика.
struct ProjectScreen: View {
    let projectId: UUID
    let model: NotchViewModel
    let store: MoneyStore

    @State private var month: YearMonth

    init(projectId: UUID, model: NotchViewModel, store: MoneyStore) {
        self.projectId = projectId
        self.model = model
        self.store = store
        self._month = State(initialValue: store.month)
    }

    var body: some View {
        if let glance = store.glances.first(where: { $0.project.id == projectId }) {
            content(glance)
        } else {
            // Проект удалили или заархивировали — домой.
            Color.clear.frame(height: 1).onAppear { model.home() }
        }
    }

    private func content(_ glance: ProjectGlance) -> some View {
        let project = glance.project
        let report = store.report(for: project, month: month)
        let tone = FaceDirector.tone(glance)
        let available = model.panelWidth - 2 * DS.Spacing.panel - DS.Spacing.cards
        return HStack(alignment: .top, spacing: DS.Spacing.cards) {
            Card(vertical: 18, horizontal: 20) {
                HStack(alignment: .top, spacing: 14) {
                    FaceColumn(face: FaceDirector.project(glance), badge: tone, width: 128)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            CardHeader(dot: tone, title: project.name, subtitle: monthLabel)
                            Spacer(minLength: 0)
                            IconButton(systemImage: "pencil", help: L("Изменить проект", "Edit project")) {
                                model.push(.projectForm(editing: project.id))
                            }
                            .padding(.vertical, -6)
                        }
                        HStack(alignment: .center, spacing: 14) {
                            HeroAmount(amount: report.current.net, currency: project.currency, font: .projectHero)
                            Sparkline(points: store.history(for: project.id, endingAt: max(month, store.month)), selected: month, inProgress: store.month) { month = $0 }
                        }
                        TrendChip(report: report)
                        EntriesList(project: project, month: month, model: model, store: store)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: available * 1.35 / 2.35)
            ProjectsCard(store: store, selected: project.id, onSelect: { id in
                if id != projectId { model.replaceTop(with: .project(id)) }
            }, onAdd: { model.push(.projectForm(editing: nil)) })
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// «октябрь» — текущий; другой год — «май 2025».
    private var monthLabel: String {
        let name = Language.current == .ru ? Words.monthName(month.month).lowercased() : Words.monthName(month.month)
        return month.year == store.month.year ? name : "\(name) \(month.year)"
    }
}

/// Мини-график за 6 месяцев: 68×24, столбики 8 pt через 4, линия нуля. Последний
/// (выбранный) столбик ярче. Клик по столбику — переключить месяц.
struct Sparkline: View {
    let points: [MonthPoint]
    let selected: YearMonth
    var inProgress: YearMonth?
    let onSelect: (YearMonth) -> Void
    @State private var hovered: YearMonth?

    private let barWidth: CGFloat = 8
    private let gap: CGFloat = 4
    private let height: CGFloat = 24

    var body: some View {
        let values = points.map(\.figures.net)
        let maxPositive = max(values.max() ?? 0, 0)
        let maxNegative = max(-(values.min() ?? 0), 0)
        let span = max(maxPositive + maxNegative, 1)
        let zeroY = height * CGFloat(maxPositive) / CGFloat(span)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(DS.Surface.baseline).frame(height: 1).offset(y: min(max(zeroY - 0.5, 0), height - 1))
            HStack(spacing: gap) {
                ForEach(points) { point in
                    bar(point, zeroY: zeroY, span: span)
                }
            }
        }
        .frame(height: height)
        .help(hovered.flatMap { month in points.first { $0.month == month } }.map { Words.monthYear($0.month) } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Итог по месяцам", "Net by month"))
    }

    private func bar(_ point: MonthPoint, zeroY: CGFloat, span: Int64) -> some View {
        let net = point.figures.net
        let isPositive = net >= 0
        let isLast = point.month == selected
        let barHeight = net == 0 ? 1.5 : max(height * CGFloat(net.magnitude) / CGFloat(span), 2)
        let color = isPositive ? (isLast ? DS.Money.positiveBarLast : DS.Money.positiveBar) : (isLast ? DS.Money.negativeBarLast : DS.Money.negativeBar)
        return ZStack(alignment: .top) {
            Color.clear
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color.opacity(point.month == inProgress && !isLast ? 0.5 : 1))
                .frame(width: barWidth, height: barHeight)
                .offset(y: isPositive ? zeroY - barHeight : zeroY)
                .brightness(hovered == point.month ? 0.15 : 0)
        }
        .frame(width: barWidth, height: height)
        .contentShape(Rectangle().inset(by: -2))
        .onHover { inside in
            if inside {
                hovered = point.month
            } else if hovered == point.month {
                hovered = nil
            }
        }
        .onTapGesture { onSelect(point.month) }
    }
}

/// Чип тренда: «⌄ −46% к сентябрю», цвет по тренду, фон α 0.14.
struct TrendChip: View {
    let report: ProjectReport

    var body: some View {
        let previous = report.month.previous.month
        let suffix = L("к \(RussianWords.monthDative(previous))", "vs \(Words.monthName(previous))")
        if let growth = report.growthPercent {
            let color: Color = growth >= 0 ? DS.Tone.plus : DS.Tone.tips
            Chip(
                text: MoneyFormat.percent(growth) + " " + suffix,
                systemImage: growth >= 0 ? "chevron.up" : "chevron.down",
                background: color.opacity(0.14), foreground: color, bold: true
            )
        } else {
            Chip(text: L("первый месяц", "first month"), background: DS.Surface.chip, foreground: DS.Ink.secondary)
        }
    }
}

/// Лента записей проекта за месяц: «64 | название | дата». Доходы с плюсом
/// зелёные, траты обычным текстом, дата серым. Клик — правка.
struct EntriesList: View {
    let project: Project
    let month: YearMonth
    let model: NotchViewModel
    let store: MoneyStore

    /// Одна строка ленты.
    struct Line: Identifiable {
        let id: String
        let amount: Int64
        let title: String
        let date: LocalDate
        let route: Route
        var dimmed: Bool
    }

    var body: some View {
        let lines = lines()
        if lines.isEmpty {
            Hint(L("Пока пусто. Заведи регулярную трату один раз — дальше она начисляется сама.",
                   "Nothing here yet. Add a recurring cost once — it accrues by itself from then on."))
        } else {
            FitOrScroll(maxHeight: 190) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        EntryLine(line: line, currency: project.currency) { model.push(line.route) }
                    }
                }
            }
        }
    }

    private func lines() -> [Line] {
        let today = LocalDate(Date())
        var lines: [Line] = []
        for income in store.incomes(for: project.id, in: month) {
            lines.append(Line(id: "i-\(income.id)", amount: income.amount, title: income.name, date: income.date, route: .entryForm(.editIncome(income.id)), dimmed: false))
        }
        for cost in store.oneOffCosts(for: project.id, in: month) {
            lines.append(Line(id: "o-\(cost.id)", amount: -cost.amount, title: title(cost.name, url: cost.url), date: cost.date, route: .entryForm(.editOneOff(cost.id)), dimmed: false))
        }
        for cost in store.recurringCosts(for: project.id, in: month) {
            let accrual = cost.accrual(in: month)
            guard accrual > 0 || cost.startMonth > month else { continue }
            // Трата с будущим стартом — её цена, бледно: ещё не начисляется.
            let amount = accrual > 0 ? accrual : (cost.price(at: cost.startMonth) ?? 0)
            let day = min(cost.dueDay ?? 1, LocalDate.daysIn(year: month.year, month: month.month))
            lines.append(Line(
                id: "r-\(cost.id)", amount: -amount, title: title(cost.name, url: cost.url),
                date: LocalDate(year: month.year, month: month.month, day: day),
                route: .entryForm(.editRecurring(cost.id)), dimmed: !cost.isActive(asOf: month) || cost.startMonth > month
            ))
        }
        // Ещё не наступившие даты текущего месяца — бледнее: списание впереди.
        return lines
            .map { line in
                var line = line
                if line.date > today && month == store.month { line.dimmed = true }
                return line
            }
            .sorted { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.amount > b.amount
            }
    }

    /// «GPU сервер · Selectel».
    private func title(_ name: String, url: String?) -> String {
        guard let key = Payments.payeeKey(for: url) else { return name }
        let payee = Payments.payeeTitle(forKey: key)
        return name.localizedCaseInsensitiveContains(payee) ? name : "\(name) · \(payee)"
    }
}

private struct EntryLine: View {
    let line: EntriesList.Line
    let currency: Currency
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(MoneyFormat.signedFull(line.amount, currency).replacingOccurrences(of: "\u{00A0}" + currency.symbol, with: ""))
                .font(.bodySemibold)
                .monospacedDigit()
                .foregroundStyle(line.amount > 0 ? DS.Tone.plus : DS.Ink.body)
                .frame(width: 64, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(line.title)
                .font(.body)
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(Self.date(line.date))
                .font(.caption)
                .foregroundStyle(DS.Ink.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? DS.Surface.rowHover : .clear))
        .opacity(line.dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }

    /// «сегодня», «вчера», «1 окт».
    static func date(_ date: LocalDate) -> String {
        let today = LocalDate(Date())
        if date == today { return L("сегодня", "today") }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()), date == LocalDate(yesterday) { return L("вчера", "yesterday") }
        return L("\(date.day) \(Words.monthShort(date.month))", "\(Words.monthShort(date.month)) \(date.day)")
    }
}
