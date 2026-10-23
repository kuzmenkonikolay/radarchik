import SwiftUI
import RadarchikCore

/// «Что это?» внутри алерта (2026-10-22). Пока Claude думает — лицо в очках, три шага и
/// ползунок с мини-лицом, как у разбора дня (экран F). Ответ — что это, вердикт чипом,
/// что делать, цена. Ошибка — текст и «Ещё раз» или «Настроить».
struct ExplainStateView: View {
    let state: ExplainState?
    /// Про кого спрашивали: «duetexpertd», «node install.js».
    let subject: String
    let model: NotchViewModel
    let retry: () -> Void
    @State private var thumbScale: CGFloat = 0.85

    var body: some View {
        switch state {
        case .thinking(let step): thinking(step)
        case .answer(let result): answer(result)
        case .failed(let message, let needsKey): failed(message, needsKey: needsKey)
        case nil: EmptyView()
        }
    }

    private func thinking(_ step: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader(dot: DS.Tone.info, title: L("Спрашиваю Claude, что это", "Asking Claude what this is"))
                Spacer(minLength: 0)
                Text("\(min(max(step, 1), 3))/3")
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                StepRow(title: L("Собираю, что знаю: путь, подпись, кто запустил", "Gathering what I know: path, signature, who launched it"), state: step > 1 ? .done : .current)
                StepRow(title: L("Спрашиваю Claude", "Asking Claude"), state: step > 2 ? .done : step == 2 ? .current : .ahead)
                StepRow(title: L("Читаю ответ", "Reading the answer"), state: step == 3 ? .current : .ahead)
            }
            ProgressTrack(progress: Double(max(step, 1) - 1) / 3 + 1.0 / 6, thumbScale: thumbScale)
        }
        .padding(.top, 6)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.1)) { thumbScale = 1 }
        }
    }

    private func answer(_ result: ExplainResult) -> some View {
        let explanation = result.explanation
        return VStack(alignment: .leading, spacing: 6) {
            // Строка переносится: имя скрипта бывает длинным, а чип не должен обрезаться.
            FlowLayout(spacing: 8) {
                Text(L("Claude про \(subject)", "Claude on \(subject)"))
                    .font(.caption)
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
                Chip(text: ExplainLook.verdictText(explanation.verdict), background: ExplainLook.verdictTone(explanation.verdict).opacity(0.18),
                     foreground: ExplainLook.verdictTone(explanation.verdict))
                Text(Self.priceText(result))
                    .font(.caption)
                    .foregroundStyle(DS.Ink.muted)
            }
            Text(Typography.bind(explanation.what))
                .font(.body)
                .foregroundStyle(DS.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Typography.bind(explanation.advice))
                .font(.body)
                .foregroundStyle(DS.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func failed(_ message: String, needsKey: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Typography.bind(message))
                .font(.body)
                .foregroundStyle(DS.Ink.body)
                .fixedSize(horizontal: false, vertical: true)
            if needsKey {
                SecondaryButton(L("Настроить", "Set up")) { model.show(.claudeSettings) }
            } else {
                SecondaryButton(L("Ещё раз", "Try again")) { retry() }
            }
        }
        .padding(.top, 6)
    }

    /// «Opus 5.5 · $0.01»; меньше цента — «<$0.01».
    static func priceText(_ result: ExplainResult) -> String {
        let model = ClaudeModel(rawValue: result.model)?.title ?? result.model
        let price = result.costUSD < 0.005 ? "<$0.01" : String(format: "$%.2f", result.costUSD)
        return model + " · " + price
    }
}

/// Лицо, бейдж и значок карточки по состоянию «Что это?»: думаю — очки и `info`,
/// ответ — по вердикту, иначе — как у самого алерта.
enum ExplainLook {
    static func verdictText(_ verdict: Explanation.Verdict) -> String {
        switch verdict {
        case .normal: L("норма", "normal")
        case .attention: L("присмотрись", "worth a look")
        case .unknown: L("не уверен", "not sure")
        }
    }

    static func verdictTone(_ verdict: Explanation.Verdict) -> Color {
        switch verdict {
        case .normal: DS.Tone.plus
        case .attention: DS.Tone.tips
        case .unknown: DS.Tone.info
        }
    }

    static func face(_ state: ExplainState?, default fallback: FaceSpec) -> FaceSpec {
        switch state {
        case .thinking: .main(.squint, tone: DS.Tone.info, glasses: true)
        case .answer(let result):
            switch result.explanation.verdict {
            case .normal: .main(.happy, tone: DS.Tone.plus)
            case .attention: .main(.worried, tone: DS.Tone.tips)
            case .unknown: .main(.squint, tone: DS.Tone.info, glasses: true)
            }
        case .failed: .main(.worried, tone: DS.Tone.info)
        case nil: fallback
        }
    }

    static func badge(_ state: ExplainState?, default fallback: Color) -> Color {
        switch state {
        case .thinking, .failed: DS.Tone.info
        case .answer(let result): verdictTone(result.explanation.verdict)
        case nil: fallback
        }
    }

    static func symbol(_ state: ExplainState?, default fallback: String) -> String {
        switch state {
        case .thinking: "ellipsis"
        case .answer(let result):
            switch result.explanation.verdict {
            case .normal: "checkmark"
            case .attention: "exclamationmark"
            case .unknown: "questionmark"
            }
        case .failed: "questionmark"
        case nil: fallback
        }
    }
}
