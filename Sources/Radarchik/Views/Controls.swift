import SwiftUI
import RadarchikCore

// Элементы управления в стиле панели (полировка 2026-10-19): системные
// сегменты, тумблеры и списки на чёрном выглядят чужими и тяжёлыми, а ещё
// не рисуются в лист картинок. Здесь — свои, на SwiftUI, в одном стиле.

// MARK: - Высота по содержимому

/// Содержимое по своей высоте, а если не влезает в `maxHeight` — прокрутка
/// ровно такой высоты. Обычный `.frame(maxHeight:)` здесь не годится: он
/// растягивается до максимума и ставит содержимое посередине — отсюда были
/// пустые полосы на «Системе» и в проекте (скриншоты 2026-10-19).
struct FitOrScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.unrollsScrolling) private var unrolls

    var body: some View {
        if unrolls {
            // Лист экранов: прокрутка в картинку не рисуется — показываем всё.
            content
        } else {
            scrollable
        }
    }

    private var scrollable: some View {
        HeightCap(maxHeight: maxHeight) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView {
                    // Запас снизу: последний пункт можно прокрутить выше затухания.
                    content.padding(.bottom, DS.Spacing.md)
                }
                .scrollIndicators(.never)
                .mask(alignment: .bottom) { ScrollFade() }
            }
        }
    }
}

extension EnvironmentValues {
    /// Для листа экранов (`--render-screens`): длинные экраны целиком, без прокрутки.
    @Entry var unrollsScrolling = false
}

/// Предлагает детям не больше `maxHeight`, а сам — ровно по их размеру.
private struct HeightCap: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let height = min(proposal.height ?? maxHeight, maxHeight)
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Мягкий край снизу у прокрутки: видно, что дальше есть ещё, и кнопки под
/// списком не выглядят наложенными на текст.
private struct ScrollFade: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 18)
        }
    }
}

// MARK: - Переключатель вариантов

/// Варианты в одну строку: выбранный — светлая плашка, она переезжает
/// между вариантами. Вместо системного сегментного переключателя.
struct SegmentedPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    /// На всю ширину (вкладки экрана) или по содержимому (в строке настроек).
    var fills = true

    @Namespace private var namespace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: DS.Radius.segment, style: .continuous).fill(DS.Surface.input))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.segment, style: .continuous).stroke(DS.Surface.inputBorder, lineWidth: 1))
        .fixedSize(horizontal: !fills, vertical: true)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { selection = option.value }
        } label: {
            Text(option.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : hovered == option.value ? DS.Ink.primary : DS.Ink.body)
                .lineLimit(1)
                .padding(.horizontal, fills ? 12 : 11)
                .frame(maxWidth: fills ? .infinity : nil)
                .frame(height: fills ? 28 : 24)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: DS.Radius.segmentInner, style: .continuous)
                            .fill(Color.white)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    } else if hovered == option.value {
                        RoundedRectangle(cornerRadius: DS.Radius.segmentInner, style: .continuous).fill(DS.Surface.chip)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = option.value
            } else if hovered == option.value {
                hovered = nil
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension SegmentedPicker where Value: CaseIterable, Value.AllCases == [Value] {
    /// Все варианты перечисления с подписью из `title`.
    init(selection: Binding<Value>, fills: Bool = true, title: (Value) -> String) {
        self.init(selection: selection, options: Value.allCases.map { Option(value: $0, title: title($0)) }, fills: fills)
    }
}

// MARK: - Тумблер

/// Тумблер в стиле панели: включён — синий, как акцент графиков.
/// Подпись (если есть) — слева, сам переключатель — справа.
struct PanelSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            configuration.label
            PanelSwitch(isOn: configuration.$isOn)
        }
    }
}

extension ToggleStyle where Self == PanelSwitchStyle {
    static var panel: PanelSwitchStyle { PanelSwitchStyle() }
}

private struct PanelSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? DS.Accent.on : Color.white.opacity(0.18))
                .frame(width: 32, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityValue(isOn ? L("включено", "on") : L("выключено", "off"))
    }
}

// MARK: - Группы и строки (настройки)

/// Группа строк на одной подложке, между строками — тонкая линия.
/// Заголовок группы — над ней, мелкими заглавными.
struct PanelGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                SectionTitle(title).padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(DS.Surface.hairline).frame(height: 1).padding(.leading, 12)
                        }
                        row
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).fill(DS.Surface.group))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).stroke(DS.Surface.groupBorder, lineWidth: 1))
        }
    }
}

/// Строка настройки: значок, название и пояснение слева, управление справа.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var icon: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Ink.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Ink.primary)
                if let detail {
                    Text(Typography.bind(detail))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.xs)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
    }
}

/// Строка с тумблером справа.
struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingRow(title, detail: detail) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.panel)
                .accessibilityLabel(title)
        }
        .contentShape(Rectangle())
        // Клик по всей строке тоже переключает — так проще попасть.
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } }
    }
}

/// Строка-переход: значок, название, значение справа и «›».
struct NavigationRow: View {
    let title: String
    var icon: String?
    var value: String?
    var showsChevron = true
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, icon: String? = nil, value: String? = nil, showsChevron: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.value = value
        self.showsChevron = showsChevron
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingRow(title, icon: icon) {
                HStack(spacing: 6) {
                    if let value {
                        Text(value)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(DS.Ink.secondary)
                    }
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(DS.Ink.secondary)
                    }
                }
            }
            .background(hovering ? DS.Surface.rowHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Выпадающий список

/// Выпадающий список в стиле полей ввода: значение, цветная метка и «⌃⌄».
/// Внутри — системное меню с галочкой у выбранного.
struct MenuPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        /// Цветная метка, как у проектов.
        var colorHex: String?
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    @State private var hovering = false

    var body: some View {
        let current = options.first { $0.value == selection }
        Menu {
            Picker(selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.value) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                if let hex = current?.colorHex {
                    Circle().fill(Color(hex: hex)).frame(width: 8, height: 8)
                }
                Text(current?.title ?? L("Выбрать", "Choose"))
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Ink.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: DS.Size.control)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Surface.input))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(hovering ? DS.Accent.focus : DS.Surface.inputBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

// MARK: - «‹ значение ›»

/// Выбор стрелками без календаря: месяц, день, час. Одна высота с полями ввода.
struct ValueStepper: View {
    let text: String
    var minWidth: CGFloat = 116
    var previousHelp = L("Назад", "Back")
    var nextHelp = L("Вперёд", "Forward")
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StepButton(systemImage: "chevron.left", help: previousHelp, action: onPrevious)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
                .frame(minWidth: minWidth)
            StepButton(systemImage: "chevron.right", help: nextHelp, action: onNext)
        }
        .frame(height: DS.Size.control)
        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Surface.input))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(DS.Surface.inputBorder, lineWidth: 1))
        .fixedSize()
    }
}

private struct StepButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering ? DS.Ink.primary : DS.Ink.secondary)
                .frame(width: 28, height: DS.Size.control)
                .background(RoundedRectangle(cornerRadius: DS.Radius.field - 2, style: .continuous).fill(hovering ? DS.Surface.chip : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// «‹ Октябрь 2026 ›».
struct MonthStepper: View {
    @Binding var month: YearMonth

    var body: some View {
        ValueStepper(
            text: Words.monthYear(month), previousHelp: L("Предыдущий месяц", "Previous month"), nextHelp: L("Следующий месяц", "Next month"),
            onPrevious: { month = month.previous }, onNext: { month = month.next }
        )
    }
}

/// «‹ 18 октября ›» и «Сегодня», если выбран другой день. Год — только если не текущий.
struct DayStepper: View {
    @Binding var date: Date

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ValueStepper(
                text: Self.text(date), previousHelp: L("День назад", "Previous day"), nextHelp: L("День вперёд", "Next day"),
                onPrevious: { step(-1) }, onNext: { step(1) }
            )
            if !Calendar.current.isDateInToday(date) {
                PillButton(L("Сегодня", "Today")) { date = Date() }
            }
        }
    }

    private func step(_ days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func text(_ date: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.day, .month, .year], from: date)
        let isThisYear = parts.year == calendar.component(.year, from: Date())
        return Words.dayMonth(parts.day ?? 1, parts.month ?? 1, year: isThisYear ? nil : parts.year)
    }
}

/// «‹ 22:00 ›» — час по кругу.
struct HourStepper: View {
    @Binding var hour: Int

    var body: some View {
        ValueStepper(
            text: String(format: "%02d:00", hour), minWidth: 64, previousHelp: L("На час раньше", "An hour earlier"), nextHelp: L("На час позже", "An hour later"),
            onPrevious: { hour = (hour + 23) % 24 }, onNext: { hour = (hour + 1) % 24 }
        )
    }
}
