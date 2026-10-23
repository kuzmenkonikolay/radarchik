import SwiftUI
import RadarchikCore

/// F. Разбор дня идёт: squint в очках, бейдж «…», шаги и прогресс с ползунком —
/// чёрной капсулой 44×30 с мини-лицом внутри, которая едет по дорожке.
struct ReviewScreen: View {
    let model: NotchViewModel
    let review: ReviewService
    @State private var thumbScale: CGFloat = 0.85

    var body: some View {
        let progress = review.progress
        let step = progress?.step ?? 0
        Card(vertical: 20, horizontal: 22) {
            HStack(alignment: .top, spacing: 18) {
                FaceColumn(face: .main(.squint, tone: DS.Tone.info, glasses: true), badge: DS.Tone.info, symbol: "ellipsis", width: 132)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        CardHeader(dot: DS.Tone.info, title: L("Разбираю твой день", "Reviewing your day"))
                        Spacer(minLength: 0)
                        Text("\(min(max(step, 1), 4))/4")
                            .font(.body)
                            .monospacedDigit()
                            .foregroundStyle(DS.Ink.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(steps(progress).enumerated()), id: \.offset) { index, title in
                            StepRow(title: title, state: index + 1 < step ? .done : index + 1 == step ? .current : .ahead)
                        }
                    }
                    ProgressTrack(progress: Double(max(step, 1) - 1) / 4 + 0.125, thumbScale: thumbScale)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.1)) { thumbScale = 1 }
        }
        // Разбор закончился — на советы.
        .onChange(of: review.isRunning) { _, running in
            if !running { model.replaceTop(with: .tips) }
        }
    }

    private func steps(_ progress: ReviewProgress?) -> [String] {
        let collected = progress?.summary.map { L("Собрал день: \($0)", "Collected the day: \($0)") }
        return [
            collected ?? L("Собираю день", "Collecting the day"),
            L("Ищу, что ты повторял руками…", "Looking for what you repeated by hand…"),
            L("Прикидываю, что можно автоматизировать", "Figuring out what could be automated"),
            L("Собираю советы", "Writing up the tips"),
        ]
    }
}

/// Шаг разбора: готово — галочка `plus` и серый текст, текущий — точка `info`
/// и жирный, впереди — пустой кружок.
struct StepRow: View {
    enum State { case done, current, ahead }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Tone.plus)
                case .current:
                    Circle().fill(DS.Tone.info).frame(width: 8, height: 8)
                case .ahead:
                    Circle().stroke(DS.Ink.faint, lineWidth: 1.5).frame(width: 8, height: 8)
                }
            }
            .frame(width: 16, height: 16)
            Text(title)
                .font(state == .current ? .bodyBold : .body)
                .foregroundStyle(state == .current ? DS.Ink.primary : DS.Ink.secondary)
                .lineLimit(1)
        }
        .animation(.easeInOut(duration: 0.25), value: state == .current)
    }
}

/// Дорожка 6 pt и ползунок с мини-лицом, который едет по прогрессу.
struct ProgressTrack: View {
    let progress: Double
    var thumbScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumb = DS.Size.thumb
            let x = (width - thumb.width) * CGFloat(min(max(progress, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Surface.progressTrack).frame(height: 6)
                Capsule().fill(DS.Tone.info).frame(width: max(x + thumb.width / 2, 6), height: 6)
                MiniFace(.main(.squint, tone: DS.Tone.info), size: 30)
                    .frame(width: thumb.width, height: thumb.height)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.Surface.thumbBorder, lineWidth: 1))
                    .scaleEffect(thumbScale)
                    .offset(x: x)
            }
            .frame(height: thumb.height)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
        }
        .frame(height: DS.Size.thumb.height)
    }
}
