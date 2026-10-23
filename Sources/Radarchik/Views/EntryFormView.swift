import SwiftUI
import RadarchikCore

/// H. Новая запись прямо в чёлке: слева лицо squint с ручками и подпись, справа форма —
/// сегмент-контрол «Регулярная / Разовая / Доход», поля в три колонки, чипы проектов
/// с мини-лицами, внизу подсказка и кнопки «Отмена» и «Записать».
///
/// Регулярную трату вводят один раз, дальше она начисляется сама. При правке
/// прошлое не переписывается: новая сумма действует «с месяца», выключение
/// задаёт последний оплачиваемый месяц, история остаётся.
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
    @State private var dueDay: Int?
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
        var original: Original?
        var originalAmount: Int64?
        var kind = EntryKind.recurring
        var projectId = firstProject
        var name = ""
        var url = ""
        var period = CostPeriod.monthly
        var startMonth = month
        var dueDay: Int?
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
                dueDay = cost.dueDay
                priceFrom = max(month, cost.startMonth)
                originalAmount = cost.price(at: priceFrom) ?? cost.prices.last?.amount
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
        _dueDay = State(initialValue: dueDay)
        _date = State(initialValue: date)
        _priceFrom = State(initialValue: priceFrom)
        _isActive = State(initialValue: isActive)
        _lastMonth = State(initialValue: lastMonth)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.cards) {
            FaceCard(face: .main(.squint, tone: DS.Tone.face, hands: .down), phrase: caption)
            Card(vertical: 18, horizontal: 20) {
                if store.projects.isEmpty && original == nil {
                    noProjects
                } else {
                    form
                }
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Подпись у лица — по виду записи.
    private var caption: String {
        switch kind {
        case .recurring: L("Запишу один раз — дальше начислю сам каждый месяц.", "Enter it once — I’ll accrue it myself every month.")
        case .oneOff: L("Разовая: запишу в этот месяц и больше не вспомню.", "One-off: goes into this month, and that’s it.")
        case .income: L("Доход! Запишу — и итог месяца подрастёт.", "Income! Once it’s in, the month’s total goes up.")
        }
    }

    // MARK: - Форма

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            if original == nil {
                SegmentedPicker(selection: $kind) { $0.title }
            } else {
                Text(kind.longTitle)
                    .font(.bodyBold)
                    .foregroundStyle(DS.Ink.primary)
            }

            HStack(alignment: .top, spacing: 12) {
                LabeledField(kind == .income ? L("Откуда", "From") : L("Название", "Name")) {
                    PanelTextField(namePlaceholder, text: $name, isFocused: focus == .name)
                        .focused($focus, equals: .name)
                }
                LabeledField(amountLabel) {
                    PanelTextField("0", text: $amountText, isFocused: focus == .amount, alignment: .trailing, suffix: currencySymbol)
                        .focused($focus, equals: .amount)
                }
                switch kind {
                case .recurring:
                    LabeledField(L("Где платить", "Where to pay")) {
                        PanelTextField(L("my.selectel.ru", "console.hetzner.com"), text: $url, isFocused: focus == .url)
                            .focused($focus, equals: .url)
                    }
                case .oneOff, .income:
                    LabeledField(L("Дата", "Date")) { DayStepper(date: $date) }
                }
            }

            if kind == .recurring {
                recurringRow
            } else if kind == .oneOff {
                LabeledField(L("Где платил", "Where you paid")) {
                    PanelTextField(L("необязательно", "optional"), text: $url, isFocused: focus == .url)
                        .focused($focus, equals: .url)
                }
                .frame(maxWidth: 260)
            }

            if original != nil, kind == .recurring {
                editingRows
            }

            LabeledField(L("Проект", "Project")) {
                ProjectChips(store: store, selected: $projectId)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(DS.Money.negativeText)
            }

            HStack(spacing: DS.Spacing.xs) {
                Text(footerHint)
                    .font(.body)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                if original != nil {
                    DeleteButton(action: { delete() })
                }
                SecondaryButton(L("Отмена", "Cancel")) { model.pop() }
                PrimaryButton(L("Записать", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .task {
            // Курсор в «Название» у новой записи; ждём, пока панель станет ключевой.
            guard original == nil else { return }
            try? await Task.sleep(for: .milliseconds(120))
            focus = .name
        }
    }

    /// Период, с какого месяца начислять и день списания.
    private var recurringRow: some View {
        HStack(alignment: .top, spacing: 12) {
            LabeledField(L("Период", "Period")) {
                SegmentedPicker(
                    selection: $period,
                    options: [
                        .init(value: CostPeriod.monthly, title: L("В месяц", "Monthly")),
                        .init(value: CostPeriod.yearly, title: L("В год", "Yearly")),
                    ]
                )
            }
            LabeledField(period == .monthly ? L("Начислять с", "Starts in") : L("Первая оплата", "First payment")) {
                MonthStepper(month: $startMonth)
            }
            LabeledField(L("День списания", "Due day")) {
                DueDayStepper(day: $dueDay)
            }
        }
    }

    /// Правка регулярной: новая сумма «с месяца», выключение «по месяц».
    @ViewBuilder
    private var editingRows: some View {
        HStack(alignment: .top, spacing: 12) {
            if amountChanged {
                LabeledField(L("Новая сумма с", "New amount from")) { MonthStepper(month: $priceFrom) }
            }
            LabeledField(L("Активна", "Active")) {
                Toggle(isOn: $isActive) { EmptyView() }
                    .toggleStyle(.panel)
                    .accessibilityLabel(L("Активна", "Active"))
                    .frame(height: DS.Size.control)
            }
            if !isActive {
                LabeledField(L("Последний месяц", "Last month")) { MonthStepper(month: $lastMonth) }
            }
        }
        if amountChanged {
            Hint(L("Месяцы раньше останутся со старой суммой.", "Earlier months keep the old amount."))
        }
    }

    private var noProjects: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L("Сначала проект", "A project first"))
                .font(.bodyBold)
                .foregroundStyle(DS.Ink.primary)
            Hint(L("Траты и доходы привязываются к проекту — заведи первый.", "Costs and income belong to a project — create the first one."))
            HStack {
                SecondaryButton(L("Отмена", "Cancel")) { model.pop() }
                PrimaryButton(L("Новый проект", "New project"), systemImage: "plus") {
                    model.replaceTop(with: .projectForm(editing: nil))
                }
            }
        }
    }

    // MARK: - Подписи

    private var namePlaceholder: String {
        switch kind {
        case .recurring: L("GPU сервер", "Hetzner server")
        case .oneOff: L("Реклама в Telegram", "Ads on X")
        case .income: L("Подписки", "Subscriptions")
        }
    }

    private var amountLabel: String {
        switch kind {
        case .recurring: period == .monthly ? L("В месяц, \(currencySymbol)", "Per month, \(currencySymbol)") : L("В год, \(currencySymbol)", "Per year, \(currencySymbol)")
        case .oneOff, .income: L("Сумма", "Amount")
        }
    }

    /// «каждый месяц · с 1 ноября», «раз в год · с октября», «15 октября».
    private var footerHint: String {
        switch kind {
        case .recurring:
            let from = period == .monthly
                ? L("с 1 \(RussianWords.monthGenitive(startMonth.month))", "from \(Words.monthName(startMonth.month)) 1")
                : L("с \(RussianWords.monthGenitive(startMonth.month))", "from \(Words.monthName(startMonth.month))")
            let each = period == .monthly ? L("каждый месяц", "every month") : L("раз в год, в итоге по 1/12", "yearly, 1/12 in totals")
            return "\(each) · \(from)"
        case .oneOff, .income:
            return DayStepper.text(date)
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
                cost.dueDay = dueDay
                if cost.startMonth != startMonth {
                    cost = cost.withStartMonth(startMonth)
                }
                if amountChanged {
                    cost = cost.changingPrice(to: amount, from: priceFrom)
                }
                cost.endMonth = isActive ? nil : max(lastMonth, cost.startMonth)
                saved = store.save(cost)
            } else {
                saved = store.save(RecurringCost(projectId: projectId, name: title, url: link, period: period, startMonth: startMonth, amount: amount, dueDay: dueDay))
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
        if saved {
            model.onSound?(.pencil)
            model.pop()
        }
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

/// Чипы проектов с мини-лицом 24: выбранный — рамка цвета настроения α 0.6, фон α 0.12.
struct ProjectChips: View {
    let store: MoneyStore
    @Binding var selected: UUID?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(store.glances) { glance in
                ProjectChipButton(glance: glance, isSelected: glance.project.id == selected) { selected = glance.project.id }
            }
        }
    }
}

private struct ProjectChipButton: View {
    let glance: ProjectGlance
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let tone = FaceDirector.tone(glance)
        Button(action: action) {
            HStack(spacing: 7) {
                MiniFace(.project(glance.mood, colorHex: glance.project.colorHex, mini: true), size: 24)
                    .frame(width: 28, height: 22)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                Text(glance.project.name)
                    .font(.bodySemibold)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(height: DS.Size.control)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(isSelected ? tone.opacity(0.12) : hovering ? DS.Surface.pillHover : DS.Surface.input))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(isSelected ? tone.opacity(0.6) : DS.Surface.inputBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.field))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// «‹ 22-го ›» или «—»: день списания, по которому приходит «Пора платить».
struct DueDayStepper: View {
    @Binding var day: Int?

    var body: some View {
        ValueStepper(
            text: day.map { L("\($0)-го", "\(Words.ordinal($0))") } ?? L("не задан", "not set"),
            minWidth: 88, previousHelp: L("Днём раньше", "A day earlier"), nextHelp: L("Днём позже", "A day later"),
            onPrevious: { step(-1) }, onNext: { step(1) }
        )
    }

    /// По кругу: — , 1, 2 … 28, —.
    private func step(_ delta: Int) {
        let current = day ?? 0
        let next = (current + delta + 29) % 29
        day = next == 0 ? nil : next
    }
}
