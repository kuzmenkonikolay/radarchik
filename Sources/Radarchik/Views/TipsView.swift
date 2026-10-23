import SwiftUI
import RadarchikCore

/// G. Советы дня: smug в очках и машет, бейдж с числом советов, по одному совету
/// с листалкой «‹ 1 / 3 ›». Заголовок, наблюдение, предложение, чипы «≈ 2 ч в неделю»
/// и сложность, кнопки «Сделаю / Уже сделал / Не надо».
struct TipsScreen: View {
    let model: NotchViewModel
    let review: ReviewService
    let settings: AppSettings
    @State private var index = 0

    var body: some View {
        let tips = review.latestTips + review.olderTips
        let count = tips.count
        let shown = count > 0 ? tips[min(index, count - 1)] : nil
        Card(vertical: 20, horizontal: 22) {
            HStack(alignment: .top, spacing: 18) {
                FaceColumn(
                    face: .main(.smug, tone: DS.Tone.tips, hands: count > 0 ? .wave : .none, glasses: true),
                    badge: DS.Tone.tips, symbol: count > 0 ? nil : "lightbulb", text: count > 0 ? "\(count)" : nil, width: 132
                )
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        CardHeader(dot: DS.Tone.tips, title: L("Советы дня", "Daily tips"), subtitle: weekday)
                        Spacer(minLength: 0)
                        if count > 1 { pager(count) }
                    }
                    if let error = review.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(DS.Ink.body)
                            .symbolRenderingMode(.multicolor)
                    }
                    if let tip = shown {
                        TipBody(tip: tip) { status in
                            review.setStatus(status, for: tip)
                            if status != .new, index < count - 1 { withAnimation(.easeInOut(duration: 0.2)) { index += 1 } }
                        }
                    } else {
                        empty
                    }
                    footer(hasTips: count > 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Открыл советы — прочитаны: бейдж и очки на лице гаснут плавно.
        .onAppear { withAnimation(.smooth(duration: 0.3)) { review.markSeen() } }
    }

    private var weekday: String {
        Date().formatted(.dateTime.weekday(.wide).locale(Language.current.locale)).lowercased()
    }

    private func pager(_ count: Int) -> some View {
        HStack(spacing: 2) {
            IconButton(systemImage: "chevron.left", help: L("Предыдущий совет", "Previous tip")) {
                withAnimation(.easeInOut(duration: 0.2)) { index = (index - 1 + count) % count }
            }
            Text("\(min(index, count - 1) + 1) / \(count)")
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(DS.Ink.secondary)
            IconButton(systemImage: "chevron.right", help: L("Следующий совет", "Next tip")) {
                withAnimation(.easeInOut(duration: 0.2)) { index = (index + 1) % count }
            }
        }
        .padding(.vertical, -6)
    }

    /// Советов нет: почему и что сделать.
    private var empty: some View {
        Text(Typography.bind(emptyText))
            .font(.body)
            .foregroundStyle(DS.Ink.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyText: String {
        guard settings.observationEnabled else {
            return L("Наблюдение выключено — советов дня не будет. Включи его, и я буду разбирать день.",
                     "Activity tracking is off — no daily tips. Turn it on and I’ll review your day.")
        }
        guard review.hasAPIKey else {
            return L("Чтобы разбирать день, нужен ключ Claude API. В Claude уходит только сводка, сырой лог остаётся на маке.",
                     "To review your day, add a Claude API key. Only a summary goes to Claude; the raw log stays on this Mac.")
        }
        guard review.latestReview != nil else {
            return L("Советов пока нет. Первый разбор — сегодня в \(review.reviewHourText). Можно запустить и сейчас: польза растёт с каждым днём записей.",
                     "No tips yet. The first review is today at \(review.reviewHourText). You can run it now too: it gets more useful with every day logged.")
        }
        return L("В последнем разборе явной рутины не нашлось — это тоже результат. Следующий — в \(review.reviewHourText).",
                 "The last review found no clear routine — that’s a result too. The next one is at \(review.reviewHourText).")
    }

    @ViewBuilder
    private func footer(hasTips: Bool) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            if !settings.observationEnabled {
                PrimaryButton(L("Включить наблюдение", "Turn on tracking"), systemImage: "eye") { model.show(.observation) }
            } else if !review.hasAPIKey {
                PrimaryButton(L("Подключить Claude", "Connect Claude"), systemImage: "key") { model.push(.claudeSettings) }
            } else if !hasTips {
                PrimaryButton(L("Разобрать сейчас", "Review now"), systemImage: "sparkles") { runNow() }
            }
            Spacer(minLength: 0)
            if settings.observationEnabled && review.hasAPIKey && hasTips {
                IconButton(systemImage: "sparkles", help: L("Разобрать сейчас", "Review now")) { runNow() }
            }
            IconButton(systemImage: "doc.text.magnifyingglass", help: L("Что уходит в Claude", "What goes to Claude")) { model.push(.reviewPrompt) }
            IconButton(systemImage: "slider.horizontal.3", help: L("Разбор дня и Claude", "Daily review & Claude")) { model.push(.claudeSettings) }
        }
        .padding(.top, 2)
    }

    private func runNow() {
        model.replaceTop(with: .review)
        Task { await review.runNow() }
    }
}

/// Один совет: заголовок 18 bold, наблюдение серым, предложение, чипы и кнопки.
private struct TipBody: View {
    let tip: Tip
    let onStatus: (TipStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Typography.bind(tip.title))
                .font(.tipTitle)
                .foregroundStyle(DS.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            RichText.make(tip.observation)
                .font(.body)
                .foregroundStyle(DS.Ink.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            RichText.make(tip.suggestion)
                .font(.body)
                .foregroundStyle(DS.Ink.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                if tip.timeSavedPerWeekMin > 0 {
                    Chip(text: "≈ " + Self.saved(tip.timeSavedPerWeekMin), background: DS.Tone.plus.opacity(0.12), foreground: DS.Tone.plusChipText, bold: true)
                }
                Chip(text: effortText, background: DS.Surface.chip, foreground: DS.Ink.body)
                if let hint = tip.toolHint {
                    Chip(text: hint, background: DS.Surface.chip, foreground: DS.Ink.secondary)
                }
            }
            .padding(.top, 2)
            buttons
                .padding(.top, 4)
        }
        .id(tip.id)
        .transition(.opacity)
    }

    @ViewBuilder
    private var buttons: some View {
        if tip.status == .new {
            HStack(spacing: DS.Spacing.xs) {
                PrimaryButton(L("Сделаю", "Will do")) { onStatus(.planned) }
                SecondaryButton(L("Уже сделал", "Already done")) { onStatus(.done) }
                PlainButton(L("Не надо", "Not needed")) { onStatus(.dismissed) }
            }
        } else {
            HStack(spacing: DS.Spacing.xs) {
                Chip(text: tip.status.title, systemImage: "checkmark", background: DS.Surface.secondaryButton, foreground: DS.Ink.primary, bold: true)
                PlainButton(L("Передумал", "Undo")) { onStatus(.new) }
            }
        }
    }

    /// «сделать за вечер», «за полчаса», «за выходные» — по усилию.
    private var effortText: String {
        switch TipEffort(word: tip.effort) {
        case .low: L("сделать за полчаса", "half an hour")
        case .medium: L("сделать за вечер", "one evening")
        case .high: L("сделать за выходные", "a weekend")
        case nil: tip.effort
        }
    }

    /// «2 ч в неделю», «25 мин в неделю».
    static func saved(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes % 60 == 0 ? "\(minutes / 60)" : String(format: "%.1f", Double(minutes) / 60).replacingOccurrences(of: ".0", with: "")
            return L("\(hours) ч в неделю", "\(hours) h a week")
        }
        return L("\(minutes) мин в неделю", "\(minutes) min a week")
    }
}

/// Текст совета с разметкой Claude: `код` — моноширинным на подложке, **жирное** — жирным.
enum RichText {
    static func make(_ markdown: String) -> Text {
        guard var attributed = try? AttributedString(
            markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(Typography.bind(markdown))
        }
        var result = AttributedString()
        for run in attributed.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) ?? false
            var piece = AttributedString(attributed[run.range])
            if isCode {
                piece.font = .system(size: 11.5, design: .monospaced)
                piece.backgroundColor = Color.white.opacity(0.08)
                piece.foregroundColor = DS.Ink.primary
            } else {
                piece = AttributedString(Typography.bind(String(piece.characters)), attributes: run.attributes)
            }
            result.append(piece)
        }
        attributed = result
        return Text(attributed)
    }
}

/// «Что уходит в Claude» — прозрачность: ровно тот текст, что отправлен
/// (или уйдёт, если разобрать сейчас). Сырого лога там нет.
struct ReviewPromptView: View {
    let model: NotchViewModel
    let review: ReviewService

    private enum Source: CaseIterable, Identifiable {
        case sent
        case now
        var id: Self { self }

        var title: String {
            switch self {
            case .sent: L("Последний разбор", "Last review")
            case .now: L("Если разобрать сейчас", "If reviewed now")
            }
        }
    }

    @State private var source: Source = .now
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Что уходит в Claude", "What goes to Claude"), onBack: { model.pop() })
            if review.latestReview != nil {
                SegmentedPicker(selection: $source) { $0.title }
            }
            Hint(L("Только сводка: время по приложениям и сайтам, шаблоны команд без значений, копирования и переключения, прошлые советы. Плюс системная инструкция Радарчика.",
                   "Only a summary: time per app and site, command templates without values, copying and switching, past tips. Plus Radarchik’s system instructions."))
            FitOrScroll(maxHeight: 380) {
                Text(text.isEmpty ? L("Пока нечего отправлять — в логе за период пусто.", "Nothing to send yet — the log for this period is empty.") : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Ink.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.sm)
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Surface.input))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(DS.Surface.inputBorder, lineWidth: 1))
        }
        .task(id: source) {
            switch source {
            case .sent: text = review.latestReview?.prompt ?? ""
            case .now: text = review.previewPrompt()
            }
        }
    }
}

extension ReviewService {
    /// «22:00» — для подсказок.
    var reviewHourText: String { String(format: "%02d:00", reviewHour) }
}
