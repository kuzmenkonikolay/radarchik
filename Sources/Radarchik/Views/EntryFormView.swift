import SwiftUI
import RadarchikCore

/// Новая запись или правка: регулярная трата, разовая трата или доход.
///
/// Регулярную трату вводят один раз, дальше она начисляется сама. При правке
/// прошлое не переписывается:
/// - новая сумма действует «с месяца» (по умолчанию с текущего);
/// - выключение задаёт последний оплачиваемый месяц, история остаётся.
struct EntryFormView: View {
    let target: EntryFormTarget
    let model: NotchViewModel
    let store: MoneyStore

    private enum Field { case name, amount, url }
    private enum Original {
        case recurring(RecurringCost)
        case oneOff(OneOffCost)
        case income(Income)
    }

    /// Запись, которую правим; nil — новая.
    private let original: Original?
    /// Сумма, показанная при открытии правки: если её не трогали, цены не меняем.
    private let originalAmount: Int64?

    @State private var kind: EntryKind
    @State private var projectId: UUID?
    @State private var name: String
    @State private var url: String
    @State private var amountText: String
    @State private var period: CostPeriod
    @State private var startMonth: YearMonth
    @State private var date: Date
    @State private var priceFrom: YearMonth
    @State private var isActive: Bool
    @State private var lastMonth: YearMonth
    @State private var errorText: String?
    @FocusState private var focus: Field?

    init(target: EntryFormTarget, model: NotchViewModel, store: MoneyStore) {
        self.target = target
        self.model = model
        self.store = store

        let month = store.month
        let firstProject = store.projects.first?.id
        // Значения для новой записи; правка ниже их перезапишет.
        var original: Original?
        var originalAmount: Int64?
        var kind = EntryKind.recurring
        var projectId = firstProject
        var name = ""
        var url = ""
        var period = CostPeriod.monthly
        var startMonth = month
        var date = Date()
        var priceFrom = month
        var isActive = true
        var lastMonth = month

        switch target {
        case .new(let newKind, let presetProject):
            kind = newKind
            projectId = presetProject ?? firstProject
        case .editRecurring(let id):
            if let cost = store.ledger.recurringCosts.first(where: { $0.id == id }) {
                original = .recurring(cost)
                kind = .recurring
                projectId = cost.projectId
                name = cost.name
                url = cost.url ?? ""
                period = cost.period
                startMonth = cost.startMonth
                priceFrom = max(month, cost.startMonth)
                originalAmount = cost.price(at: priceFrom) ?? cost.prices.last?.amount
                // «Активна» = у траты нет последнего месяца.
                isActive = cost.endMonth == nil
                lastMonth = cost.endMonth ?? month
            }
        case .editOneOff(let id):
            if let cost = store.ledger.oneOffCosts.first(where: { $0.id == id }) {
                original = .oneOff(cost)
                kind = .oneOff
                projectId = cost.projectId
                name = cost.name
                url = cost.url ?? ""
                originalAmount = cost.amount
                date = cost.date.date()
            }
        case .editIncome(let id):
            if let income = store.ledger.incomes.first(where: { $0.id == id }) {
                original = .income(income)
                kind = .income
                projectId = income.projectId
                name = income.name
                originalAmount = income.amount
                date = income.date.date()
            }
        }

        self.original = original
        self.originalAmount = originalAmount
        _kind = State(initialValue: kind)
        _projectId = State(initialValue: projectId)
        _name = State(initialValue: name)
        _url = State(initialValue: url)
        _amountText = State(initialValue: originalAmount.map(MoneyParser.editingString) ?? "")
        _period = State(initialValue: period)
        _startMonth = State(initialValue: startMonth)
        _date = State(initialValue: date)
        _priceFrom = State(initialValue: priceFrom)
        _isActive = State(initialValue: isActive)
        _lastMonth = State(initialValue: lastMonth)
    }

    var body: some View {
        if store.projects.isEmpty && original == nil {
            noProjects
        } else {
            form
        }
    }

    // MARK: - Форма

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: title, onBack: { model.pop() })

            if original == nil {
                SegmentedPicker(selection: $kind) { $0.title }
                    .padding(.bottom, 4)
            }

            FormRow(L("Проект", "Project")) {
                MenuPicker(
                    selection: $projectId,
                    options: store.projects.map { .init(value: Optional($0.id), title: $0.name, colorHex: $0.colorHex) }
                )
                .frame(maxWidth: 240)
            }

            FormRow(L("Название", "Name")) {
                PanelTextField(namePlaceholder, text: $name, isFocused: focus == .name)
                    .focused($focus, equals: .name)
            }

            FormRow(L("Сумма", "Amount")) {
                HStack(spacing: DS.Spacing.xs) {
                    // Цифры справа, значок валюты — внутри поля, как на чеке.
                    PanelTextField("0", text: $amountText, isFocused: focus == .amount, alignment: .trailing, suffix: currencySymbol)
                        .focused($focus, equals: .amount)
                        .frame(width: 150)
                    if kind == .recurring {
                        Text(period == .monthly ? L("в месяц", "per month") : L("в год", "per year"))
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Ink.muted)
                    }
                }
            }

            if kind != .income {
                FormRow(L("Ссылка", "Link")) {
                    PanelTextField(L("где платить, например my.selectel.ru", "where to pay, e.g. console.hetzner.com"), text: $url, isFocused: focus == .url)
                        .focused($focus, equals: .url)
                }
            }

            switch kind {
            case .recurring:
                recurringFields
            case .oneOff, .income:
                FormRow(L("Дата", "Date")) { DayStepper(date: $date) }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Money.negativeText)
            }

            HStack(spacing: DS.Spacing.xs) {
                if original != nil {
                    DeleteButton(action: { delete() })
                }
                Spacer()
                PillButton(L("Отмена", "Cancel")) { model.pop() }
                PillButton(L("Сохранить", "Save"), prominent: true) { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .task {
            // Курсор в «Название» у новой записи; ждём, пока панель станет ключевой.
            guard original == nil else { return }
            try? await Task.sleep(for: .milliseconds(80))
            focus = .name
        }
    }

    @ViewBuilder
    private var recurringFields: some View {
        FormRow(L("Период", "Period")) {
            SegmentedPicker(
                selection: $period,
                options: [
                    .init(value: CostPeriod.monthly, title: L("Каждый месяц", "Monthly")),
                    .init(value: CostPeriod.yearly, title: L("Раз в год", "Yearly")),
                ],
                fills: false
            )
        }
        FormRow(period == .monthly ? L("Начислять с", "Starts in") : L("Первая оплата", "First payment")) {
            MonthStepper(month: $startMonth)
        }
        if original == nil {
            Hint(period == .monthly
                ? L("Сохранишь один раз — дальше начисляется само.", "Save it once — it accrues by itself from then on.")
                : L("Сохранишь один раз. В итогах — по 1/12 каждый месяц, в «Куда платить» — целиком в месяц продления.",
                    "Save it once. Totals count 1/12 every month; “Where to pay” shows the full amount in the renewal month."))
                .padding(.leading, Self.fieldInset)
        } else {
            if amountChanged {
                FormRow(L("Новая сумма с", "New amount from")) { MonthStepper(month: $priceFrom) }
                Hint(L("Месяцы раньше останутся со старой суммой.", "Earlier months keep the old amount."))
                    .padding(.leading, Self.fieldInset)
            }
            FormRow(L("Активна", "Active")) {
                Toggle(isOn: $isActive) { EmptyView() }
                    .toggleStyle(.panel)
                    .accessibilityLabel(L("Активна", "Active"))
            }
            if !isActive {
                FormRow(L("Последний месяц", "Last month")) { MonthStepper(month: $lastMonth) }
                Hint(period == .monthly
                    ? L("По этот месяц включительно трата останется в истории.", "The cost stays in history up to and including this month.")
                    : L("Последний месяц, когда ещё было продление. Уже оплаченный год дочислится.",
                        "The last month with a renewal. The year already paid for keeps accruing."))
                    .padding(.leading, Self.fieldInset)
            }
        }
    }

    private var noProjects: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Новая запись", "New entry"), onBack: { model.pop() })
            Hint(L("Сначала заведи проект: траты и доходы привязываются к нему.", "Create a project first: costs and income belong to one."))
            PillButton(L("Новый проект", "New project"), systemImage: "plus", prominent: true) {
                model.replaceTop(with: .projectForm(editing: nil))
            }
        }
    }

    /// Подсказки — под колонкой полей, а не под подписями.
    private static let fieldInset = DS.Size.formLabel + DS.Spacing.xs

    // MARK: - Подписи

    private var title: String {
        switch original {
        case nil: L("Новая запись", "New entry")
        case .recurring: EntryKind.recurring.title
        case .oneOff: EntryKind.oneOff.title
        case .income: EntryKind.income.title
        }
    }

    private var namePlaceholder: String {
        switch kind {
        case .recurring: L("например, Сервер Selectel", "e.g. Hetzner server")
        case .oneOff: L("например, Реклама в Telegram", "e.g. Ads on X")
        case .income: L("например, Подписки", "e.g. Subscriptions")
        }
    }

    private var currencySymbol: String {
        projectId.flatMap { store.ledger.project(id: $0) }?.currency.symbol ?? ""
    }

    private var amountChanged: Bool {
        guard let originalAmount, let amount = MoneyParser.parse(amountText) else { return false }
        return amount != originalAmount
    }

    // MARK: - Действия

    private func save() {
        errorText = nil
        guard let projectId, store.ledger.project(id: projectId) != nil else {
            errorText = L("Выбери проект", "Choose a project")
            return
        }
        guard let title = name.trimmedOrNil else {
            errorText = L("Напиши название", "Enter a name")
            focus = .name
            return
        }
        guard let amount = MoneyParser.parse(amountText) else {
            errorText = L("Сумма — число больше нуля, например 15 500", "The amount must be a number above zero, e.g. 15,500")
            focus = .amount
            return
        }
        let link = url.trimmedOrNil
        let day = LocalDate(date)

        let saved: Bool
        switch kind {
        case .recurring:
            if case .recurring(var cost)? = original {
                cost.projectId = projectId
                cost.name = title
                cost.url = link
                cost.period = period
                if cost.startMonth != startMonth {
                    cost = cost.withStartMonth(startMonth)
                }
                if amountChanged {
                    cost = cost.changingPrice(to: amount, from: priceFrom)
                }
                cost.endMonth = isActive ? nil : max(lastMonth, cost.startMonth)
                saved = store.save(cost)
            } else {
                saved = store.save(RecurringCost(projectId: projectId, name: title, url: link, period: period, startMonth: startMonth, amount: amount))
            }
        case .oneOff:
            if case .oneOff(var cost)? = original {
                cost.projectId = projectId
                cost.name = title
                cost.url = link
                cost.amount = amount
                cost.date = day
                saved = store.save(cost)
            } else {
                saved = store.save(OneOffCost(projectId: projectId, name: title, url: link, amount: amount, date: day))
            }
        case .income:
            if case .income(var income)? = original {
                income.projectId = projectId
                income.name = title
                income.amount = amount
                income.date = day
                saved = store.save(income)
            } else {
                saved = store.save(Income(projectId: projectId, name: title, amount: amount, date: day))
            }
        }
        if saved { model.pop() }
    }

    private func delete() {
        let deleted: Bool
        switch original {
        case .recurring(let cost): deleted = store.deleteRecurringCost(cost.id)
        case .oneOff(let cost): deleted = store.deleteOneOffCost(cost.id)
        case .income(let income): deleted = store.deleteIncome(income.id)
        case nil: return
        }
        if deleted { model.pop() }
    }
}
