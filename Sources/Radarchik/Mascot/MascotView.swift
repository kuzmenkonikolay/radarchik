import SwiftUI
import RadarchikCore

/// Временный Радарчик из фигур SwiftUI, пока персонаж не утверждён.
///
/// Это «скин» с тем же входом, что будет у настоящего: состояние
/// (`MascotState`, имена — как клипы анимаций), огонёк антенки и взгляд.
/// Rive- или 3D-рендерер потом займёт место этого view, логика не изменится.
///
/// Батарею не ест: моргание крутится только пока view на экране
/// (чёлка раскрыта), в покое ничего не анимируется.
struct MascotView: View {
    var state: MascotState
    var antenna: AntennaSignal
    /// −1…1 по каждой оси, y вниз.
    var gaze: CGPoint = .zero

    @State private var blinking = false

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                ears(s)
                antennaStick(s)
                torso(s)
                glasses(s)
                eyes(s)
                mouth(s)
                if state == .catchCoin { coin(s) }
            }
            .frame(width: s, height: s)
            .offset(y: bounce(s))
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: state)
        .animation(.easeOut(duration: 0.15), value: gaze)
        .task(id: state == .sleep) { await blinkLoop() }
        .accessibilityElement()
        .accessibilityLabel(L("Радарчик", "Radarchik"))
    }

    // MARK: - Части

    /// Уши-локаторы: тарелки, развёрнутые в стороны. Во сне опущены.
    private func ears(_ s: CGFloat) -> some View {
        let tilt: Double = state == .sleep ? 38 : (state == .nervous ? 8 : 22)
        return ZStack {
            ear(s).rotationEffect(.degrees(-tilt)).offset(x: -s * 0.36, y: -s * 0.08)
            ear(s).scaleEffect(x: -1).rotationEffect(.degrees(tilt)).offset(x: s * 0.36, y: -s * 0.08)
        }
    }

    private func ear(_ s: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(DS.Mascot.ear).frame(width: s * 0.25, height: s * 0.34)
            Ellipse().fill(DS.Mascot.earDish).frame(width: s * 0.14, height: s * 0.23).offset(x: -s * 0.03)
        }
    }

    /// Антенка с огоньком — тот же сигнал, что в свёрнутой чёлке.
    private func antennaStick(_ s: CGFloat) -> some View {
        let color = DS.antenna(state == .sleep ? .dim : antenna)
        return ZStack {
            Capsule().fill(DS.Mascot.ink.opacity(0.8)).frame(width: max(s * 0.03, 1.5), height: s * 0.16).offset(y: -s * 0.33)
            Circle().fill(color).frame(width: s * 0.13, height: s * 0.13)
                .shadow(color: color.opacity(0.9), radius: s * 0.07)
                .offset(y: -s * 0.42)
        }
    }

    /// Круглое тело — матовый винил: мягкий градиент и блик сверху слева.
    private func torso(_ s: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [DS.Mascot.bodyTop, DS.Mascot.bodyBottom], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.64, height: s * 0.64)
            Ellipse()
                .fill(Color.white.opacity(0.35))
                .frame(width: s * 0.2, height: s * 0.12)
                .rotationEffect(.degrees(-30))
                .offset(x: -s * 0.14, y: -s * 0.18)
        }
        .offset(y: s * 0.08)
    }

    /// Круглые очки отличника в тонкой оправе.
    private func glasses(_ s: CGFloat) -> some View {
        let lens = s * 0.2
        let line = max(s * 0.022, 1)
        return ZStack {
            Circle().stroke(DS.Mascot.ink, lineWidth: line).frame(width: lens, height: lens).offset(x: -s * 0.11)
            Circle().stroke(DS.Mascot.ink, lineWidth: line).frame(width: lens, height: lens).offset(x: s * 0.11)
            Capsule().fill(DS.Mascot.ink).frame(width: s * 0.04, height: line).offset(y: -lens * 0.1)
        }
        .offset(y: s * 0.06)
    }

    /// Глаза-бусинки. Смотрят на курсор, моргают; во сне закрыты.
    private func eyes(_ s: CGFloat) -> some View {
        let shift = CGSize(width: gaze.x * s * 0.035, height: gaze.y * s * 0.03)
        // Хитро смотрит поверх очков, когда спокоен.
        let lookOver: CGFloat = (state == .peek || state == .idleScan) ? -s * 0.012 : 0
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                if state == .sleep {
                    Capsule().fill(DS.Mascot.ink).frame(width: s * 0.09, height: max(s * 0.018, 1))
                        .offset(x: side * s * 0.11)
                } else {
                    ZStack {
                        Circle().fill(DS.Mascot.ink).frame(width: s * 0.085, height: s * 0.085)
                        Circle().fill(Color.white.opacity(0.9)).frame(width: s * 0.025, height: s * 0.025)
                            .offset(x: s * 0.015, y: -s * 0.015)
                    }
                    .scaleEffect(x: 1, y: blinking ? 0.12 : (state == .happy ? 0.8 : 1))
                    .offset(x: side * s * 0.11 + shift.width, y: shift.height + lookOver)
                }
            }
        }
        .offset(y: s * 0.06)
    }

    /// Рот: ухмылка всезнайки, улыбка, тревога, нервная волна.
    private func mouth(_ s: CGFloat) -> some View {
        MouthShape(kind: MouthShape.Kind(state))
            .stroke(DS.Mascot.ink, style: StrokeStyle(lineWidth: max(s * 0.025, 1), lineCap: .round, lineJoin: .round))
            .frame(width: s * 0.16, height: s * 0.06)
            .offset(y: s * 0.24)
    }

    /// Монетка над головой, когда добавили доход.
    private func coin(_ s: CGFloat) -> some View {
        ZStack {
            Circle().fill(DS.Mascot.coin)
            Text("₽").font(.system(size: s * 0.1, weight: .bold)).foregroundStyle(Color.black.opacity(0.6))
        }
        .frame(width: s * 0.18, height: s * 0.18)
        .offset(x: s * 0.3, y: -s * 0.36)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// «Поймал монетку» и «доволен» — лёгкий подскок.
    private func bounce(_ s: CGFloat) -> CGFloat {
        switch state {
        case .catchCoin: -s * 0.05
        case .happy: -s * 0.02
        default: 0
        }
    }

    // MARK: - Моргание

    /// Случайно раз в 3–8 секунд. Задача живёт, пока view на экране.
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
}

/// Линия рта под настроение.
private struct MouthShape: Shape {
    enum Kind {
        case smirk, smile, worried, wavy, neutral

        init(_ state: MascotState) {
            switch state {
            case .happy, .catchCoin, .tipWave: self = .smile
            case .worried: self = .worried
            case .nervous: self = .wavy
            case .sleep, .onCall: self = .neutral
            case .idleScan, .peek, .write: self = .smirk
            }
        }
    }

    var kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .smirk:
            // Одна сторона выше — «я всё записал».
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY))
        case .smile:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        case .worried:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        case .wavy:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.midY),
                control1: CGPoint(x: rect.minX + rect.width / 3, y: rect.minY),
                control2: CGPoint(x: rect.minX + rect.width * 2 / 3, y: rect.maxY)
            )
        case .neutral:
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.25, y: rect.midY))
        }
        return path
    }
}
