import SwiftUI
import RadarchikCore

// Мелкие общие элементы панели: заголовок, кнопки, строки форм, шаг месяцев,
// раскладка чипов «в строку с переносом».

/// Заголовок внутреннего экрана: «‹» назад, цветная метка проекта, название, действие справа.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var colorHex: String?
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            IconButton(systemImage: "chevron.left", help: L("Назад (Esc)", "Back (Esc)"), action: onBack)
                .padding(.leading, -6)

            if let colorHex {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: colorHex))
                    .frame(width: 4, height: 16)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, colorHex: String? = nil, onBack: @escaping () -> Void) {
        self.init(title: title, colorHex: colorHex, onBack: onBack) { EmptyView() }
    }
}

/// Кнопка-«таблетка». `prominent` — главное действие экрана (светлая).
/// Подсвечивается при наведении, при нажатии темнеет и чуть сжимается,
/// неактивная — полупрозрачная.
struct PillButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(PillButtonStyle(prominent: prominent))
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.black : DS.Ink.primary)
            .background(Capsule().fill(fill))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var fill: Color {
        let active = hovering && isEnabled
        if prominent {
            return DS.Ink.primary.opacity(configuration.isPressed ? 0.72 : active ? 0.88 : 1)
        }
        return configuration.isPressed ? DS.Surface.pressed : active ? DS.Surface.cardHover : DS.Surface.card
    }
}

/// Строка формы: подпись слева, поле справа.
struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.xs) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DS.Ink.muted)
                .frame(width: DS.Size.formLabel, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Текстовое поле в стиле панели: на полупрозрачной подложке, высотой с кнопки.
/// В фокусе — синяя рамка (передаёт родитель: фокусом управляет он, `.focused`).
/// `suffix` — приписка внутри поля справа, например значок валюты.
/// (Выбор месяца, дня и часа — `MonthStepper` и соседи в Controls.swift.)
struct PanelTextField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused = false
    var alignment: TextAlignment = .leading
    var suffix: String?

    init(_ placeholder: String, text: Binding<String>, isFocused: Bool = false, alignment: TextAlignment = .leading, suffix: String? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.isFocused = isFocused
        self.alignment = alignment
        self.suffix = suffix
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(text: $text, prompt: Text(placeholder).foregroundStyle(DS.Ink.muted)) { EmptyView() }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DS.Ink.primary)
                .multilineTextAlignment(alignment)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Ink.muted)
            }
        }
        .modifier(FieldChrome(isFocused: isFocused))
    }
}

/// То же для секретов (ключ API): ввод скрыт.
struct PanelSecureField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused = false

    init(_ placeholder: String, text: Binding<String>, isFocused: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.isFocused = isFocused
    }

    var body: some View {
        SecureField(text: $text, prompt: Text(placeholder).foregroundStyle(DS.Ink.muted)) { EmptyView() }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(DS.Ink.primary)
            .modifier(FieldChrome(isFocused: isFocused))
    }
}

/// Подложка поля: отступы, высота, рамка в фокусе.
private struct FieldChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(DS.Surface.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).stroke(isFocused ? DS.Accent.focus : .clear, lineWidth: 1.5))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Подсказка мелким шрифтом.
struct Hint: View {
    let text: String
    /// Короткие слова не остаются в конце строки (`Typography.bind`).
    init(_ text: String) { self.text = Typography.bind(text) }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DS.Ink.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Удаление в два нажатия без модального окна: «Удалить» → «Точно удалить?».
/// Через 3 секунды кнопка сама возвращается в обычное состояние.
struct DeleteButton: View {
    var title = L("Удалить", "Delete")
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { action() } else { armed = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                Text(armed ? L("Точно удалить?", "Really delete?") : title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(armed ? DS.Money.negativeText : DS.Ink.muted)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(3))
            armed = false
        }
    }
}

/// Заголовок секции списка.
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Ink.muted)
            .textCase(.uppercase)
    }
}

/// Строка списка трат/доходов: название, пояснение, сумма; по клику — правка.
struct EntryRow: View {
    let title: String
    var subtitle: String?
    let amount: String
    var amountColor: Color = DS.Ink.primary
    var link: URL?
    var dimmed = false
    /// Строка внутри общей карточки (`PaymentsView`): без своей подложки, только подсветка.
    var inGroup = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Ink.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            Text(amount)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(amountColor)
            if let link {
                IconButton(systemImage: "arrow.up.right.square", help: L("Открыть ", "Open ") + (link.host() ?? L("ссылку", "link"))) {
                    NSWorkspace.shared.open(link)
                }
                .padding(.vertical, -4)
                .padding(.trailing, -6)
            }
        }
        .padding(.horizontal, inGroup ? 12 : 10)
        .padding(.vertical, inGroup ? 8 : 7)
        .background(
            RoundedRectangle(cornerRadius: inGroup ? 0 : DS.Radius.field)
                .fill(hovering ? DS.Surface.cardHover : (inGroup ? Color.clear : DS.Surface.card))
        )
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// Раскладка «в строку с переносом» — для чипов проектов.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(maxWidth: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: .unspecified
                )
            }
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty && x + size.width > maxWidth {
                rows.append(Row(items: [(index, 0)], y: row.y + row.height + spacing, width: size.width, height: size.height))
            } else {
                row.items.append((index, x))
                row.width = x + size.width
                row.height = max(row.height, size.height)
                rows[rows.count - 1] = row
            }
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

extension String {
    /// Пустая после обрезки пробелов строка → nil (для необязательных полей).
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
