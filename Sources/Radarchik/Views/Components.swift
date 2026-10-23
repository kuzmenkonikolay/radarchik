import AppKit
import SwiftUI
import RadarchikCore

// Базовые элементы дизайна v2: карточка, кнопки, чипы, бейдж, кнопка тулбара,
// поля, строки списков, раскладка «в строку с переносом».

// MARK: - Карточка

/// Карточка панели: чуть светлее чёрного и полупрозрачная, рамка 1 pt, радиус 22.
struct Card<Content: View>: View {
    var padding = EdgeInsets(top: 18, leading: 22, bottom: 18, trailing: 22)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).stroke(DS.Surface.cardBorder, lineWidth: 1))
    }
}

extension Card {
    init(vertical: CGFloat, horizontal: CGFloat, @ViewBuilder content: () -> Content) {
        self.init(padding: EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal), content: content)
    }
}

/// Шапка карточки: цветная точка, заголовок жирным и подпись серым.
struct CardHeader: View {
    var dot: Color?
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(title)
                .font(.bodyBold)
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
            if let subtitle {
                Text("· " + subtitle)
                    .font(.body)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Кнопки

/// Главное действие: белая кнопка с чёрным текстом.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    /// Значок после текста («Открыть кабинет ↗»).
    var iconAfter = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, iconAfter: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.iconAfter = iconAfter
        self.action = action
    }

    var body: some View {
        Button(action: action) { ButtonLabel(title: title, systemImage: systemImage, iconAfter: iconAfter) }
            .buttonStyle(PanelButtonStyle(kind: .primary))
    }
}

/// Второстепенное действие: белая подложка α 0.08.
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) { ButtonLabel(title: title, systemImage: systemImage) }
            .buttonStyle(PanelButtonStyle(kind: .secondary))
    }
}

/// Третье действие: без фона, серый текст («Не надо»).
struct PlainButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) { ButtonLabel(title: title, systemImage: nil) }
            .buttonStyle(PanelButtonStyle(kind: .plain))
    }
}

/// Прежнее имя: `prominent` — главная кнопка. Остальным экранам менять код не нужно.
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
        Button(action: action) { ButtonLabel(title: title, systemImage: systemImage) }
            .buttonStyle(PanelButtonStyle(kind: prominent ? .primary : .secondary))
    }
}

private struct ButtonLabel: View {
    let title: String
    let systemImage: String?
    var iconAfter = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage, !iconAfter {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
            }
            Text(title).lineLimit(1).fixedSize()
            if let systemImage, iconAfter {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
        }
    }
}

struct PanelButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, kind: kind)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PanelButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.bodySemibold)
            .padding(.horizontal, kind == .plain ? 10 : 16)
            .frame(height: DS.Size.button)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous).fill(fill))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .black
        case .secondary: DS.Ink.primary
        case .plain: hovering ? DS.Ink.body : DS.Ink.secondary
        }
    }

    private var fill: Color {
        let active = hovering && isEnabled
        switch kind {
        case .primary: return Color.white.opacity(configuration.isPressed ? 0.78 : active ? 0.92 : 1)
        case .secondary: return configuration.isPressed ? DS.Surface.secondaryHover : active ? DS.Surface.secondaryHover : DS.Surface.secondaryButton
        case .plain: return active ? DS.Surface.chip : .clear
        }
    }
}

/// Кнопка тулбара в «ушах» выреза: 38×30, радиус 10, значок 17 pt.
/// Активная — белая подложка α 0.10 и светлый значок.
struct ToolbarButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    /// Бейдж с числом (советы) или точка (тревога).
    var badge: ToolbarBadge?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive || hovering ? DS.Ink.primary : DS.Ink.secondary)
                .frame(width: DS.Size.toolbarButton.width, height: DS.Size.toolbarButton.height)
                .background(RoundedRectangle(cornerRadius: DS.Radius.toolbar, style: .continuous).fill(isActive ? DS.Surface.toolbarActive : hovering ? DS.Surface.toolbarHover : .clear))
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        badge.view.offset(x: 4, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Что висит на кнопке тулбара: число (советы) или точка (тревога).
enum ToolbarBadge: Equatable {
    case count(Int, Color)
    case dot(Color)

    @ViewBuilder var view: some View {
        switch self {
        case .count(let count, let color):
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(color))
        case .dot(let color):
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Чипы и бейджи

/// Чип: короткая надпись на подложке. Цвет — по смыслу.
struct Chip: View {
    let text: String
    var systemImage: String?
    var background: Color = DS.Surface.chip
    var foreground: Color = DS.Ink.primary
    var bold = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: bold ? .bold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(background))
    }
}

/// Чип-кнопка: «К оплате 30,5к · больше всего Selectel ↗».
struct ChipButton: View {
    let text: String
    var systemImage: String? = "arrow.up.right"
    var background: Color = DS.Tone.payChipBg
    var foreground: Color = DS.Tone.payChipText
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text).lineLimit(1)
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(background.opacity(hovering ? 1.6 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Бейдж с числом советов: фон `tips` α 0.16, текст `tips`, 11 bold.
struct CountBadge: View {
    let count: Int
    var color: Color = DS.Tone.tips

    var body: some View {
        Text("\(count)")
            .font(.badge)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

// MARK: - Шапка внутреннего экрана

/// «‹» назад и заголовок — у экранов, куда зашли с другого (настройки Claude, «Что уходит»).
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
                Circle().fill(Color(hex: colorHex)).frame(width: 8, height: 8)
            }
            Text(title)
                .font(.system(size: 15, weight: .bold))
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

// MARK: - Поля

/// Поле с подписью сверху (11 semibold, серая) — колонки формы.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.label)
                .foregroundStyle(DS.Ink.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Строка формы: подпись слева, поле справа (настройки Claude).
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
                .font(.caption)
                .foregroundStyle(DS.Ink.secondary)
                .frame(width: FormRow.labelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    nonisolated static var labelWidth: CGFloat { 116 }
}

/// Текстовое поле: чёрная подложка с рамкой, высотой 34. В фокусе рамка светлее.
/// `suffix` — приписка внутри поля справа, например значок валюты.
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
                    .foregroundStyle(DS.Ink.secondary)
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

/// Подложка поля: отступы, высота, рамка.
struct FieldChrome: ViewModifier {
    var isFocused = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: DS.Size.control)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Surface.input))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(isFocused ? DS.Accent.focus : DS.Surface.inputBorder, lineWidth: 1))
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
            .foregroundStyle(armed ? DS.Money.negativeText : DS.Ink.secondary)
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
            .foregroundStyle(DS.Ink.secondary)
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            Text(amount)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
            if let link {
                IconButton(systemImage: "arrow.up.right", help: L("Открыть ", "Open ") + (link.host() ?? L("ссылку", "link"))) {
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
                .fill(hovering ? DS.Surface.rowHover : (inGroup ? Color.clear : DS.Surface.group))
        )
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// Кнопка из одного значка: «‹ назад», карандаш, шестерёнка. Подсвечивается при наведении.
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? DS.Ink.primary : DS.Ink.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? DS.Surface.chip : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
