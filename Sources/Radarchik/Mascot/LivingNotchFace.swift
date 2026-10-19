import SwiftUI
import RadarchikCore

/// «Живая чёлка» (выбрана 2026-10-18): персонаж — сам вырез. Чёрная капля,
/// а под вырезом из темноты светятся глаза цветом настроения денег.
/// Мимика — глазами, в раскрытом виде ещё и ртом.
///
/// Лицо одно на всю панель: его рисует `NotchFace` поверх фигуры, и при
/// раскрытии те же глаза растут и съезжают на сводку (`FacePlacement`).
/// `scale` 1 — размер в подбородке свёрнутой чёлки (глаза 7×9 pt). Он
/// анимируемый: SwiftUI рисует каждый промежуточный размер, а не скачок.
///
/// Рамка вида — только глаза: рот и капля пота висят поверх, поэтому
/// ставить лицо на место можно по центру глаз.
struct LivingNotchFace: View, Animatable {
    var state: MascotState
    var signal: AntennaSignal
    /// −1…1, y вниз.
    var gaze: CGPoint = .zero
    var scale: CGFloat = 1
    /// Насколько веки прикрыты сверх позы, 0…1. Ролик (`PromoRenderer`) так моргает
    /// и «просыпается» по кадрам; в приложении 0 — моргает сама (`blinkLoop`).
    var lids: CGFloat = 0
    /// Рисовка глаз (`EyeStyle`), выбирается в настройках.
    var eyes: EyeStyle = .capsule
    /// Время ролика или листа. Задано — развёртка радара считается от него,
    /// а не бежит сама (`sweepLoop`): ImageRenderer рисует кадр, циклы не идут.
    var clock: TimeInterval?

    /// Глаз в масштабе 1, расстояние между глазами, рот под ними.
    /// nonisolated: по этим размерам раскладывают панель и считают взгляд вне вида.
    nonisolated static let eyeSize = CGSize(width: 7, height: 9)
    nonisolated static let eyeSpacing: CGFloat = 15
    nonisolated static let mouthGap: CGFloat = 3
    nonisolated static let mouthHeight: CGFloat = 4
    /// Лицо со ртом в масштабе 1: глаза, отступ, рот.
    nonisolated static var fullHeight: CGFloat { eyeSize.height + mouthGap + mouthHeight }

    // nonisolated: SwiftUI зовёт это вне главного актора, а `scale` — просто число.
    nonisolated var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    @State private var blinking = false
    /// Куда косится сам, пока курсор далеко (см. `lookAroundLoop`).
    @State private var glance: CGPoint = .zero
    /// Где развёртка радара, 0…1 (см. `sweepLoop`).
    @State private var sweep: CGFloat = 0

    var body: some View {
        // Рот проявляется по мере раскрытия: в подбородке для него нет места.
        let mouthOpacity = min(max((scale - 1.4) / 0.8, 0), 1)
        // Курсор рядом — смотрит на него, далеко — озирается сам.
        let look = gaze == .zero ? glance : gaze
        HStack(spacing: Self.eyeSpacing * scale) {
            eye(isLeft: true, look: look)
            eye(isLeft: false, look: look)
        }
        .overlay(alignment: .bottom) {
            FaceMouth(kind: FaceMouth.Kind(state))
                .stroke(eyeColor.opacity(0.8), style: mouthStroke)
                .frame(width: 12 * scale, height: Self.mouthHeight * scale)
                .offset(y: (Self.mouthGap + Self.mouthHeight) * scale)
                .opacity(mouthOpacity)
        }
        .overlay(alignment: .topTrailing) { accessory }
        // Смотрит всем лицом: глаза и рот сдвигаются вместе.
        .offset(x: look.x * 3 * scale, y: look.y * 1.5 * scale)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: state)
        .animation(.easeOut(duration: 0.15), value: gaze)
        .task(id: state == .sleep) { await blinkLoop() }
        .task(id: canLookAround) { await lookAroundLoop() }
        .task(id: sweepingState) { await sweepLoop() }
        .accessibilityLabel(L("Живая чёлка", "Living Notch"))
    }

    // MARK: - Глаза

    private var eyeColor: Color {
        switch state {
        case .tipWave: .white
        case .catchCoin: DS.Mascot.coin
        case .sleep, .onCall: DS.antenna(.dim)
        default: DS.antenna(signal)
        }
    }

    /// Спит или притих на звонке — глаза не светятся.
    private var glows: Bool { state != .sleep && state != .onCall }

    private func eye(isLeft: Bool, look: CGPoint) -> some View {
        let size = CGSize(width: Self.eyeSize.width * scale, height: Self.eyeSize.height * scale)
        var pose = EyePose(state: state, isLeft: isLeft)
        if blinking { pose.openness = 0.1 }
        if lids > 0 { pose.openness = min(pose.openness, max(1 - lids, 0.1)) }
        return styledEye(pose: pose, look: look)
            // Рамка — капсула при любой рисовке: по ней раскладка и рот.
            // Радар и матрица чуть выходят за неё, это нормально.
            .frame(width: size.width, height: size.height)
            .shadow(color: eyeColor.opacity(glows ? 0.85 : 0), radius: 3 * scale)
            .overlay {
                // Доход: глаза-монетки поверх обычных. У матрицы монетка своя, из точек.
                if state == .catchCoin && eyes != .pixel {
                    CoinEye(scale: scale)
                        .frame(width: size.height, height: size.height)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                // Готовы советы: искорка у глаза — «есть идея».
                if state == .tipWave {
                    Circle().fill(.white)
                        .frame(width: 2.4 * scale, height: 2.4 * scale)
                        .offset(x: 1.5 * scale, y: -1.5 * scale)
                        .transition(.opacity)
                }
            }
    }

    /// Рот — обводкой; у матрицы — пунктиром из круглых точек с тем же шагом, что в глазах.
    private var mouthStroke: StrokeStyle {
        guard eyes == .pixel else {
            return StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
        }
        let pitch = PixelEye.pitch(scale: scale)
        return StrokeStyle(lineWidth: pitch * 0.8, lineCap: .round, dash: [0, pitch])
    }

    @ViewBuilder
    private func styledEye(pose: EyePose, look: CGPoint) -> some View {
        switch eyes {
        case .capsule:
            EyeShape(pose: pose).fill(eyeColor)
        case .radar:
            RadarEye(pose: pose, color: eyeColor, look: look, sweep: clock.map(RadarEye.sweep(at:)) ?? sweep, scale: scale)
        case .pixel:
            PixelEye(pose: pose, color: eyeColor, look: look, isCoin: state == .catchCoin, scale: scale)
                // Табло стоит на месте, пока лицо плывёт за курсором: глаз по нему
                // перескакивает сам, на целую точку.
                .offset(x: -look.x * 3 * scale, y: -look.y * 1.5 * scale)
        case .cat:
            CatEye(pose: pose, color: eyeColor, look: look, pupil: CatEye.pupil(for: state), isDim: !glows, scale: scale)
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch state {
        case .nervous:
            // Капля пота.
            Capsule().fill(DS.antenna(.blue).opacity(0.9))
                .frame(width: 2.5 * scale, height: 4 * scale)
                .offset(x: 4 * scale, y: -2 * scale)
        case .sleep:
            Text("z").font(.system(size: 5.5 * scale, weight: .bold)).foregroundStyle(DS.Ink.muted)
                .offset(x: 5 * scale, y: -2 * scale)
        default:
            EmptyView()
        }
    }

    // MARK: - Сама по себе

    private func blinkLoop() async {
        guard state != .sleep else {
            blinking = false
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3...8)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.07)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.09)) { blinking = false }
        }
    }

    /// Озирается, только когда в покое сканирует, а курсор далеко
    /// (контроллер тогда ставит взгляд ровно в ноль).
    private var canLookAround: Bool { state == .idleScan && gaze == .zero }

    /// Раз в 20–45 секунд косится вниз в сторону, иногда — в обе, и возвращается.
    /// Просто характер: чёлка живая, а не нарисованная.
    private func lookAroundLoop() async {
        glance = .zero
        guard canLookAround else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 20...45)))
            guard !Task.isCancelled else { return }
            let side: CGFloat = Bool.random() ? 1 : -1
            withAnimation(.easeInOut(duration: 0.35)) { glance = CGPoint(x: side, y: 0.35) }
            try? await Task.sleep(for: .seconds(Double.random(in: 0.8...1.4)))
            guard !Task.isCancelled else { return }
            if Bool.random() {
                withAnimation(.easeInOut(duration: 0.5)) { glance = CGPoint(x: -side, y: 0.35) }
                try? await Task.sleep(for: .seconds(Double.random(in: 0.6...1.1)))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: 0.4)) { glance = .zero }
        }
    }

    /// Состояние, в котором бежит развёртка, или nil — у этих глаз её нет
    /// или время задаёт ролик (`clock`).
    private var sweepingState: MascotState? {
        eyes == .radar && clock == nil ? state : nil
    }

    /// Развёртка не крутится без конца: оборот, пауза, оборот. Так локатор
    /// «прислушивается», а чёлка не перерисовывается каждый кадр весь день.
    private func sweepLoop() async {
        // Состояние сменилось посреди оборота — начинаем с чистого экрана,
        // иначе следующий оборот «доедет» до той же единицы и не случится.
        withTransaction(Transaction(animation: nil)) { sweep = 0 }
        guard let state = sweepingState, let pause = RadarEye.pause(for: state) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: pause)))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: RadarEye.sweepDuration)) { sweep = 1 }
            try? await Task.sleep(for: .seconds(RadarEye.sweepDuration))
            // На 0 и на 1 развёртки не видно — возвращаем без анимации.
            withTransaction(Transaction(animation: nil)) { sweep = 0 }
        }
    }
}

/// Где лицо Живой чёлки:
/// - `chin` — в подбородке под вырезом: пока чёлка свёрнута и на внутренних
///   экранах (смотрит, как ты заполняешь форму);
/// - `hero` — крупно по центру сводки, со ртом: там оно говорит фразу.
///
/// Отсюда же берут размеры раскладка панели (`NotchRootView`) и взгляд
/// (`NotchController`), чтобы все трое сходились в одной точке.
enum FacePlacement: Equatable {
    case chin
    case hero

    init(isExpanded: Bool, route: Route?) {
        self = isExpanded && route == nil ? .hero : .chin
    }

    var scale: CGFloat {
        switch self {
        case .chin: 1
        case .hero: 2.4
        }
    }

    /// Центр глаз от верхнего края фигуры.
    func eyeCenterY(notchHeight: CGFloat) -> CGFloat {
        switch self {
        case .chin: notchHeight + NotchShape.chin.height / 2
        case .hero: notchHeight + Self.heroTopInset + LivingNotchFace.eyeSize.height * scale / 2
        }
    }

    /// Сколько под вырезом занимает лицо: ниже начинается содержимое панели.
    var contentTop: CGFloat {
        switch self {
        // Глаза в полосе 3…12 pt под вырезом, дальше 8 pt воздуха.
        case .chin: 20
        // Глаза, рот и 4 pt до кончика хвостика облачка.
        case .hero: Self.heroTopInset + LivingNotchFace.fullHeight * scale + 4
        }
    }

    private static let heroTopInset: CGFloat = 6
}

/// Лицо на своём месте: центр глаз — на `eyeCenterY` от верха фигуры, по центру.
/// Отдельно от `NotchFace`, чтобы лист с картинками рисовал то же самое без моделей.
struct PlacedLivingFace: View {
    var state: MascotState
    var signal: AntennaSignal
    var gaze: CGPoint = .zero
    var scale: CGFloat
    var eyeCenterY: CGFloat
    var lids: CGFloat = 0
    var eyes: EyeStyle = .capsule
    var clock: TimeInterval?

    var body: some View {
        LivingNotchFace(state: state, signal: signal, gaze: gaze, scale: scale, lids: lids, eyes: eyes, clock: clock)
            .padding(.top, eyeCenterY - LivingNotchFace.eyeSize.height * scale / 2)
            // Лицо не ловит клики: под ним кнопки и поля.
            .allowsHitTesting(false)
    }
}

/// Поза глаза: насколько открыт, прикрыт веком, наклон века, улыбка.
/// Все величины анимируются, поэтому мимика перетекает, а не скачет.
struct EyePose: Equatable {
    /// 0 — закрыт (чёрточка), 1 — открыт.
    var openness: CGFloat
    /// Сколько сверху закрыто веком, 0…1.
    var cover: CGFloat
    /// Наклон века −1…1: брови «домиком» или хмуро.
    var tilt: CGFloat
    /// 0…1: снизу «откусывается» дуга — глаз становится радостным «^».
    var smile: CGFloat

    init(openness: CGFloat, cover: CGFloat, tilt: CGFloat, smile: CGFloat) {
        self.openness = openness
        self.cover = cover
        self.tilt = tilt
        self.smile = smile
    }

    init(state: MascotState, isLeft: Bool) {
        switch state {
        case .idleScan, .peek:
            // Хитрый прищур всезнайки: левый глаз прикрыт сильнее.
            self.init(openness: 1, cover: isLeft ? 0.38 : 0.22, tilt: 0, smile: 0)
        case .write:
            self.init(openness: 1, cover: 0.45, tilt: 0, smile: 0)
        case .happy:
            self.init(openness: 1, cover: 0, tilt: 0, smile: 1)
        case .worried:
            self.init(openness: 1, cover: 0.3, tilt: isLeft ? -0.35 : 0.35, smile: 0)
        case .nervous:
            self.init(openness: 0.8, cover: 0.15, tilt: isLeft ? 0.25 : -0.25, smile: 0)
        case .tipWave:
            self.init(openness: 1.08, cover: 0, tilt: 0, smile: 0)
        case .catchCoin:
            self.init(openness: 1, cover: 0, tilt: 0, smile: 0.4)
        case .sleep:
            self.init(openness: 0.12, cover: 0, tilt: 0, smile: 0)
        case .onCall:
            // Притих: глаза полуприкрыты, смотрит спокойно и не отвлекает.
            self.init(openness: 0.6, cover: 0.35, tilt: 0, smile: 0)
        }
    }

    typealias Vector = AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>

    /// Все четыре величины разом — `animatableData` для всех рисовок глаза.
    var vector: Vector {
        get { AnimatablePair(AnimatablePair(openness, cover), AnimatablePair(tilt, smile)) }
        set {
            self = EyePose(openness: newValue.first.first, cover: newValue.first.second, tilt: newValue.second.first, smile: newValue.second.second)
        }
    }
}

/// Один глаз на все эмоции: капсула, срезанная веком сверху и «улыбкой» снизу.
struct EyeShape: Shape {
    var pose: EyePose

    var animatableData: EyePose.Vector {
        get { pose.vector }
        set { pose.vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let height = max(rect.height * pose.openness, rect.height * 0.12)
        let eyeRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        var eye = Path(roundedRect: eyeRect, cornerRadius: min(rect.width, height) / 2)

        // Веко: оставляем только то, что ниже наклонной линии.
        if pose.cover > 0.001 || abs(pose.tilt) > 0.001 {
            let base = eyeRect.minY + eyeRect.height * pose.cover
            let slope = eyeRect.height * 0.35 * pose.tilt
            var visible = Path()
            visible.move(to: CGPoint(x: eyeRect.minX - 1, y: base - slope))
            visible.addLine(to: CGPoint(x: eyeRect.maxX + 1, y: base + slope))
            visible.addLine(to: CGPoint(x: eyeRect.maxX + 1, y: eyeRect.maxY + 1))
            visible.addLine(to: CGPoint(x: eyeRect.minX - 1, y: eyeRect.maxY + 1))
            visible.closeSubpath()
            eye = eye.intersection(visible)
        }

        // Улыбка: снизу вычитаем эллипс — получается полумесяц «^».
        if pose.smile > 0.001 {
            let bite = eyeRect.height * 0.75 * pose.smile
            let biteRect = CGRect(
                x: eyeRect.minX - eyeRect.width * 0.2,
                y: eyeRect.maxY - bite * 0.55,
                width: eyeRect.width * 1.4,
                height: bite * 1.5
            )
            eye = eye.subtracting(Path(ellipseIn: biteRect))
        }
        return eye
    }
}

/// Глаз-монетка: золотой кружок с ободком и бликом. Без знака валюты —
/// у проектов валюты разные.
private struct CoinEye: View {
    var scale: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(DS.Mascot.coin)
            Circle()
                .strokeBorder(.black.opacity(0.22), lineWidth: 0.8 * scale)
                .padding(1.3 * scale)
            // Блик слева сверху.
            Circle().fill(.white.opacity(0.75))
                .frame(width: 1.8 * scale, height: 1.8 * scale)
                .offset(x: -1.8 * scale, y: -1.8 * scale)
        }
        .shadow(color: DS.Mascot.coin.opacity(0.8), radius: 3 * scale)
    }
}

/// Рот Живой чёлки.
struct FaceMouth: Shape {
    enum Kind {
        case smirk, smile, worried, wavy, flat

        init(_ state: MascotState) {
            switch state {
            case .happy, .catchCoin, .tipWave: self = .smile
            case .worried: self = .worried
            case .nervous: self = .wavy
            case .sleep, .onCall: self = .flat
            case .idleScan, .peek, .write: self = .smirk
            }
        }
    }

    var kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .smirk:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY))
        case .smile:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.5))
        case .worried:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        case .wavy:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                          control1: CGPoint(x: rect.minX + rect.width / 3, y: rect.minY),
                          control2: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.maxY))
        case .flat:
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.midY))
        }
        return path
    }
}
