import SwiftUI
import RadarchikCore

/// Первый экран при наведении: Радарчик со своей фразой, все проекты по месяцам,
/// чипы проектов, строка «CPU · RAM · °», кнопки «+ Трата», «+ Доход»,
/// «Куда платить» и меню.
/// Принцип ТЗ: на первом уровне минимум цифр, подробности — по клику.
///
/// Если какое-то приложение ест больше обычного (этап 6), облачко говорит
/// о нём — с кнопками «Показать», «Это нормально», «Позже». Ответил — снова о деньгах.
struct SummaryView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let review: ReviewService
    let resources: ResourceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if settings.mascotSkin == .livingNotch {
                // Лицо рисует сама чёлка (`NotchFace`) прямо над облачком,
                // хвостик облачка показывает на него: говорит чёлка.
                bubble(pointsUp: true)
            } else {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    SummaryMascot(model: model, store: store, review: review, resources: resources, skin: settings.mascotSkin)
                    bubble(pointsUp: false)
                }
            }

            let histories = store.overallHistory
            if !histories.isEmpty {
                OverallChart(histories: histories, month: store.month)
            }

            let glances = store.glances
            if !glances.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(glances) { glance in
                        ProjectChip(glance: glance) { model.push(.project(glance.project.id)) }
                    }
                }
            }

            if !settings.observationEnabled {
                ObservationOffCard { model.push(.observation) }
            } else if !review.latestTips.isEmpty || review.newTipsCount > 0 {
                TipsCard(count: review.latestTips.count, isNew: review.newTipsCount > 0) { model.push(.tips) }
            }

            if settings.resourcesEnabled {
                ResourceLine(resources: resources) { model.push(.system(nil)) }
            }

            actions
        }
    }

    /// Тревога важнее фразы о деньгах: пока она есть, облачко о ней.
    @ViewBuilder
    private func bubble(pointsUp: Bool) -> some View {
        if let alert = resources.activeAlert {
            AlertBubble(alert: alert, more: resources.alerts.count - 1, pointsUp: pointsUp) {
                model.push(.system(SystemFocus(metric: SystemMetric(alert.kind), appKey: alert.app?.key)))
            } onNormal: {
                resources.respond(alert, with: .normal)
            } onLater: {
                resources.respond(alert, with: .later)
            }
            // Новая тревога — новое облачко: иначе onAppear не сработал бы для следующей.
            .id(alert.id)
            .onAppear { resources.markSeen(alert) }
        } else {
            SpeechBubble(text: store.phrase, pointsUp: pointsUp)
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.xs) {
            if store.projects.isEmpty {
                PillButton(L("Новый проект", "New project"), systemImage: "plus", prominent: true) {
                    model.push(.projectForm(editing: nil))
                }
            } else {
                PillButton(L("Трата", "Cost"), systemImage: "plus") {
                    model.push(.entryForm(.new(.recurring, projectId: nil)))
                }
                PillButton(L("Доход", "Income"), systemImage: "plus") {
                    model.push(.entryForm(.new(.income, projectId: nil)))
                }
                let due = store.dueTotals
                if !due.isEmpty {
                    PillButton(L("К оплате ", "Due ") + MoneyFormat.compactList(due), systemImage: "creditcard") {
                        model.push(.payments)
                    }
                }
            }
            Spacer(minLength: 0)
            MoreMenu {
                Button(L("Новый проект", "New project")) { model.push(.projectForm(editing: nil)) }
                Button(L("Куда платить", "Where to pay")) { model.push(.payments) }
                Button(L("Советы дня", "Daily tips")) { model.push(.tips) }
                Button(L("Наблюдение", "Activity tracking")) { model.push(.observation) }
                Button(L("Система", "System")) { model.push(.system(nil)) }
                Button(L("Что записано сегодня", "What’s logged today")) { model.push(.today) }
                Button(L("Настройки", "Settings")) { model.push(.settings) }
                Divider()
                Button(L("Выйти из Радарчика", "Quit Radarchik")) { NSApp.terminate(nil) }
            }
        }
    }
}

/// «⋯» — меню экранов. Кружок подсвечивается при наведении, как у кнопок-значков.
private struct MoreMenu<Items: View>: View {
    @ViewBuilder var items: Items
    @State private var hovering = false

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? DS.Ink.primary : DS.Ink.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? DS.Surface.cardHover : .clear))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(L("Ещё", "More"))
    }
}

/// Подсказка, пока наблюдение выключено: без него советов не будет.
private struct ObservationOffCard: View {
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Ink.muted)
            Text(Typography.bind(L("Наблюдение выключено — советов дня не будет", "Activity tracking is off — no daily tips")))
                .font(.system(size: 12))
                .foregroundStyle(DS.Ink.secondary)
            Spacer(minLength: 0)
            PillButton(L("Настроить", "Set up"), action: onOpen)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))
    }
}

/// Радарчик на сводке. Отдельный view нарочно: взгляд меняется на каждое
/// движение мыши, и перерисовываться должен только он, а не вся сводка
/// с пересчётом денег (SwiftUI следит за тем, что читает именно этот body).
private struct SummaryMascot: View {
    let model: NotchViewModel
    let store: MoneyStore
    let review: ReviewService
    let resources: ResourceMonitor
    let skin: MascotSkin

    var body: some View {
        let mood = store.overallMood
        let state = MascotBrain.state(
            isExpanded: true, mood: mood, isResting: model.isResting, event: store.mascotEvent,
            hasNewTips: review.newTipsCount > 0, hasResourceAlert: resources.activeAlert != nil
        )
        MascotPortrait(skin: skin, state: state, signal: mood?.antenna ?? .dim, gaze: model.gaze)
            .frame(width: DS.Size.mascot, height: DS.Size.mascot)
    }
}

/// Все проекты по месяцам (решение 2026-10-19): растёт ли общий итог.
/// По графику на валюту, без конвертации; валют несколько — переключатель.
/// Текущий месяц ещё идёт: его столбик бледный, а сумма «пока» — в заголовке.
private struct OverallChart: View {
    let histories: [CurrencyHistory]
    let month: YearMonth
    @State private var currency: Currency?

    var body: some View {
        let shown = histories.first { $0.currency == currency } ?? histories[0]
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if histories.count > 1 {
                SegmentedPicker(
                    selection: Binding(get: { shown.currency }, set: { currency = $0 }),
                    options: histories.map { SegmentedPicker<Currency>.Option(value: $0.currency, title: $0.currency.symbol) },
                    fills: false
                )
            }
            NetBarsChart(
                points: shown.points,
                currency: shown.currency,
                selected: month,
                inProgress: month,
                title: L("Все проекты по месяцам", "All projects by month"),
                note: note(shown)
            )
        }
        .padding(DS.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))
    }

    /// «октябрь пока +34,9к ₽» / «October so far +$34.9k»; в месяце ещё ничего нет — без суммы.
    private func note(_ history: CurrencyHistory) -> (label: String, amount: Int64)? {
        guard let current = history.points.last, current.figures != .zero else { return nil }
        let name = Words.monthName(month.month)
        return (L("\(name.lowercased()) пока", "\(name) so far"), current.figures.net)
    }
}

/// Что говорит Радарчик — облачко рядом с ним. У тревоги ниже мелко —
/// сколько она держится, и кнопки.
/// У Живой чёлки облачко под лицом: хвостик вверх, текст по центру.
struct SpeechBubble<Actions: View>: View {
    let text: String
    var footnote: String?
    var pointsUp = false
    /// Обводка: у тревоги жёлтая — облачко сразу отличается от фразы о деньгах.
    var accent: Color?
    @ViewBuilder var actions: Actions

    var body: some View {
        let tail = pointsUp ? BubbleShape.tail : .zero
        let shape = BubbleShape(cornerRadius: DS.Radius.card, tailSize: tail)
        VStack(alignment: pointsUp ? .center : .leading, spacing: 4) {
            // Короткие слова не остаются в конце строки: «К / оплате» не разорвётся.
            Text(Typography.bind(text))
                .font(.system(size: 12))
                .foregroundStyle(DS.Ink.primary)
                .lineSpacing(2)
                .multilineTextAlignment(pointsUp ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.secondary)
            }
            actions
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: pointsUp ? .center : .leading)
        .padding(.top, tail.height)
        .background(shape.fill(DS.Surface.card).stroke(accent ?? .clear))
    }
}

extension SpeechBubble where Actions == EmptyView {
    init(text: String, footnote: String? = nil, pointsUp: Bool = false) {
        self.init(text: text, footnote: footnote, pointsUp: pointsUp, accent: nil) { EmptyView() }
    }
}

/// Облачко тревоги «больше обычного» (этап 6): фраза, сколько держится и три кнопки.
/// «Показать» — экран «Система» на нужной вкладке, «Это нормально» — поднять норму,
/// «Позже» — убрать; три часа о том же не напомню.
struct AlertBubble: View {
    let alert: ResourceAlert
    /// Сколько ещё тревог ждут за этой.
    var more = 0
    var pointsUp = false
    let onShow: () -> Void
    let onNormal: () -> Void
    let onLater: () -> Void

    var body: some View {
        SpeechBubble(text: alert.speech, footnote: footnote, pointsUp: pointsUp, accent: DS.antenna(.yellow).opacity(0.5)) {
            HStack(spacing: DS.Spacing.xs) {
                PillButton(L("Показать", "Show"), prominent: true, action: onShow)
                PillButton(L("Это нормально", "That’s normal"), action: onNormal)
                PillButton(L("Позже", "Later"), action: onLater)
            }
            .padding(.top, 4)
        }
    }

    private var footnote: String {
        let lasting = DurationFormat.short(Date().timeIntervalSince(alert.startedAt))
        var parts = [L("держится \(lasting)", "for \(lasting)")]
        if more > 0 {
            let alerts = Words.plural(more, ru: ("тревога", "тревоги", "тревог"), en: ("alert", "alerts"))
            parts.append(L("ещё \(more) \(alerts)", "\(more) more \(alerts)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Строка «CPU 23% · RAM 14/24 ГБ · 52°» на сводке (SPEC §3а), по клику — экран «Система».
/// Отдельный вид: обновляется раз в 5 секунд, и перерисовываться должна только она.
private struct ResourceLine: View {
    let resources: ResourceMonitor
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        if let system = resources.system {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Ink.muted)
                    Text(ResourceFormat.hoverLine(system))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(hovering ? DS.Ink.primary : DS.Ink.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Ink.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.chip).fill(hovering ? DS.Surface.cardHover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(L("Система: кто больше всех ест и график за час", "System: who uses the most, and the last hour"))
        }
    }
}

/// Облачко: скруглённый прямоугольник и мягкий хвостик сверху по центру.
/// Одна фигура, а не две: подложка полупрозрачная, и на стыке двух
/// заливок проступила бы полоска двойной плотности.
struct BubbleShape: Shape {
    static let tail = CGSize(width: 18, height: 8)

    var cornerRadius: CGFloat
    /// `.zero` — без хвостика.
    var tailSize: CGSize = .zero

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + tailSize.height, width: rect.width, height: rect.height - tailSize.height)
        let bubble = Path(roundedRect: body, cornerRadius: cornerRadius)
        guard tailSize.height > 0 else { return bubble }
        // Бока хвостика вогнутые: от основания к кончику по кривой.
        let half = tailSize.width / 2
        var tail = Path()
        tail.move(to: CGPoint(x: rect.midX - half, y: body.minY + 1))
        tail.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.midX - half * 0.25, y: body.minY))
        tail.addQuadCurve(to: CGPoint(x: rect.midX + half, y: body.minY + 1), control: CGPoint(x: rect.midX + half * 0.25, y: body.minY))
        tail.closeSubpath()
        return bubble.union(tail)
    }
}

/// Чип проекта: цветная метка, название, итог и значок настроения
/// последнего закрытого месяца. У нового проекта — песочные часы и итог «пока».
private struct ProjectChip: View {
    let glance: ProjectGlance
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let net = glance.net
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: glance.project.colorHex))
                    .frame(width: 4, height: 14)
                Text(glance.project.name)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Text(MoneyFormat.compact(net, glance.project.currency, signed: true))
                    .monospacedDigit()
                    .foregroundStyle(DS.Money.text(for: net))
                Image(systemName: glance.mood?.icon ?? "hourglass")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(glance.mood.map { DS.antenna($0.antenna) } ?? DS.Ink.muted)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.chip).fill(hovering ? DS.Surface.cardHover : DS.Surface.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    /// Все месяцы мужского рода, поэтому «за октябрь» — та же форма, что «Октябрь».
    private var help: String {
        let name = glance.project.name
        let month = Words.monthName(glance.month.month)
        guard let mood = glance.mood else {
            return L("\(name): первый месяц идёт, \(month.lowercased()) пока", "\(name): first month in progress, \(month) so far")
        }
        return L("\(name): \(mood.label), итог за \(month.lowercased())", "\(name): \(mood.label), net for \(month)")
    }
}

/// Плашка «Советы дня» на сводке. Пока советы новые — выделена.
private struct TipsCard: View {
    let count: Int
    let isNew: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isNew ? DS.antenna(.yellow) : DS.Ink.muted)
            Text(isNew ? L("Готовы советы дня: \(count)", "Daily tips are ready: \(count)") : L("Советы дня: \(count)", "Daily tips: \(count)"))
                .font(.system(size: 12, weight: isNew ? .semibold : .regular))
                .foregroundStyle(isNew ? DS.Ink.primary : DS.Ink.secondary)
            Spacer(minLength: 0)
            PillButton(L("Открыть", "Open"), prominent: isNew, action: onOpen)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Новые советы — жёлтая обводка, как у тревоги; прочитанные — просто карточка.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .fill(DS.Surface.card)
                .stroke(isNew ? DS.antenna(.yellow).opacity(0.5) : .clear)
        )
    }
}
