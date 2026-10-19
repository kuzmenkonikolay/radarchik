import SwiftUI
import RadarchikCore

/// Итог по месяцам — проекта или всех проектов сразу: столбики от нулевой линии.
///
/// Плюс — зелёный вверх, минус — оранжевый вниз. Знак читается и без цвета,
/// по положению, а пару цветов проверял валидатор на дальтонизм (DS.Money).
/// Одна серия, поэтому легенды нет: её заменяет заголовок. Значения подписаны
/// выборочно: при наведении сумма столбика показывается в строке над графиком.
/// На экране проекта клик выбирает месяц — экран переключается на него, так что
/// любая сумма доступна и без наведения.
///
/// Месяц, который ещё идёт, — штрихованный столбик того же цвета: итог ещё поменяется.
struct NetBarsChart: View {
    let points: [MonthPoint]
    let currency: Currency
    let selected: YearMonth
    /// Текущий месяц: его итог «пока».
    var inProgress: YearMonth?
    /// Строка над графиком, пока не наводишь: слева заголовок, справа — подпись
    /// и сумма («октябрь пока +34,9к ₽»).
    var title = L("Итог по месяцам", "Net by month")
    var note: (label: String, amount: Int64)?
    /// nil — месяц кликом не выбирается (сводка).
    var onSelect: ((YearMonth) -> Void)?

    @State private var hovered: YearMonth?
    @Environment(\.chartReveal) private var reveal

    /// Спецификация меток: столбик не толще 24pt, скругление 4pt только на конце данных.
    private let barWidth: CGFloat = 20
    private let plotHeight: CGFloat = 64

    var body: some View {
        let values = points.map(\.figures.net)
        let maxPositive = max(values.max() ?? 0, 0)
        let maxNegative = max(-(values.min() ?? 0), 0)
        let span = max(maxPositive + maxNegative, 1)
        // Высота над нулевой линией; ниже — место для минусов.
        let zeroY = plotHeight * CGFloat(maxPositive) / CGFloat(span)

        VStack(alignment: .leading, spacing: 6) {
            readout

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(DS.Surface.baseline)
                    .frame(height: 1)
                    .offset(y: min(max(zeroY - 0.5, 0), plotHeight - 1))
                HStack(spacing: 0) {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        bar(point, zeroY: zeroY, span: span, growth: growth(of: index))
                    }
                }
            }
            .frame(height: plotHeight)

            HStack(spacing: 0) {
                ForEach(points) { point in
                    Text(Words.monthShort(point.month.month))
                        .font(.system(size: 10, weight: point.month == selected ? .semibold : .regular))
                        .foregroundStyle(point.month == selected ? DS.Ink.primary : DS.Ink.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(points.map { "\(Words.monthName($0.month.month)): \(MoneyFormat.signedFull($0.figures.net, currency))" }.joined(separator: ", "))
    }

    /// Строка над графиком: заголовок, а при наведении — сумма месяца
    /// (значение впереди, подпись после).
    @ViewBuilder
    private var readout: some View {
        if let hovered, let point = points.first(where: { $0.month == hovered }) {
            HStack(spacing: 6) {
                Text(MoneyFormat.signedFull(point.figures.net, currency))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.primary)
                Text(Language.current == .ru ? Words.monthYear(point.month).lowercased() : Words.monthYear(point.month))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Ink.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Ink.muted)
                Spacer(minLength: DS.Spacing.xs)
                if let note {
                    Text(note.label)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Ink.secondary)
                    Text(MoneyFormat.compact(note.amount, currency, signed: true))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.Money.text(for: note.amount))
                }
            }
        }
    }

    /// Ролик выращивает столбики по очереди, слева направо; в приложении все сразу целиком.
    private func growth(of index: Int) -> CGFloat {
        guard reveal < 1 else { return 1 }
        let x = min(max(reveal * 1.6 - CGFloat(index) * 0.12, 0), 1)
        return 1 - pow(1 - x, 3)
    }

    private func bar(_ point: MonthPoint, zeroY: CGFloat, span: Int64, growth: CGFloat) -> some View {
        let net = point.figures.net
        let isPositive = net >= 0
        let height = net == 0 ? 0 : max(plotHeight * CGFloat(net.magnitude) / CGFloat(span), 2) * growth
        let isHovered = hovered == point.month
        let isRunning = point.month == inProgress
        let color = isPositive ? DS.Money.positiveBar : DS.Money.negativeBar
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isPositive ? 4 : 0,
            bottomLeadingRadius: isPositive ? 0 : 4,
            bottomTrailingRadius: isPositive ? 0 : 4,
            topTrailingRadius: isPositive ? 4 : 0
        )
        return ZStack(alignment: .top) {
            // Невидимая мишень на всю высоту: навести проще, чем попасть в тонкий столбик.
            Color.clear
            shape
                .fill(color.opacity(isRunning ? 0.25 : 1))
                .overlay {
                    if isRunning && height > 0 {
                        Hatch().stroke(color, lineWidth: 1.5).clipShape(shape)
                        shape.strokeBorder(color, lineWidth: 1)
                    }
                }
                .brightness(isHovered ? 0.12 : 0)
                .frame(width: barWidth, height: height)
                .offset(y: isPositive ? zeroY - height : zeroY)
        }
        .frame(maxWidth: .infinity)
        .frame(height: plotHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = point.month
            } else if hovered == point.month {
                hovered = nil
            }
        }
        .onTapGesture { onSelect?(point.month) }
    }
}

extension EnvironmentValues {
    /// Какая доля столбиков уже выросла, 0…1: ролик выращивает график по кадрам.
    @Entry var chartReveal: CGFloat = 1
}

/// Штриховка под 45°: линии с шагом `spacing` на всю фигуру (обрезает её `clipShape`).
private struct Hatch: Shape {
    var spacing: CGFloat = 4.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
