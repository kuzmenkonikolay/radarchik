import AppKit
import SwiftUI
import RadarchikCore

// Лицо Радарчика (дизайн v2, 2026-10-20): глаза и рот прямо в чёрной чёлке.
// Рисуется кодом в системе координат 120×80 и масштабируется до нужного
// размера: 120 — главное лицо, 34 — свёрнутая чёлка, 30 — пилюли и ползунок,
// 24 — чипы проектов в форме, 22 — строка меню.
//
// Модель параметрическая, а не набор жёстких путей: у каждого глаза — высота
// и наклон века, радиус верхней дуги и нижней; рот — три квадратичных кривых.
// Все числа лежат в `animatableData`, поэтому эмоции перетекают одна в другую.
// Пути из спеки — эталон для каждого состояния (`FaceGeometry.init(emotion:)`).

/// Вектор для анимации из произвольного числа чисел.
struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableVector { AnimatableVector(values: []) }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        AnimatableVector(values: zip(padded(lhs, rhs)).map(+))
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        AnimatableVector(values: zip(padded(lhs, rhs)).map(-))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func padded(_ lhs: AnimatableVector, _ rhs: AnimatableVector) -> ([Double], [Double]) {
        let count = max(lhs.values.count, rhs.values.count)
        return (
            lhs.values + Array(repeating: 0, count: count - lhs.values.count),
            rhs.values + Array(repeating: 0, count: count - rhs.values.count)
        )
    }

    private static func zip(_ pair: ([Double], [Double])) -> Zip2Sequence<[Double], [Double]> {
        Swift.zip(pair.0, pair.1)
    }
}

/// Цвет числами, чтобы он тоже интерполировался.
struct RGBA: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var values: [Double] { [r, g, b, a] }

    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}

/// Что показать лицу: эмоция, цвета, ручки, очки.
struct FaceSpec: Hashable {
    var emotion: FaceEmotion
    /// Цвет глаз и рта.
    var fill: Color
    /// Цвет свечения — состояние денег или цвет проекта.
    var glow: Color
    var hands: HandsMode = .none
    var glasses = false

    /// Главное лицо: тёплый белый, чуть подкрашенный цветом состояния.
    static func main(_ emotion: FaceEmotion, tone: Color, hands: HandsMode = .none, glasses: Bool = false) -> FaceSpec {
        FaceSpec(emotion: emotion, fill: DS.Tone.face.mix(with: tone, by: 0.3), glow: tone, hands: hands, glasses: glasses)
    }

    /// Мини-лицо проекта: целиком в его цвете.
    static func mini(_ emotion: FaceEmotion, color: Color) -> FaceSpec {
        FaceSpec(emotion: emotion, fill: color, glow: color)
    }

    /// Лицо проекта — по его настроению: эмоция и цвет из таблицы «Состояния → лицо».
    /// Без закрытого месяца — прищур в цвете проекта.
    static func project(_ mood: Mood?, colorHex: String, mini: Bool = false) -> FaceSpec {
        let emotion = mood?.emotion ?? .smug
        let color = mood.map(DS.tone) ?? Color(hex: colorHex)
        return mini ? .mini(emotion, color: color) : .main(emotion, tone: color)
    }
}

/// Параметры одного глаза в системе 120×80.
struct EyeParams: Equatable {
    /// Верх века (у капсулы — вершина дуги).
    var top: Double
    /// Внутренний угол выше на `tilt`, внешний — ниже: домиком (переживает) или хмуро.
    var tilt: Double
    /// Радиус верхней дуги; 0 — плоское веко.
    var round: Double
    /// Центр нижней дуги и её радиус по вертикали.
    var bottomY: Double
    var bottomRy: Double

    var values: [Double] { [top, tilt, round, bottomY, bottomRy] }

    static let smug = EyeParams(top: 26, tilt: 0, round: 0, bottomY: 33, bottomRy: 9)
    static let wide = EyeParams(top: 19, tilt: 0, round: 9, bottomY: 36, bottomRy: 9)
    static let worried = EyeParams(top: 28, tilt: 3, round: 0, bottomY: 33, bottomRy: 9)
    static let sad = EyeParams(top: 31, tilt: 3, round: 0, bottomY: 34, bottomRy: 7)
    static let squintRight = EyeParams(top: 31, tilt: 0, round: 0, bottomY: 34, bottomRy: 8)
}

/// Вся геометрия лица — то, что интерполируется между эмоциями.
struct FaceGeometry: Equatable {
    var left: EyeParams
    var right: EyeParams
    /// Глаза-дуги (happy, sleep): 0 — заливка, 1 — дуги.
    var arc: Double
    var arcEndY: Double
    var arcControlY: Double
    /// Рот: три квадратичных кривых — 7 точек (x, y).
    var mouth: [Double]
    var glasses: Double
    var handsVisible: Double
    var leftHand: CGPoint
    var rightHand: CGPoint
    var sweat: Double
    var fill: RGBA
    var glow: RGBA

    init(_ spec: FaceSpec) {
        switch spec.emotion {
        case .smug:
            left = .smug; right = .smug
            mouth = Self.quad((47, 57), (59, 63), (73, 54))
        case .wide:
            left = .wide; right = .wide
            mouth = Self.quad((53, 58), (60, 62), (67, 58))
        case .happy:
            left = .smug; right = .smug
            mouth = Self.quad((46, 54), (60, 67), (74, 54))
        case .worried:
            left = .worried; right = .worried
            mouth = [48, 59, 52, 56, 56, 59, 60, 62, 64, 59, 68, 56, 72, 59]
        case .sad:
            left = .sad; right = .sad
            mouth = Self.quad((49, 62), (60, 53), (71, 62))
        case .squint:
            left = .smug; right = .squintRight
            mouth = Self.quad((48, 58), (61, 62), (74, 51))
        case .sleep:
            left = .smug; right = .smug
            mouth = Self.quad((55, 58), (60, 60), (65, 58))
        }
        switch spec.emotion {
        case .happy: arc = 1; arcEndY = 37; arcControlY = 25
        case .sleep: arc = 1; arcEndY = 35; arcControlY = 41
        default: arc = 0; arcEndY = 36; arcControlY = 33
        }
        glasses = spec.glasses ? 1 : 0
        sweat = spec.emotion == .worried ? 1 : 0
        switch spec.hands {
        case .none: handsVisible = 0; leftHand = CGPoint(x: 12, y: 62); rightHand = CGPoint(x: 108, y: 62)
        case .down: handsVisible = 1; leftHand = CGPoint(x: 12, y: 62); rightHand = CGPoint(x: 108, y: 62)
        case .wave: handsVisible = 1; leftHand = CGPoint(x: 12, y: 62); rightHand = CGPoint(x: 111, y: 14)
        case .up: handsVisible = 1; leftHand = CGPoint(x: 9, y: 14); rightHand = CGPoint(x: 111, y: 14)
        }
        fill = RGBA(spec.fill)
        glow = RGBA(spec.glow)
    }

    init(vector v: [Double]) {
        func at(_ i: Int) -> Double { i < v.count ? v[i] : 0 }
        left = EyeParams(top: at(0), tilt: at(1), round: at(2), bottomY: at(3), bottomRy: at(4))
        right = EyeParams(top: at(5), tilt: at(6), round: at(7), bottomY: at(8), bottomRy: at(9))
        arc = at(10); arcEndY = at(11); arcControlY = at(12)
        mouth = (13..<27).map(at)
        glasses = at(27)
        handsVisible = at(28)
        leftHand = CGPoint(x: at(29), y: at(30))
        rightHand = CGPoint(x: at(31), y: at(32))
        sweat = at(33)
        fill = RGBA(r: at(34), g: at(35), b: at(36), a: at(37))
        glow = RGBA(r: at(38), g: at(39), b: at(40), a: at(41))
    }

    var vector: [Double] {
        // По частям и без неявного CGFloat → Double: одним выражением Swift из Xcode 16
        // (CI на macos-15) не успевал вывести типы.
        let hands = [Double(leftHand.x), Double(leftHand.y), Double(rightHand.x), Double(rightHand.y)]
        var values = left.values + right.values
        values += [arc, arcEndY, arcControlY]
        values += mouth
        values += [glasses, handsVisible]
        values += hands
        values += [sweat]
        values += fill.values
        values += glow.values
        return values
    }

    /// Одна квадратичная кривая как три: делим по де Кастельжо на 1/3 и 2/3 —
    /// тогда любой рот состоит из трёх кривых и перетекает в любой другой.
    static func quad(_ p0: (Double, Double), _ c: (Double, Double), _ p1: (Double, Double)) -> [Double] {
        func lerp(_ a: (Double, Double), _ b: (Double, Double), _ t: Double) -> (Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
        }
        func point(_ t: Double) -> (Double, Double) {
            let u = 1 - t
            return (u * u * p0.0 + 2 * u * t * c.0 + t * t * p1.0, u * u * p0.1 + 2 * u * t * c.1 + t * t * p1.1)
        }
        // Первый кусок: 0…1/3.
        let m1 = point(1 / 3)
        let c1 = lerp(p0, c, 1 / 3)
        // Остаток 1/3…1 — кривая (m1, c', p1), делим пополам.
        let cRest = lerp(c, p1, 1 / 3)
        let m2 = point(2 / 3)
        let c2 = lerp(m1, cRest, 0.5)
        let c3 = lerp(cRest, p1, 0.5)
        return [p0.0, p0.1, c1.0, c1.1, m1.0, m1.1, c2.0, c2.1, m2.0, m2.1, c3.0, c3.1, p1.0, p1.1]
    }
}

/// Само лицо: рисует геометрию в Canvas. Все числа анимируемые, поэтому
/// смена эмоции, моргание, взгляд и ручки перетекают.
struct FaceCanvas: View, Animatable {
    var geometry: FaceGeometry
    /// 0 — глаза открыты, 1 — закрыты.
    var blink: Double = 0
    /// −1…1 по осям, y вниз: глаза и рот смещаются к курсору.
    var look: CGPoint = .zero
    /// Качание правой ручки, −1…1.
    var wave: Double = 0

    nonisolated var animatableData: AnimatableVector {
        get { AnimatableVector(values: geometry.vector + [blink, look.x, look.y, wave]) }
        set {
            let v = newValue.values
            geometry = FaceGeometry(vector: Array(v.prefix(42)))
            func at(_ i: Int) -> Double { i < v.count ? v[i] : 0 }
            blink = at(42)
            look = CGPoint(x: at(43), y: at(44))
            wave = at(45)
        }
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let s = min(size.width / 120, size.height / 80)
            let isSmall = size.width < 50
            let origin = CGPoint(x: (size.width - 120 * s) / 2, y: (size.height - 80 * s) / 2)
            let transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: s, y: s)
            let glow = geometry.glow.color
            if isSmall {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: glow.opacity(0.8), radius: 2 * s))
                    draw(in: &layer, transform: transform, scale: s, isSmall: true)
                }
            } else {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: glow.opacity(0.5), radius: 16 * s))
                    draw(in: &layer, transform: transform, scale: s, isSmall: false)
                }
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: glow.opacity(0.8), radius: 4 * s))
                    draw(in: &layer, transform: transform, scale: s, isSmall: false)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Глаза, рот, очки, ручки и капля — в единицах 120×80, потом `transform`.
    private func draw(in context: inout GraphicsContext, transform: CGAffineTransform, scale s: Double, isSmall: Bool) {
        let fill = geometry.fill.color
        let dx = look.x * 5
        let dy = look.y * 2.5
        let shift = CGAffineTransform(translationX: dx, y: dy).concatenating(transform)

        // Глаза заливкой.
        if geometry.arc < 0.999 {
            let eyes = Self.eyePath(geometry.left, outerX: 31, innerX: 49, blink: blink)
                .union(Self.eyePath(geometry.right, outerX: 89, innerX: 71, blink: blink))
            context.fill(eyes.applying(shift), with: .color(fill.opacity(1 - geometry.arc)))
        }
        // Глаза-дуги: при моргании дуга распрямляется.
        if geometry.arc > 0.001 {
            let control = geometry.arcControlY + (geometry.arcEndY - geometry.arcControlY) * blink
            var arcs = Path()
            for cx in [40.0, 80.0] {
                arcs.move(to: CGPoint(x: cx - 9, y: geometry.arcEndY))
                arcs.addQuadCurve(to: CGPoint(x: cx + 9, y: geometry.arcEndY), control: CGPoint(x: cx, y: control))
            }
            context.stroke(
                arcs.applying(shift), with: .color(fill.opacity(geometry.arc)),
                style: StrokeStyle(lineWidth: (isSmall ? 7 : 4.5) * s, lineCap: .round)
            )
        }
        // Рот.
        let m = geometry.mouth
        var mouth = Path()
        mouth.move(to: CGPoint(x: m[0], y: m[1]))
        for i in stride(from: 2, to: 14, by: 4) {
            mouth.addQuadCurve(to: CGPoint(x: m[i + 2], y: m[i + 3]), control: CGPoint(x: m[i], y: m[i + 1]))
        }
        context.stroke(mouth.applying(shift), with: .color(fill), style: StrokeStyle(lineWidth: (isSmall ? 6 : 4) * s, lineCap: .round, lineJoin: .round))

        // Очки: две окружности и переносица.
        if geometry.glasses > 0.001 {
            var glasses = Path()
            glasses.addEllipse(in: CGRect(x: 40 - 15.5, y: 34 - 15.5, width: 31, height: 31))
            glasses.addEllipse(in: CGRect(x: 80 - 15.5, y: 34 - 15.5, width: 31, height: 31))
            glasses.move(to: CGPoint(x: 55.5, y: 32))
            glasses.addQuadCurve(to: CGPoint(x: 64.5, y: 32), control: CGPoint(x: 60, y: 29))
            context.stroke(glasses.applying(shift), with: .color(fill.opacity(0.85 * geometry.glasses)), style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
        }
        guard !isSmall else { return }

        // Ручки — две отдельные точки, не приклеены к лицу.
        if geometry.handsVisible > 0.001 {
            let r = 6 * geometry.handsVisible
            let right = CGPoint(x: geometry.rightHand.x + wave * 5, y: geometry.rightHand.y + wave * 3.4)
            var hands = Path()
            hands.addEllipse(in: CGRect(x: geometry.leftHand.x - r, y: geometry.leftHand.y - r, width: 2 * r, height: 2 * r))
            hands.addEllipse(in: CGRect(x: right.x - r, y: right.y - r, width: 2 * r, height: 2 * r))
            context.fill(hands.applying(transform), with: .color(fill))
        }
        // Капля пота — только у worried.
        if geometry.sweat > 0.001 {
            var drop = Path()
            drop.move(to: CGPoint(x: 101, y: 12))
            drop.addQuadCurve(to: CGPoint(x: 101, y: 25), control: CGPoint(x: 107, y: 21))
            drop.addQuadCurve(to: CGPoint(x: 101, y: 12), control: CGPoint(x: 95, y: 21))
            drop.closeSubpath()
            context.fill(drop.applying(transform), with: .color(DS.Tone.sweat.opacity(geometry.sweat)))
        }
    }

    /// Глаз: веко сверху (плоское, наклонное или дугой), прямые бока и нижняя дуга.
    /// Моргание опускает веко к нижней дуге, пока глаз не станет щёлочкой.
    static func eyePath(_ e: EyeParams, outerX: Double, innerX: Double, blink: Double) -> Path {
        let k = 4.0 / 3.0
        let round = e.round * (1 - blink)
        let tilt = e.tilt * (1 - blink)
        let lid = (e.top + e.round) + (e.bottomY - (e.top + e.round)) * blink
        let ry = e.bottomRy + (1.2 - e.bottomRy) * blink
        let yOuter = lid + tilt
        let yInner = lid - tilt
        var path = Path()
        path.move(to: CGPoint(x: outerX, y: yOuter))
        path.addCurve(
            to: CGPoint(x: innerX, y: yInner),
            control1: CGPoint(x: outerX, y: yOuter - k * round),
            control2: CGPoint(x: innerX, y: yInner - k * round)
        )
        path.addLine(to: CGPoint(x: innerX, y: e.bottomY))
        path.addCurve(
            to: CGPoint(x: outerX, y: e.bottomY),
            control1: CGPoint(x: innerX, y: e.bottomY + k * ry),
            control2: CGPoint(x: outerX, y: e.bottomY + k * ry)
        )
        path.closeSubpath()
        return path
    }
}

/// Живое лицо: моргает, косится по сторонам, дышит, машет ручкой — само,
/// пока его видно. Эмоция и взгляд приходят снаружи и перетекают анимацией.
struct FaceView: View {
    var spec: FaceSpec
    /// Взгляд к курсору, −1…1; ноль — смотрит прямо (тогда иногда косится сам).
    var look: CGPoint = .zero
    /// Прыжок вверх (пришли деньги), pt.
    var jump: CGFloat = 0
    /// Живёт ли: моргание и взгляды. Лист картинок рисует без них.
    var isLive = true
    /// Дышит — только пока панель раскрыта: в покое 0% CPU.
    var breathes = false

    @State private var blink = 0.0
    @State private var glance = CGPoint.zero
    @State private var wave = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let breathing = breathes && isLive && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !breathing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = breathing ? sin(t * .pi / 2) * 0.8 : 0
            FaceCanvas(geometry: FaceGeometry(spec), blink: blink, look: look == .zero ? glance : look, wave: wave)
                .offset(y: breath - jump)
        }
        .animation(DS.emotionAnimation, value: spec)
        .animation(DS.gazeAnimation, value: look)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: jump)
        .task(id: "\(isLive)-\(spec.emotion == .sleep)") { await blinkLoop() }
        .task(id: "\(isLive)-\(reduceMotion)-\(look == .zero)") { await glanceLoop() }
        .task(id: "\(isLive)-\(reduceMotion)-\(spec.hands == .wave)") { await waveLoop() }
        .accessibilityLabel(L("Радарчик", "Radarchik"))
    }

    /// Раз в 2–6 с: закрыть за 80 мс, открыть за 120 мс, в 15% случаев дважды. Спит — не моргает.
    private func blinkLoop() async {
        guard isLive, spec.emotion != .sleep else {
            blink = 0
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2...6)))
            guard !Task.isCancelled else { return }
            await blinkOnce()
            if Double.random(in: 0..<1) < 0.15 {
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                await blinkOnce()
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeIn(duration: 0.08)) { blink = 1 }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.easeOut(duration: 0.12)) { blink = 0 }
    }

    /// В простое раз в 4–10 с косится вбок на 0,6 с — просто характер.
    private func glanceLoop() async {
        glance = .zero
        guard isLive, !reduceMotion, look == .zero else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 4...10)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.22)) { glance = CGPoint(x: Bool.random() ? 1 : -1, y: 0.3) }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { glance = .zero }
        }
    }

    /// Машет: правая ручка качается три раза за 0,9 с, потом пауза.
    private func waveLoop() async {
        wave = 0
        guard isLive, !reduceMotion, spec.hands == .wave else { return }
        while !Task.isCancelled {
            for step in 0..<6 {
                withAnimation(.easeInOut(duration: 0.15)) { wave = step.isMultiple(of: 2) ? 1 : -1 }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: 0.2)) { wave = 0 }
            try? await Task.sleep(for: .seconds(Double.random(in: 3...5)))
        }
    }
}

/// Мини-лицо без жизни: пилюли проектов, чипы формы, ползунок разбора, строка меню.
struct MiniFace: View {
    var spec: FaceSpec
    var size: CGFloat

    init(_ spec: FaceSpec, size: CGFloat) {
        self.spec = spec
        self.size = size
    }

    var body: some View {
        FaceCanvas(geometry: FaceGeometry(spec))
            .frame(width: size, height: size * 2 / 3)
            .animation(DS.emotionAnimation, value: spec)
    }
}

/// Чип мини-лица: чёрный квадрат 36×30 с рамкой — в пилюлях проектов.
struct FaceChip: View {
    var spec: FaceSpec
    var size = DS.Size.faceChip
    var faceSize: CGFloat = 30

    var body: some View {
        MiniFace(spec, size: faceSize)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: DS.Radius.chip).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).stroke(DS.Surface.inputBorder, lineWidth: 1))
    }
}

// MARK: - Место для лица на экране

/// Где на экране стоит главное лицо. Экран ставит пустое место (`faceSlot`),
/// а само лицо одно на всю панель — `NotchRootView` рисует его поверх по якорю.
/// Так при раскрытии лицо перетекает из свёрнутой чёлки в карточку, а моргание
/// и эмоция не начинаются заново при смене экрана.
struct FaceSlot {
    var spec: FaceSpec
    var anchor: Anchor<CGRect>
    /// Чьё место главнее: видимого экрана, а не уходящего.
    var priority: Int
}

struct FaceSlotKey: PreferenceKey {
    static var defaultValue: FaceSlot? { nil }

    static func reduce(value: inout FaceSlot?, nextValue: () -> FaceSlot?) {
        guard let next = nextValue() else { return }
        if let current = value, current.priority > next.priority { return }
        value = next
    }
}

/// Размер лица: ширина, высота — 2/3.
func faceSize(_ width: CGFloat) -> CGSize { CGSize(width: width, height: width * 2 / 3) }

extension View {
    /// Отметить это место под главное лицо панели.
    func faceSlot(_ spec: FaceSpec, priority: Int = 1) -> some View {
        anchorPreference(key: FaceSlotKey.self, value: .bounds) { FaceSlot(spec: spec, anchor: $0, priority: priority) }
    }
}

/// Пустое место под лицо нужного размера.
struct FacePlaceholder: View {
    var spec: FaceSpec
    var width: CGFloat = 120
    var priority = 1

    var body: some View {
        let size = faceSize(width)
        Color.clear
            .frame(width: size.width, height: size.height)
            .faceSlot(spec, priority: priority)
    }
}

/// Бейдж-точка статуса у лица: круг 20 pt цвета состояния с обводкой 3 pt в цвет карточки.
struct StatusBadge: View {
    var color: Color
    var symbol: String?
    var text: String?

    var body: some View {
        ZStack {
            Circle().fill(color)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.8))
            } else if let text {
                Text(text)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.8))
            }
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().stroke(Color(red: 22 / 255, green: 23 / 255, blue: 28 / 255), lineWidth: 3))
    }
}
