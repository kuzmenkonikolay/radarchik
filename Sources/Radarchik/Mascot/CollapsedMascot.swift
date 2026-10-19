import SwiftUI
import RadarchikCore

/// Свёрнутая чёлка: крылья по бокам выреза и «подбородок» под ним.
/// Чёрную фигуру рисует `NotchRootView` (`NotchShape.collapsed`) по размеру
/// этого вида, а лицо — `NotchFace` поверх: здесь под него только место.
///
/// Облик один — Живая чёлка (Домовой и Радарчик убраны 2026-10-19),
/// меняются только глаза (`EyeStyle`).
///
/// Крылья — по содержимому (`NotchWings`): без цифр их нет, с цифрами — ровно
/// под них, обе стороны одной ширины. Цифры отступают от края фигуры с её
/// скруглением, чтобы не начинаться прямо у кромки.
struct CollapsedMascot: View {
    var notchSize: CGSize
    /// Цифры по бокам (настройка «Цифры по бокам чёлки»): слева деньги, справа система.
    var leading: [WingItem] = []
    var trailing: [WingItem] = []

    /// От внешнего края фигуры: 6 pt занимает её вогнутое плечо, дальше 12 pt воздуха.
    static let outerPadding: CGFloat = 18
    /// От выреза: он тоже чёрный, поэтому меньше.
    static let innerPadding: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            NotchWings(notchWidth: notchSize.width) {
                WingStack(items: leading, edge: .leading)
                WingStack(items: trailing, edge: .trailing)
            }
            .frame(height: notchSize.height)

            Color.clear.frame(width: NotchShape.chin.width, height: NotchShape.chin.height)
        }
    }
}

/// Что стоит в крыле свёрнутой чёлки: значок, текст и его цвет.
struct WingItem: Identifiable, Equatable {
    let id: String
    var icon: String?
    let text: String
    var color: Color = DS.Ink.secondary
    /// Самый широкий текст этого места («88%»): под него держим место, чтобы
    /// фигура не дёргалась каждые 5 секунд, когда меняются цифры.
    var widest: String?

    /// Что куда: слева деньги, справа система. Если чего-то одного нет, оставшееся
    /// делится на два крыла — ни одно не пустует (раньше правое могло пустовать).
    static func arrange(money: [WingItem], system: [WingItem]) -> (leading: [WingItem], trailing: [WingItem]) {
        switch (money.isEmpty, system.isEmpty) {
        case (false, false): (money, system)
        case (false, true): (Array(money.prefix(1)), Array(money.dropFirst()))
        case (true, false): (Array(system.prefix(1)), Array(system.dropFirst()))
        case (true, true): ([], [])
        }
    }
}

/// Крылья по бокам выреза. Обе стороны одной ширины — иначе фигура съедет
/// с центра выреза, — а ширина по более широкой стороне, не больше `maxWing`.
/// Первое крыло встаёт у левого края, второе — у правого, вырез — между ними.
struct NotchWings: Layout {
    var notchWidth: CGFloat
    /// Длинные суммы в нескольких валютах ужимаются, а не растягивают чёлку через всю строку меню.
    var maxWing: CGFloat = 190

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = proposal.height ?? sizes.map(\.height).max() ?? 0
        return CGSize(width: notchWidth + 2 * wing(sizes), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = wing(subviews.map { $0.sizeThatFits(.unspecified) })
        let proposal = ProposedViewSize(width: width, height: bounds.height)
        if let leading = subviews.first {
            leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: proposal)
        }
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: proposal)
        }
    }

    private func wing(_ sizes: [CGSize]) -> CGFloat {
        min(sizes.map(\.width).max() ?? 0, maxWing)
    }
}

/// Одно крыло — цифры. Пустое — нулевой ширины, без отступов
/// (раскладке нужен ровно один вид на крыло, поэтому пустота — `Color.clear`).
private struct WingStack: View {
    let items: [WingItem]
    let edge: HorizontalEdge

    var body: some View {
        if items.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else {
            HStack(spacing: 8) {
                ForEach(items) { WingItemView(item: $0) }
            }
            .padding(.leading, edge == .leading ? CollapsedMascot.outerPadding : CollapsedMascot.innerPadding)
            .padding(.trailing, edge == .leading ? CollapsedMascot.innerPadding : CollapsedMascot.outerPadding)
        }
    }
}

private struct WingItemView: View {
    let item: WingItem

    var body: some View {
        HStack(spacing: 3) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Ink.muted)
            }
            // Место под самый широкий текст: цифры меняются, ширина — нет.
            ZStack(alignment: .leading) {
                if let widest = item.widest { Text(widest).hidden() }
                Text(item.text).foregroundStyle(item.color)
            }
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}
