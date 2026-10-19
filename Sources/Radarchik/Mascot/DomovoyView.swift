import SwiftUI
import RadarchikCore

/// Домовой — хозяин мака. Живёт «за печкой», то есть в вырезе, бережёт казну,
/// ворчит на беспорядок, но он на твоей стороне. Настроение денег показывает
/// огонёк его фонарика. Эмоции в основном — бровями.
///
/// `DomovoyPortrait` — в раскрытой чёлке. `DomovoyPeek` — в свёрнутой: из темноты
/// под вырезом глядят глаза из-под лохматых бровей.
enum DomovoyPalette {
    static let furTop = Color(hex: "#C98A55")
    static let furBottom = Color(hex: "#8A5530")
    static let face = Color(hex: "#F0C49B")
    static let brow = Color(hex: "#F6F0E6")
    static let beard = Color(hex: "#F3E9DA")
    static let nose = Color(hex: "#E07F5C")
    static let shirt = Color(hex: "#D2452E")
    static let boots = Color(hex: "#9A958F")
    static let wood = Color(hex: "#A0683A")
    static let pupil = Color(hex: "#2A1A10")
}

struct DomovoyPortrait: View {
    var state: MascotState
    var signal: AntennaSignal
    var gaze: CGPoint = .zero

    @State private var blinking = false

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                boots(s)
                fur(s)
                hair(s)
                faceMask(s)
                eyes(s)
                brows(s)
                nose(s)
                beard(s)
                abacus(s)
                lantern(s)
                if state == .sleep { nightcap(s) }
                if state == .catchCoin { coin(s) }
                if state == .tipWave { exclamation(s) }
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: state)
        .animation(.easeOut(duration: 0.15), value: gaze)
        .task(id: state == .sleep) { await blinkLoop() }
        .accessibilityLabel(L("Домовой", "Domovoi"))
    }

    // MARK: - Тело

    private func fur(_ s: CGFloat) -> some View {
        ZStack {
            FurShape(bumps: 16, depth: 0.07)
                .fill(LinearGradient(colors: [DomovoyPalette.furTop, DomovoyPalette.furBottom], startPoint: .top, endPoint: .bottom))
            Ellipse().fill(.white.opacity(0.14))
                .frame(width: s * 0.26, height: s * 0.16)
                .rotationEffect(.degrees(-30))
                .offset(x: -s * 0.15, y: -s * 0.17)
        }
        .frame(width: s * 0.76, height: s * 0.72)
        .position(x: s * 0.47, y: s * 0.56)
    }

    /// Вихры на макушке.
    private func hair(_ s: CGFloat) -> some View {
        ZStack {
            Tuft().fill(DomovoyPalette.furTop).frame(width: s * 0.12, height: s * 0.16).rotationEffect(.degrees(-25)).offset(x: -s * 0.08)
            Tuft().fill(DomovoyPalette.furTop).frame(width: s * 0.13, height: s * 0.2)
            Tuft().fill(DomovoyPalette.furTop).frame(width: s * 0.11, height: s * 0.15).rotationEffect(.degrees(28)).offset(x: s * 0.09)
        }
        .position(x: s * 0.47, y: s * 0.2)
    }

    private func faceMask(_ s: CGFloat) -> some View {
        Ellipse()
            .fill(DomovoyPalette.face)
            .frame(width: s * 0.46, height: s * 0.31)
            .position(x: s * 0.47, y: s * 0.505)
    }

    private func eyes(_ s: CGFloat) -> some View {
        let shift = CGSize(width: gaze.x * s * 0.025, height: gaze.y * s * 0.02)
        return HStack(spacing: s * 0.05) {
            ForEach([true, false], id: \.self) { isLeft in
                ZStack {
                    if state == .sleep || state == .happy {
                        // Закрытые или радостные — дуги.
                        ArcEye()
                            .stroke(DomovoyPalette.pupil, style: StrokeStyle(lineWidth: max(s * 0.025, 1.2), lineCap: .round))
                            .frame(width: s * 0.10, height: s * 0.04)
                            .rotationEffect(.degrees(state == .sleep ? 180 : 0))
                    } else {
                        Ellipse().fill(.white).frame(width: s * 0.13, height: s * 0.14)
                        Circle().fill(DomovoyPalette.pupil).frame(width: s * 0.075, height: s * 0.075)
                            .offset(shift)
                        Circle().fill(.white.opacity(0.9)).frame(width: s * 0.02, height: s * 0.02)
                            .offset(x: shift.width + s * 0.012, y: shift.height - s * 0.012)
                        // Веко цвета лица: прищур всезнайки или моргание.
                        Rectangle().fill(DomovoyPalette.face)
                            .frame(width: s * 0.15, height: s * 0.14 * lidCover(isLeft: isLeft))
                            .frame(width: s * 0.15, height: s * 0.14, alignment: .top)
                    }
                }
                .frame(width: s * 0.14, height: s * 0.14)
                .clipShape(Ellipse())
            }
        }
        .position(x: s * 0.47, y: s * 0.50)
    }

    private func lidCover(isLeft: Bool) -> CGFloat {
        if blinking { return 1 }
        switch state {
        case .idleScan, .peek, .write: return isLeft ? 0.45 : 0.3
        case .worried: return 0.25
        case .nervous: return 0.1
        case .tipWave: return 0.05
        default: return 0.3
        }
    }

    /// Брови — главная мимика: хмурые, удивлённые, «домиком».
    private func brows(_ s: CGFloat) -> some View {
        let (left, right, lift): (Double, Double, CGFloat) = switch state {
        case .idleScan, .peek, .write: (14, -14, 0)          // хмурый всезнайка
        case .happy, .catchCoin: (-6, 6, -0.03)
        case .worried: (-18, 18, -0.01)                      // «домиком»
        case .nervous: (-10, 22, -0.02)
        case .tipWave: (-20, -4, -0.04)                      // одна бровь вверх: «а я говорил»
        case .sleep, .onCall: (4, -4, 0.01)
        }
        return HStack(spacing: s * 0.03) {
            Capsule().fill(DomovoyPalette.brow).frame(width: s * 0.18, height: s * 0.07).rotationEffect(.degrees(left))
            Capsule().fill(DomovoyPalette.brow).frame(width: s * 0.18, height: s * 0.07).rotationEffect(.degrees(right))
        }
        .position(x: s * 0.47, y: s * (0.405 + lift))
    }

    private func nose(_ s: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(DomovoyPalette.nose)
            Ellipse().fill(.white.opacity(0.35)).frame(width: s * 0.035, height: s * 0.02).offset(x: -s * 0.02, y: -s * 0.02)
        }
        .frame(width: s * 0.16, height: s * 0.12)
        .position(x: s * 0.47, y: s * 0.59)
    }

    private func beard(_ s: CGFloat) -> some View {
        ZStack {
            CloudShape()
                .fill(DomovoyPalette.beard)
                .frame(width: s * 0.46, height: s * 0.24)
            // Рот в бороде: ухмылка, улыбка, «ой».
            FaceMouth(kind: FaceMouth.Kind(state))
                .stroke(DomovoyPalette.pupil.opacity(0.7), style: StrokeStyle(lineWidth: max(s * 0.02, 1), lineCap: .round))
                .frame(width: s * 0.09, height: s * 0.03)
                .offset(y: -s * 0.02)
        }
        .position(x: s * 0.47, y: s * 0.735)
    }

    private func boots(_ s: CGFloat) -> some View {
        HStack(spacing: s * 0.07) {
            Capsule().fill(DomovoyPalette.boots).frame(width: s * 0.13, height: s * 0.08)
            Capsule().fill(DomovoyPalette.boots).frame(width: s * 0.13, height: s * 0.08)
        }
        .overlay(alignment: .top) {
            // Подол красной рубахи над валенками.
            Capsule().fill(DomovoyPalette.shirt).frame(width: s * 0.36, height: s * 0.06).offset(y: -s * 0.045)
        }
        .position(x: s * 0.47, y: s * 0.93)
    }

    /// Счёты в лапке: у домового всё посчитано. Пришёл доход — костяшки щёлкают.
    private func abacus(_ s: CGFloat) -> some View {
        let shifted = state == .catchCoin
        return ZStack {
            RoundedRectangle(cornerRadius: s * 0.02).fill(Color.black.opacity(0.35))
                .frame(width: s * 0.27, height: s * 0.18)
            RoundedRectangle(cornerRadius: s * 0.02).stroke(DomovoyPalette.wood, lineWidth: max(s * 0.025, 1.2))
                .frame(width: s * 0.27, height: s * 0.18)
            VStack(spacing: s * 0.035) {
                ForEach(0..<3, id: \.self) { row in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(DomovoyPalette.wood.opacity(0.9)).frame(width: s * 0.24, height: max(s * 0.01, 0.7))
                        HStack(spacing: s * 0.005) {
                            ForEach(0..<3, id: \.self) { bead in
                                Circle().fill(bead == 1 ? DomovoyPalette.shirt : DomovoyPalette.beard)
                                    .frame(width: s * 0.04, height: s * 0.04)
                            }
                        }
                        .offset(x: shifted && row == 1 ? s * 0.11 : s * 0.01)
                    }
                }
            }
            // Лапка, которая держит счёты.
            Circle().fill(DomovoyPalette.furTop).frame(width: s * 0.09, height: s * 0.09).offset(x: -s * 0.14, y: s * 0.04)
        }
        .rotationEffect(.degrees(-8))
        .position(x: s * 0.76, y: s * 0.76)
    }

    /// Фонарик — индикатор денег (как огонёк антенки у Радарчика).
    private func lantern(_ s: CGFloat) -> some View {
        let color = DS.antenna(state == .sleep ? .dim : (state == .tipWave ? .tipsReady : signal))
        return VStack(spacing: 0) {
            Rectangle().fill(DomovoyPalette.wood).frame(width: max(s * 0.012, 0.8), height: s * 0.06)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.02).fill(Color.black.opacity(0.6))
                RoundedRectangle(cornerRadius: s * 0.02).stroke(DomovoyPalette.wood, lineWidth: max(s * 0.015, 1))
                Circle().fill(color).frame(width: s * 0.06, height: s * 0.06)
                    .shadow(color: color.opacity(0.9), radius: s * 0.05)
            }
            .frame(width: s * 0.10, height: s * 0.13)
        }
        .position(x: s * 0.86, y: s * 0.24)
    }

    private func nightcap(_ s: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Triangle().fill(DomovoyPalette.shirt).frame(width: s * 0.3, height: s * 0.24)
            Circle().fill(.white).frame(width: s * 0.07, height: s * 0.07).offset(x: s * 0.03, y: -s * 0.02)
        }
        .rotationEffect(.degrees(18))
        .position(x: s * 0.52, y: s * 0.17)
        .overlay(alignment: .topLeading) {
            Text("z").font(.system(size: s * 0.12, weight: .bold)).foregroundStyle(DS.Ink.muted)
                .offset(x: s * 0.12, y: s * 0.06)
        }
    }

    private func coin(_ s: CGFloat) -> some View {
        ZStack {
            Circle().fill(DS.Mascot.coin)
            Text("₽").font(.system(size: s * 0.09, weight: .bold)).foregroundStyle(.black.opacity(0.6))
        }
        .frame(width: s * 0.16, height: s * 0.16)
        .position(x: s * 0.78, y: s * 0.55)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func exclamation(_ s: CGFloat) -> some View {
        Text("!")
            .font(.system(size: s * 0.16, weight: .black))
            .foregroundStyle(.white)
            .position(x: s * 0.16, y: s * 0.2)
    }

    private func blinkLoop() async {
        guard state != .sleep else {
            blinking = false
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 3...8)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.07)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.09)) { blinking = false }
        }
    }
}

/// Домовой в свёрнутой чёлке: в «подбородке» под вырезом из темноты глядят
/// глаза из-под лохматых бровей. Огонёк фонарика — справа от выреза.
struct DomovoyPeek: View {
    var state: MascotState
    var gaze: CGPoint = .zero

    var body: some View {
        let sleeping = state == .sleep
        ZStack(alignment: .top) {
            // Глаза из темноты: прищур, во сне закрыты.
            HStack(spacing: 10) {
                ForEach([true, false], id: \.self) { isLeft in
                    if sleeping {
                        Capsule().fill(DomovoyPalette.brow.opacity(0.6)).frame(width: 7, height: 1.3)
                    } else {
                        ZStack {
                            Ellipse().fill(.white).frame(width: 8, height: 7)
                            Circle().fill(DomovoyPalette.pupil).frame(width: 4, height: 4)
                                .offset(x: gaze.x * 1.4, y: gaze.y * 0.8)
                        }
                        .frame(width: 8, height: 7)
                        .clipShape(Ellipse())
                        .overlay(alignment: .top) {
                            // Тяжёлое веко из темноты — хитрый прищур.
                            Rectangle().fill(.black).frame(width: 9, height: isLeft ? 2.8 : 2)
                        }
                    }
                }
            }
            .offset(y: 9)
            // Брови-кусты.
            HStack(spacing: 8) {
                Capsule().fill(DomovoyPalette.brow).frame(width: 12, height: 4).rotationEffect(.degrees(sleeping ? 4 : 14))
                Capsule().fill(DomovoyPalette.brow).frame(width: 12, height: 4).rotationEffect(.degrees(sleeping ? -4 : -14))
            }
            .offset(y: 5)
            // Чёлка свисает из выреза на брови (у домового — чёлка из чёлки).
            HStack(spacing: -3) {
                ForEach(0..<6, id: \.self) { index in
                    Tuft()
                        .fill(index.isMultiple(of: 2) ? DomovoyPalette.furTop : DomovoyPalette.furBottom)
                        .frame(width: 9, height: index == 2 || index == 3 ? 9 : 7)
                        .rotationEffect(.degrees(180 + Double(index - 2) * 6))
                }
            }
            .offset(y: -1)
        }
        .frame(width: 58, height: 18, alignment: .top)
        .clipped()
    }
}

/// Фонарик домового в свёрнутой чёлке — огонёк настроения денег.
struct DomovoyLanternLight: View {
    var signal: AntennaSignal
    var isResting: Bool

    var body: some View {
        let color = DS.antenna(isResting ? .dim : signal)
        VStack(spacing: 0) {
            Rectangle().fill(DomovoyPalette.wood).frame(width: 1, height: 3)
            ZStack {
                RoundedRectangle(cornerRadius: 1.5).stroke(DomovoyPalette.wood, lineWidth: 1)
                Circle().fill(color).frame(width: 5, height: 5).shadow(color: color.opacity(isResting ? 0 : 0.9), radius: 3)
            }
            .frame(width: 8, height: 10)
        }
        .accessibilityLabel(L("Фонарик: ", "Lantern: ") + signal.spokenName)
    }
}

// MARK: - Фигуры

/// Мохнатый край: круг (эллипс) из мягких «бугорков».
struct FurShape: Shape {
    var bumps = 14
    /// Глубина бугорка — доля радиуса.
    var depth: CGFloat = 0.06

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2
        let ry = rect.height / 2
        func point(_ scale: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + rx * scale * CGFloat(cos(angle)), y: center.y + ry * scale * CGFloat(sin(angle)))
        }
        var path = Path()
        for index in 0..<bumps {
            let a0 = Double(index) / Double(bumps) * 2 * .pi
            let a1 = Double(index + 1) / Double(bumps) * 2 * .pi
            if index == 0 { path.move(to: point(1 - depth, a0)) }
            path.addQuadCurve(to: point(1 - depth, a1), control: point(1 + depth, (a0 + a1) / 2))
        }
        path.closeSubpath()
        return path
    }
}

/// Вихор — капля, сужающаяся кверху.
struct Tuft: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.2))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.midY))
        return path
    }
}

/// Пушистое облако — борода.
struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.height * 0.42
        let centers: [CGPoint] = [
            CGPoint(x: rect.minX + r, y: rect.minY + r),
            CGPoint(x: rect.midX, y: rect.minY + r * 1.15),
            CGPoint(x: rect.maxX - r, y: rect.minY + r),
            CGPoint(x: rect.minX + rect.width * 0.32, y: rect.maxY - r),
            CGPoint(x: rect.maxX - rect.width * 0.32, y: rect.maxY - r),
        ]
        for center in centers {
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        return path
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
