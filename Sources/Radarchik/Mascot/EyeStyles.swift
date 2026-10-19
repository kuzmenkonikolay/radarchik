import SwiftUI
import RadarchikCore

/// Какими глазами смотрит Живая чёлка (2026-10-19). Поза у всех одна (`EyePose`):
/// веки, наклон, улыбка, моргание и взгляд работают одинаково — меняется рисовка.
///
/// Всё рисуется кодом, а не в Rive и не видео: глаз 7×9 pt, ему нужны чёткие
/// края в любом масштабе и мгновенная реакция на курсор, деньги и моргание.
enum EyeStyle: String, CaseIterable, Identifiable {
    /// Светящиеся капсулы — первые глаза Живой чёлки.
    case capsule
    /// Экранчики локатора: кольцо, зрачок-отметка и развёртка, что иногда пробегает по кругу.
    case radar
    /// Светодиодная матрица: глаз собран из точек и на курсор перескакивает на целую точку.
    case pixel
    /// Кошачьи: светящаяся радужка и зрачок-щель — от радости шире, от тревоги уже.
    case cat

    var id: Self { self }

    var title: String {
        switch self {
        case .capsule: L("Капсулы", "Capsules")
        case .radar: L("Радар", "Radar")
        case .pixel: L("Пиксели", "Pixels")
        case .cat: L("Кошачьи", "Cat")
        }
    }
}

// MARK: - Радар

/// Глаз-локатор: тусклый круглый экранчик с кольцом, зрачок — яркая отметка
/// цели, она смещается туда, куда смотрит лицо. Веки режут экранчик так же,
/// как капсулу. `sweep` 0…1 — где развёртка; 0 и 1 — её нет.
struct RadarEye: View {
    var pose: EyePose
    var color: Color
    var look: CGPoint
    var sweep: CGFloat
    var scale: CGFloat

    var body: some View {
        // Круг по высоте глаза: чуть шире капсулы, зато круглый.
        let d = LivingNotchFace.eyeSize.height * scale
        ZStack {
            Circle().fill(color.opacity(0.16))
            // Сетка локатора: внутреннее кольцо.
            Circle()
                .strokeBorder(color.opacity(0.35), lineWidth: 0.5 * scale)
                .padding(d * 0.22)
            RadarSweep(progress: sweep, color: color)
            Circle().strokeBorder(color, lineWidth: 1 * scale)
            Circle().fill(color)
                .brightness(0.25)
                .frame(width: d * 0.36, height: d * 0.36)
                .offset(x: look.x * d * 0.2, y: look.y * d * 0.16)
        }
        .frame(width: d, height: d)
        .mask { EyeShape(pose: pose) }
    }

    /// Сколько ждать между оборотами: чем тревожнее, тем чаще озирается.
    /// nil — развёртки нет (спит, на звонке, ловит монетку).
    static func pause(for state: MascotState) -> ClosedRange<Double>? {
        switch state {
        case .idleScan, .peek, .write: 4...8
        case .happy: 3...5
        case .worried: 1.8...3
        case .nervous: 0.5...1
        case .tipWave: 1.5...2.5
        case .catchCoin, .sleep, .onCall: nil
        }
    }

    static let sweepDuration = 1.1

    /// Развёртка по часам ролика или листа: оборот, пауза, оборот.
    static func sweep(at time: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: 2.6)
        return phase < sweepDuration ? phase / sweepDuration : 0
    }
}

/// Развёртка: яркий луч и тающий за ним след на четверть круга.
/// Появляется и гаснет плавно, чтобы не мигать в начале и в конце оборота.
private struct RadarSweep: View, Animatable {
    var progress: CGFloat
    var color: Color

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            guard progress > 0.001, progress < 0.999 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let fade = sin(.pi * progress)
            let head = Angle.degrees(-90 + 360 * progress)
            let steps = 12
            for step in 0..<steps {
                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(
                    center: center, radius: radius,
                    startAngle: head - .degrees(Double(step + 1) * 90 / Double(steps)),
                    endAngle: head - .degrees(Double(step) * 90 / Double(steps)),
                    clockwise: false
                )
                wedge.closeSubpath()
                context.fill(wedge, with: .color(color.opacity(0.55 * (1 - Double(step) / Double(steps)) * fade)))
            }
            var beam = Path()
            beam.move(to: center)
            beam.addLine(to: CGPoint(x: center.x + radius * cos(head.radians), y: center.y + radius * sin(head.radians)))
            context.stroke(beam, with: .color(color.opacity(fade)), style: StrokeStyle(lineWidth: radius * 0.16, lineCap: .round))
        }
    }
}

// MARK: - Пиксели

/// Глаз-матрица: сетка светодиодов, горят те, что внутри позы глаза. Точка
/// светится настолько, насколько её накрывает `EyeShape`, поэтому мимика
/// перетекает и здесь — точки плавно гаснут и зажигаются. Взгляд — скачком
/// на целую точку, как на табло.
struct PixelEye: View, Animatable {
    var pose: EyePose
    var color: Color
    var look: CGPoint
    /// Доход: вместо глаза — монетка-колечко из точек.
    var isCoin: Bool
    var scale: CGFloat

    /// Точек по ширине глаза: крупные читаются в подбородке, а не сливаются в сеточку.
    static let columns = 4
    /// На сколько точек взгляд уводит глаз по горизонтали и вертикали.
    private static let reach = (x: 2, y: 1)

    nonisolated var animatableData: EyePose.Vector {
        get { pose.vector }
        set { pose.vector = newValue }
    }

    /// Шаг светодиодов; по нему же точками рисуется рот.
    static func pitch(scale: CGFloat) -> CGFloat {
        LivingNotchFace.eyeSize.width * scale / CGFloat(columns)
    }

    var body: some View {
        let eye = CGSize(width: LivingNotchFace.eyeSize.width * scale, height: LivingNotchFace.eyeSize.height * scale)
        let pitch = Self.pitch(scale: scale)
        // По высоте — точка ровно в середине глаза, иначе закрытый глаз ляжет
        // между рядами двумя тусклыми полосками. По ширине — столбцы ровно
        // по краям глаза: при чётном их числе середина приходится между точками.
        let isEven = Self.columns.isMultiple(of: 2)
        // С запасом на взгляд и на полторы точки тусклого ореола вокруг.
        let half = (x: Int(eye.width / 2 / pitch) + Self.reach.x + 1, y: Int(eye.height / 2 / pitch) + Self.reach.y + 1)
        let columns = -half.x...(isEven ? half.x - 1 : half.x)
        let board = CGSize(width: CGFloat(columns.count) * pitch, height: CGFloat(2 * half.y + 1) * pitch)
        Canvas { context, size in
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let shift = CGPoint(x: (look.x * CGFloat(Self.reach.x)).rounded() * pitch, y: (look.y * CGFloat(Self.reach.y)).rounded() * pitch)
            let eyeRect = CGRect(
                x: middle.x - eye.width / 2 + shift.x, y: middle.y - eye.height / 2 + shift.y,
                width: eye.width, height: eye.height
            )
            let shape = isCoin ? Self.coin(in: eyeRect) : EyeShape(pose: pose).path(in: eyeRect)
            // Дальше этого светодиод фигуру не задевает — не проверяем его вовсе.
            let reachable = shape.boundingRect.insetBy(dx: -pitch / 3, dy: -pitch / 3)
            let dot = pitch * 0.8
            for row in -half.y...half.y {
                for column in columns {
                    let center = CGPoint(x: middle.x + (CGFloat(column) + (isEven ? 0.5 : 0)) * pitch, y: middle.y + CGFloat(row) * pitch)
                    // Покрытие по 3×3 точкам внутри светодиода: сглаживание без размытия.
                    var hits = 0
                    if reachable.contains(center) {
                        for dy in -1...1 {
                            for dx in -1...1 where shape.contains(CGPoint(x: center.x + CGFloat(dx) * pitch / 3, y: center.y + CGFloat(dy) * pitch / 3)) {
                                hits += 1
                            }
                        }
                    }
                    // Две трети накрыто — горит в полную. Погасшие вокруг глаза
                    // чуть видны, как на табло, и сходят на нет за полторы точки.
                    let lit = min(Double(hits) / 6, 1)
                    let away = hypot(
                        max(eyeRect.minX - center.x, 0, center.x - eyeRect.maxX),
                        max(eyeRect.minY - center.y, 0, center.y - eyeRect.maxY)
                    )
                    let off = 0.08 * max(1 - away / (1.6 * pitch), 0)
                    let alpha = off + (1 - off) * lit
                    guard alpha > 0.005 else { continue }
                    let rect = CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
                }
            }
        }
        .frame(width: board.width, height: board.height)
    }

    /// Монетка: круг по ширине глаза без середины.
    private static func coin(in rect: CGRect) -> Path {
        let outer = CGRect(x: rect.minX, y: rect.midY - rect.width / 2, width: rect.width, height: rect.width)
        return Path(ellipseIn: outer).subtracting(Path(ellipseIn: outer.insetBy(dx: outer.width * 0.3, dy: outer.height * 0.3)))
    }
}

// MARK: - Кошачьи

/// Кошачий глаз: светящаяся радужка, тёмный зрачок-щель и блик. Зрачок
/// смотрит туда же, куда лицо, а шириной показывает настроение (`pupil`).
struct CatEye: View {
    var pose: EyePose
    var color: Color
    var look: CGPoint
    /// Ширина зрачка в долях глаза: 0.13 — щёлочка, 0.6 — почти круг.
    var pupil: CGFloat
    /// Спит или на звонке: блик не горит в полную.
    var isDim: Bool
    var scale: CGFloat

    static func pupil(for state: MascotState) -> CGFloat {
        switch state {
        case .happy, .tipWave: 0.6
        case .catchCoin: 0.5
        case .idleScan, .peek, .write, .sleep, .onCall: 0.28
        case .worried: 0.2
        case .nervous: 0.13
        }
    }

    var body: some View {
        let w = LivingNotchFace.eyeSize.width * scale
        let h = LivingNotchFace.eyeSize.height * scale
        // Что видно между веком сверху и «улыбкой» снизу (см. `EyeShape`):
        // зрачок живёт там, иначе он сливается с вырезом и глаз становится аркой.
        let top = -h / 2 + h * pose.cover
        let bottom = h / 2 - h * 0.41 * pose.smile
        // Чем шире зрачок, тем он круглее: щель во весь глаз, круг — меньше по высоте.
        let roundness = (pupil - 0.13) / (0.6 - 0.13)
        let pupilHeight = min(h * (0.84 - 0.3 * roundness), (bottom - top) * 0.8)
        let pupilSize = CGSize(width: min(w * pupil, pupilHeight), height: pupilHeight)
        ZStack {
            // Радужка: к краю темнее — объём.
            Rectangle().fill(RadialGradient(
                colors: [color, color.mix(with: .black, by: 0.4)],
                center: .center, startRadius: 0, endRadius: h * 0.6
            ))
            Capsule().fill(.black.opacity(0.88))
                .frame(width: pupilSize.width, height: pupilSize.height)
                .offset(x: look.x * w * 0.18, y: (top + bottom) / 2 + look.y * h * 0.08)
            // Блик — под веком, а не над ним: опускается вместе с краем века.
            Circle().fill(.white.opacity(isDim ? 0.3 : 0.92))
                .frame(width: w * 0.26, height: w * 0.26)
                .offset(x: -w * 0.18, y: top + h * 0.2)
        }
        .frame(width: w, height: h)
        .mask { EyeShape(pose: pose) }
    }
}
