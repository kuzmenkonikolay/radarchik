import SwiftUI
import RadarchikCore

/// Облик маскота. Логика у всех одна (`MascotBrain`): состояние, огонёк, взгляд.
/// Меняется только рисовка. Выбирается в настройках, переключается на лету.
///
/// Финальный облик — Живая чёлка (решено 2026-10-18): у неё одно лицо на всю
/// панель (`NotchFace`). Домовой и Радарчик остались запасными и рисуются
/// по-старому — портретом слева от фразы.
enum MascotSkin: String, CaseIterable, Identifiable {
    case livingNotch
    case domovoy
    case radarchik

    var id: Self { self }

    var title: String {
        switch self {
        case .radarchik: L("Радарчик", "Radarchik")
        case .domovoy: L("Домовой", "Domovoi")
        case .livingNotch: L("Живая чёлка", "Living Notch")
        }
    }

    /// «Подбородок» под вырезом в свёрнутой чёлке — там глаза.
    /// Внутри самого выреза пикселей нет, поэтому лицо — ниже него.
    var bump: CGSize {
        switch self {
        case .radarchik: .zero
        case .domovoy: CGSize(width: 58, height: 18)
        case .livingNotch: CGSize(width: 46, height: 15)
        }
    }
}

/// Персонаж в раскрытой чёлке.
struct MascotPortrait: View {
    var skin: MascotSkin
    var state: MascotState
    var signal: AntennaSignal
    var gaze: CGPoint = .zero

    var body: some View {
        switch skin {
        case .radarchik:
            MascotView(state: state, antenna: signal, gaze: gaze)
        case .domovoy:
            DomovoyPortrait(state: state, signal: signal, gaze: gaze)
        case .livingNotch:
            // В приложении её лицо рисует `NotchFace`; портрет — только для листа.
            // Рамка лица — глаза, рот висит ниже: поднимаем, чтобы всё было по центру.
            let scale = FacePlacement.hero.scale
            LivingNotchFace(state: state, signal: signal, gaze: gaze, scale: scale)
                .offset(y: -(LivingNotchFace.fullHeight - LivingNotchFace.eyeSize.height) * scale / 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Свёрнутая чёлка: крылья по бокам выреза и «подбородок» под ним.
/// Чёрную фигуру рисует `NotchRootView` (`NotchShape` с тем же `bump`) по размеру
/// этого вида, а лицо Живой чёлки — `NotchFace` поверх: здесь под него только место.
///
/// Крылья — по содержимому (`NotchWings`): без цифр их нет, с цифрами — ровно
/// под них, обе стороны одной ширины. Цифры отступают от края фигуры с её
/// скруглением, чтобы не начинаться прямо у кромки.
struct CollapsedMascot: View {
    var skin: MascotSkin
    var state: MascotState
    var signal: AntennaSignal
    var gaze: CGPoint = .zero
    /// Если задана, взгляд берётся из неё: на движение мыши перерисовывается
    /// только лицо, а не вся свёрнутая чёлка с подсчётом денег.
    var gazeModel: NotchViewModel?
    var notchSize: CGSize
    /// Цифры по бокам (настройка «Цифры по бокам чёлки»): слева деньги, справа система.
    var leading: [WingItem] = []
    var trailing: [WingItem] = []

    /// От внешнего края фигуры: 6 pt занимает её вогнутое плечо, дальше 12 pt воздуха.
    static let outerPadding: CGFloat = 18
    /// От выреза: он тоже чёрный, поэтому меньше.
    static let innerPadding: CGFloat = 12

    var body: some View {
        let resting = state == .sleep
        VStack(spacing: 0) {
            NotchWings(notchWidth: notchSize.width) {
                // У Радарчика слева ухо-локатор, справа огонёк; у Домового справа фонарик.
                WingStack(items: leading, edge: .leading, hasExtra: skin == .radarchik) {
                    if skin == .radarchik { MascotEar(isResting: resting) }
                }
                WingStack(items: trailing, edge: .trailing, hasExtra: skin != .livingNotch) {
                    switch skin {
                    case .radarchik: AntennaLight(signal: signal, caught: state == .catchCoin, isResting: resting)
                    case .domovoy: DomovoyLanternLight(signal: signal, isResting: resting)
                    case .livingNotch: EmptyView()
                    }
                }
            }
            .frame(height: notchSize.height)

            if skin.bump != .zero {
                BumpFace(skin: skin, state: state, signal: signal, fixedGaze: gaze, model: gazeModel)
                    .frame(width: skin.bump.width, height: skin.bump.height)
            }
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

/// Одно крыло: детали облика у края и цифры. Пустое — нулевой ширины, без отступов
/// (раскладке нужен ровно один вид на крыло, поэтому пустота — `Color.clear`).
private struct WingStack<Extra: View>: View {
    let items: [WingItem]
    let edge: HorizontalEdge
    let hasExtra: Bool
    @ViewBuilder var extra: Extra

    var body: some View {
        if items.isEmpty && !hasExtra {
            Color.clear.frame(width: 0, height: 0)
        } else {
            HStack(spacing: 8) {
                if edge == .leading { extra }
                ForEach(items) { WingItemView(item: $0) }
                if edge == .trailing { extra }
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

/// Лицо в подбородке. Читает взгляд из модели само, чтобы родитель не перерисовывался.
private struct BumpFace: View {
    var skin: MascotSkin
    var state: MascotState
    var signal: AntennaSignal
    var fixedGaze: CGPoint
    var model: NotchViewModel?

    var body: some View {
        let gaze = model?.gaze ?? fixedGaze
        switch skin {
        case .domovoy: DomovoyPeek(state: state, gaze: gaze)
        // Её лицо рисует `NotchFace` поверх всей панели.
        case .livingNotch, .radarchik: Color.clear
        }
    }
}
