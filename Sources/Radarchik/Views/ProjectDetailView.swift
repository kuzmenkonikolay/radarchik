import SwiftUI
import RadarchikCore

/// Экран проекта: пришло, ушло и итог за месяц, рост к прошлому месяцу,
/// график за 6 месяцев, итог за всё время, а ниже — траты и доходы.
/// Месяц переключается стрелками или кликом по столбику.
struct ProjectDetailView: View {
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
        if let project = store.ledger.project(id: projectId) {
            content(project)
        } else {
            // Проект удалили с другого экрана — возвращаемся.
            Color.clear.frame(height: 1).onAppear { model.popToRoot() }
        }
    }

    private func content(_ project: Project) -> some View {
        let report = store.report(for: project, month: month)
        let currency = project.currency

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: project.name, colorHex: project.colorHex, onBack: model.pop) {
                IconButton(systemImage: "pencil", help: L("Изменить проект", "Edit project")) {
                    model.push(.projectForm(editing: project.id))
                }
            }

            HStack {
                MonthStepper(month: $month)
                Spacer()
                // Настроение — только у закрытых месяцев; текущий ещё «пока».
                Group {
                    if month == store.month {
                        Label(L("месяц идёт", "in progress"), systemImage: "hourglass")
                    } else if month > store.month {
                        Label(L("ещё впереди", "still ahead"), systemImage: "calendar")
                    } else {
                        Label(report.mood.label, systemImage: report.mood.icon)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Ink.secondary)
            }

            HStack(spacing: DS.Spacing.xs) {
                StatTile(label: L("Пришло", "In"), value: MoneyFormat.full(report.current.income, currency))
                StatTile(label: L("Ушло", "Out"), value: MoneyFormat.full(report.current.cost, currency))
                StatTile(label: L("Итог", "Net"), value: MoneyFormat.signedFull(report.current.net, currency), color: DS.Money.text(for: report.current.net))
            }

            HStack(spacing: 4) {
                Text(growthText(report))
                Text("·").foregroundStyle(DS.Ink.muted)
                Text(L("за всё время", "all time"))
                Text(MoneyFormat.signedFull(report.allTimeNet, currency))
                    .monospacedDigit()
                    .foregroundStyle(DS.Money.text(for: report.allTimeNet))
            }
            .font(.system(size: 11))
            .foregroundStyle(DS.Ink.secondary)

            NetBarsChart(
                points: store.history(for: project.id, endingAt: month),
                currency: currency,
                selected: month,
                inProgress: store.month,
                onSelect: { month = $0 }
            )
            .padding(DS.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))

            FitOrScroll(maxHeight: 280) { lists(project) }

            HStack(spacing: DS.Spacing.xs) {
                PillButton(L("Трата", "Cost"), systemImage: "plus") {
                    model.push(.entryForm(.new(.recurring, projectId: project.id)))
                }
                PillButton(L("Доход", "Income"), systemImage: "plus") {
                    model.push(.entryForm(.new(.income, projectId: project.id)))
                }
            }
        }
    }

    // MARK: - Списки

    private func lists(_ project: Project) -> some View {
        let recurring = store.recurringCosts(for: project.id, in: month)
        let oneOffs = store.oneOffCosts(for: project.id, in: month)
        let incomes = store.incomes(for: project.id, in: month)
        let monthName = Language.current == .ru ? Words.monthName(month.month).lowercased() : Words.monthName(month.month)

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if recurring.isEmpty && oneOffs.isEmpty && incomes.isEmpty {
                Hint(L("Пока пусто. Заведи регулярную трату один раз — дальше она начисляется сама.",
                       "Nothing here yet. Add a recurring cost once — it accrues by itself from then on."))
            }
            if !recurring.isEmpty {
                SectionTitle(L("Регулярные траты", "Recurring costs"))
                ForEach(recurring) { cost in
                    EntryRow(
                        title: cost.name,
                        subtitle: recurringSubtitle(cost),
                        amount: recurringAmount(cost, currency: project.currency),
                        link: Payments.normalizedURL(cost.url),
                        dimmed: !cost.isActive(asOf: month) || cost.startMonth > month
                    ) {
                        model.push(.entryForm(.editRecurring(cost.id)))
                    }
                }
            }
            if !oneOffs.isEmpty {
                SectionTitle(L("Разовые траты · ", "One-off costs · ") + monthName)
                ForEach(oneOffs) { cost in
                    EntryRow(
                        title: cost.name,
                        subtitle: Words.dayMonth(cost.date.day, month.month),
                        amount: MoneyFormat.full(cost.amount, project.currency),
                        link: Payments.normalizedURL(cost.url)
                    ) {
                        model.push(.entryForm(.editOneOff(cost.id)))
                    }
                }
            }
            if !incomes.isEmpty {
                SectionTitle(L("Доходы · ", "Income · ") + monthName)
                ForEach(incomes) { income in
                    EntryRow(
                        title: income.name,
                        subtitle: Words.dayMonth(income.date.day, month.month),
                        amount: MoneyFormat.signedFull(income.amount, project.currency),
                        amountColor: DS.Money.positiveText
                    ) {
                        model.push(.entryForm(.editIncome(income.id)))
                    }
                }
            }
        }
    }

    /// «Рост к сентябрю: +12%» / «vs September: +12%».
    private func growthText(_ report: ProjectReport) -> String {
        let previousMonth = report.month.previous.month
        let head = L("Рост к \(RussianWords.monthDative(previousMonth))", "vs \(Words.monthName(previousMonth))")
        guard let growth = report.growthPercent else { return head + ": —" }
        return head + ": " + MoneyFormat.percent(growth)
    }

    /// «каждый месяц · с янв 2026», «раз в год · до сен 2026».
    private func recurringSubtitle(_ cost: RecurringCost) -> String {
        var parts = [cost.period == .monthly ? L("каждый месяц", "monthly") : L("раз в год", "yearly")]
        if cost.startMonth > month {
            parts.append(L("с ", "from ") + shortMonth(cost.startMonth))
        } else if let end = cost.endMonth {
            parts.append(end < month ? L("выключена с ", "off since ") + shortMonth(end.next) : L("до ", "until ") + shortMonth(end))
        } else {
            parts.append(L("с ", "since ") + shortMonth(cost.startMonth))
        }
        return parts.joined(separator: " · ")
    }

    /// Месячная — цена месяца; годовая — цена за год и сколько из неё приходится на месяц.
    private func recurringAmount(_ cost: RecurringCost, currency: Currency) -> String {
        let reference = max(month, cost.startMonth)
        switch cost.period {
        case .monthly:
            return MoneyFormat.full(cost.price(at: reference) ?? 0, currency)
        case .yearly:
            let yearly = MoneyFormat.full(cost.price(at: reference) ?? 0, currency) + L(" / год", " / yr")
            let accrual = cost.accrual(in: month)
            guard accrual > 0 else { return yearly }
            return yearly + L(" (\(MoneyFormat.compact(accrual, currency)) в мес.)", " (\(MoneyFormat.compact(accrual, currency))/mo)")
        }
    }

    private func shortMonth(_ month: YearMonth) -> String {
        "\(Words.monthShort(month.month)) \(month.year)"
    }
}

/// Плитка «подпись — сумма».
struct StatTile: View {
    let label: String
    let value: String
    var color: Color = DS.Ink.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DS.Ink.muted)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(DS.Surface.card))
    }
}
