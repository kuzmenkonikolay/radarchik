import SwiftUI
import RadarchikCore

/// Новый проект или правка: название, валюта, цвет, архив, удаление — в раскладке
/// формы (H): слева лицо в выбранном цвете, справа поля.
struct ProjectFormView: View {
    let editingId: UUID?
    let model: NotchViewModel
    let store: MoneyStore

    private let original: Project?

    @State private var name: String
    @State private var colorHex: String
    @State private var currency: Currency
    @State private var isArchived: Bool
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    init(editingId: UUID?, model: NotchViewModel, store: MoneyStore) {
        self.editingId = editingId
        self.model = model
        self.store = store
        let original = editingId.flatMap { store.ledger.project(id: $0) }
        self.original = original
        _name = State(initialValue: original?.name ?? "")
        _colorHex = State(initialValue: original?.colorHex ?? store.suggestedProjectColor())
        // Новый проект по-английски — в долларах, по-русски — в рублях.
        _currency = State(initialValue: original?.currency ?? (Language.current == .ru ? .rub : .usd))
        _isArchived = State(initialValue: original?.isArchived ?? false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.cards) {
            FaceCard(face: .mini(.smug, color: Color(hex: colorHex)), phrase: original == nil
                ? L("Назови проект — дальше считаю сам.", "Name the project — I’ll count from here.")
                : L("Поменяю название и цвет, цифры не трону.", "I’ll change the name and color, the numbers stay."))
            Card(vertical: 18, horizontal: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(original == nil ? L("Новый проект", "New project") : L("Проект", "Project"))
                        .font(.bodyBold)
                        .foregroundStyle(DS.Ink.primary)
                    HStack(alignment: .top, spacing: 12) {
                        LabeledField(L("Название", "Name")) {
                            PanelTextField(L("Парсер", "Side project"), text: $name, isFocused: nameFocused)
                                .focused($nameFocused)
                        }
                        LabeledField(L("Валюта", "Currency")) {
                            SegmentedPicker(selection: $currency, options: Currency.allCases.map { .init(value: $0, title: $0.symbol) })
                        }
                        .frame(width: 180)
                    }
                    LabeledField(L("Цвет", "Color")) {
                        HStack(spacing: 10) {
                            ForEach(DS.projectColors, id: \.self) { hex in
                                Button {
                                    colorHex = hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(DS.Ink.primary, lineWidth: hex == colorHex ? 2 : 0).padding(-3))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(hex == colorHex ? L("Выбран", "Selected") : L("Выбрать цвет", "Choose color"))
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.leading, 3)
                    }
                    Hint(original.map { $0.currency != currency } ?? false
                        ? L("Суммы не пересчитаются — поменяется только значок валюты.", "Amounts won’t be converted — only the currency sign changes.")
                        : L("Все траты и доходы проекта — в его валюте, без конвертации. Цвет — пока у проекта нет закрытого месяца; потом лицо красится настроением.",
                            "All of the project’s costs and income are in its currency, no conversion. The color shows until the first closed month; then the face takes the mood color."))

                    if original != nil {
                        HStack(spacing: DS.Spacing.sm) {
                            Toggle(isOn: $isArchived) {
                                Text(L("В архиве", "Archived"))
                                    .font(.body)
                                    .foregroundStyle(DS.Ink.primary)
                            }
                            .toggleStyle(.panel)
                            if isArchived {
                                Hint(L("Не показывается и не попадает в итоги, данные остаются.", "Hidden and left out of totals, the data stays."))
                            }
                        }
                    }

                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(DS.Money.negativeText)
                    }

                    HStack(spacing: DS.Spacing.xs) {
                        if let original {
                            DeleteButton(title: L("Удалить с тратами и доходами", "Delete with costs and income")) {
                                if store.deleteProject(original.id) { model.home() }
                            }
                        }
                        Spacer(minLength: 0)
                        SecondaryButton(L("Отмена", "Cancel")) { model.pop() }
                        PrimaryButton(L("Записать", "Save")) { save() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .task {
            guard original == nil else { return }
            try? await Task.sleep(for: .milliseconds(120))
            nameFocused = true
        }
    }

    private func save() {
        guard let title = name.trimmedOrNil else {
            errorText = L("Напиши название", "Enter a name")
            nameFocused = true
            return
        }
        var project = original ?? Project(name: title, colorHex: colorHex, currency: currency)
        project.name = title
        project.colorHex = colorHex
        project.currency = currency
        project.isArchived = isArchived
        guard store.save(project) else { return }
        if original == nil {
            // Новый проект — сразу его карточка, чтобы завести траты.
            model.replaceTop(with: .project(project.id))
        } else if isArchived {
            model.home()
        } else {
            model.pop()
        }
    }
}
