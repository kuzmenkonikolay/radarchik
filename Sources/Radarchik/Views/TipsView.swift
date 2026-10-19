import SwiftUI
import RadarchikCore

/// «Советы дня»: советы последнего разбора, ниже — прошлые, кроме отклонённых.
/// У каждого — «Сделаю», «Уже сделал», «Не надо»; отклонённые больше не предлагаются.
struct TipsView: View {
    let model: NotchViewModel
    let review: ReviewService

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Советы дня", "Daily tips"), onBack: { model.pop() }) {
                if review.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = review.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Ink.primary)
                    .symbolRenderingMode(.multicolor)
            }
            content
            actions
        }
        .onAppear { review.markSeen() }
    }

    @ViewBuilder
    private var content: some View {
        if !review.hasAPIKey {
            Hint(L("Чтобы разбирать день, нужен ключ Claude API. В Claude уходит только сводка, сырой лог остаётся на маке.",
                   "To review your day, add a Claude API key. Only a summary goes to Claude; the raw log stays on this Mac."))
        } else if review.tips.isEmpty {
            Hint(review.isRunning
                ? L("Разбираю день — это займёт минуту-две.", "Reviewing the day — this takes a minute or two.")
                : L("Советов пока нет. Первый разбор — сегодня в \(review.reviewHourText). Можно запустить и сейчас: польза растёт с каждым днём записей.",
                    "No tips yet. The first review is today at \(review.reviewHourText). You can run it now too: it gets more useful with every day logged."))
        } else {
            if let latest = review.latestReview {
                Text(meta(latest))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Ink.muted)
            }
            FitOrScroll(maxHeight: 500) { list }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if review.latestTips.isEmpty {
                Hint(L("В последнем разборе явной рутины не нашлось — это тоже результат.", "The last review found no clear routine — that’s a result too."))
            }
            ForEach(review.latestTips) { tip in
                TipCard(tip: tip) { review.setStatus($0, for: tip) }
            }
            if !review.olderTips.isEmpty {
                SectionTitle(L("Раньше", "Earlier"))
                    .padding(.top, DS.Spacing.xs)
                ForEach(review.olderTips.prefix(10)) { tip in
                    TipCard(tip: tip) { review.setStatus($0, for: tip) }
                        .opacity(tip.status == .done ? 0.6 : 1)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.xs) {
            if review.hasAPIKey {
                PillButton(review.isRunning ? L("Разбираю…", "Reviewing…") : L("Разобрать сейчас", "Review now"), systemImage: "sparkles") {
                    Task { await review.runNow() }
                }
                .disabled(review.isRunning)
            } else {
                PillButton(L("Подключить Claude", "Connect Claude"), systemImage: "key", prominent: true) { model.push(.claudeSettings) }
            }
            PillButton(L("Что уходит в Claude", "What goes to Claude"), systemImage: "doc.text.magnifyingglass") { model.push(.reviewPrompt) }
            Spacer(minLength: 0)
            IconButton(systemImage: "gearshape", help: L("Разбор дня и Claude", "Daily review & Claude")) { model.push(.claudeSettings) }
        }
    }

    private func meta(_ review: StoredReview) -> String {
        let date = review.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Language.current.locale))
        let model = ClaudeModel(rawValue: review.model)?.title ?? review.model
        let cost = L(String(format: "$%.2f", review.costUSD).replacingOccurrences(of: ".", with: ","), String(format: "$%.2f", review.costUSD))
        return L("Разбор \(date) · \(model) · \(cost)", "Reviewed \(date) · \(model) · \(cost)")
    }
}

/// Карточка совета: что видно, что сделать, усилие, сколько вернёт, чем делать.
private struct TipCard: View {
    let tip: Tip
    let onStatus: (TipStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Typography.bind(tip.title))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Self.rich(tip.observation)
                .font(.system(size: 12))
                .foregroundStyle(DS.Ink.secondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            Self.rich(tip.suggestion)
                .font(.system(size: 12))
                .foregroundStyle(DS.Ink.primary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            // Влезает в строку — подробности слева, кнопки справа; нет — кнопки ниже.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    detailsText.fixedSize()
                    Spacer(minLength: 4)
                    statusButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    detailsText
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        statusButtons
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))
    }

    /// Текст совета с разметкой Claude: `код` — моноширинным на подложке,
    /// **жирное** — жирным. Неразрывные пробелы — только в обычном тексте:
    /// внутри команды они сломали бы её при копировании в терминал.
    static func rich(_ markdown: String) -> Text {
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
                // Моноширинный крупнее обычного — на полпункта мельче, чтобы строки были ровными.
                piece.font = .system(size: 11.5, design: .monospaced)
                piece.backgroundColor = Color.white.opacity(0.09)
                piece.foregroundColor = DS.Ink.primary
            } else {
                piece = AttributedString(Typography.bind(String(piece.characters)), attributes: run.attributes)
            }
            result.append(piece)
        }
        attributed = result
        return Text(attributed)
    }

    private var detailsText: some View {
        Text(details)
            .font(.system(size: 11))
            .foregroundStyle(DS.Ink.muted)
    }

    private var statusButtons: some View {
        HStack(spacing: 6) {
            status(.planned)
            status(.done)
            status(.dismissed)
        }
    }

    private var details: String {
        // Старые советы хранят усилие по-русски — показываем на текущем языке.
        let effort = TipEffort(word: tip.effort)?.word ?? tip.effort
        var parts = [L("усилие: ", "effort: ") + effort]
        if tip.timeSavedPerWeekMin > 0 { parts.append(L("≈ \(tip.timeSavedPerWeekMin) мин/нед", "≈ \(tip.timeSavedPerWeekMin) min/week")) }
        if let hint = tip.toolHint { parts.append(hint) }
        return parts.joined(separator: " · ")
    }

    private func status(_ value: TipStatus) -> some View {
        let isCurrent = tip.status == value
        return Button {
            // Повторное нажатие снимает отметку.
            onStatus(isCurrent ? .new : value)
        } label: {
            Text(value.title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(isCurrent ? Color.black : DS.Ink.secondary)
                .background(Capsule().fill(isCurrent ? DS.Ink.primary : DS.Surface.field))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
            FitOrScroll(maxHeight: 460) {
                Text(text.isEmpty ? L("Пока нечего отправлять — в логе за период пусто.", "Nothing to send yet — the log for this period is empty.") : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Ink.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.sm)
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(DS.Surface.field))
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
