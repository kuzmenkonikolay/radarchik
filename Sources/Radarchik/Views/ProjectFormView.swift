import SwiftUI
import RadarchikCore

/// Новый проект или правка: название, цвет, валюта, архив, удаление.
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
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: original == nil ? L("Новый проект", "New project") : L("Проект", "Project"), colorHex: colorHex, onBack: { model.pop() })

            FormRow(L("Название", "Name")) {
                PanelTextField(L("например, Курсы", "e.g. Side project"), text: $name, isFocused: nameFocused)
                    .focused($nameFocused)
            }

            FormRow(L("Цвет", "Color")) {
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

            FormRow(L("Валюта", "Currency")) {
                SegmentedPicker(selection: $currency, options: Currency.allCases.map { .init(value: $0, title: $0.symbol) }, fills: false)
            }
            if let original, original.currency != currency {
                Hint(L("Суммы не пересчитаются — поменяется только значок валюты.", "Amounts won’t be converted — only the currency sign changes."))
            } else if original == nil {
                Hint(L("Все траты и доходы проекта вводятся в его валюте, без конвертации.",
                       "All of the project’s costs and income are entered in its currency, no conversion."))
            }

            if original != nil {
                FormRow(L("В архиве", "Archived")) {
                    Toggle(isOn: $isArchived) { EmptyView() }
                        .toggleStyle(.panel)
                        .accessibilityLabel(L("В архиве", "Archived"))
                }
                if isArchived {
                    Hint(L("Архивный проект не показывается и не попадает в итоги, но данные остаются.",
                           "An archived project is hidden and left out of totals, but its data stays."))
                }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Money.negativeText)
            }

            HStack(spacing: DS.Spacing.xs) {
                if let original {
                    DeleteButton(title: L("Удалить с тратами и доходами", "Delete with costs and income")) {
                        if store.deleteProject(original.id) { model.popToRoot() }
                    }
                }
                Spacer()
                PillButton(L("Отмена", "Cancel")) { model.pop() }
                PillButton(L("Сохранить", "Save"), prominent: true) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            guard original == nil else { return }
            try? await Task.sleep(for: .milliseconds(80))
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
            // Новый проект — сразу открываем его карточку, чтобы завести траты.
            model.replaceTop(with: .project(project.id))
        } else if isArchived {
            model.popToRoot()
        } else {
            model.pop()
        }
    }
}
