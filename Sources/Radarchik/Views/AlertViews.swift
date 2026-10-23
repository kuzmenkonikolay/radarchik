import AppKit
import SwiftUI
import RadarchikCore

/// Алерты (экраны D и E и тревоги): одна карточка без тулбара, раскрывается
/// сама и висит, пока не нажмёшь кнопку на ней (или Esc).
struct AlertScreen: View {
    let alert: PanelAlert
    let model: NotchViewModel
    let store: MoneyStore
    let resources: ResourceMonitor
    let protection: GuardMonitor
    let settings: AppSettings
    let review: ReviewService

    var body: some View {
        switch alert {
        case .income(let news):
            IncomeAlertView(news: news, model: model)
        case .pay(let reminder):
            PayAlertView(reminder: reminder, model: model, settings: settings)
        case .resource(let id):
            if let alert = resources.alerts.first(where: { $0.id == id }) {
                ResourceAlertView(alert: alert, model: model, resources: resources, explain: review.explain)
            } else {
                gone
            }
        case .guardEvent(let snapshot):
            if let event = protection.alerts.first(where: { $0.id == snapshot.id }) {
                GuardAlertView(event: event, isLive: true, model: model, protection: protection, explain: review.explain)
            } else if snapshot.level < .critical {
                // «Стоит глянуть»: ответа не ждёт, но висит, пока не нажмёшь «Понятно».
                GuardAlertView(event: snapshot, isLive: false, model: model, protection: protection, explain: review.explain)
            } else {
                gone
            }
        }
    }

    /// Тревога уже прошла или на неё ответили с другого экрана.
    private var gone: some View {
        Color.clear.frame(height: 1).onAppear { model.dismissAlert() }
    }
}

/// Карточка алерта: лицо с бейджем слева, содержимое справа.
struct AlertCard<Content: View>: View {
    let face: FaceSpec
    let badge: Color
    var symbol: String?
    var text: String?
    @ViewBuilder var content: Content

    var body: some View {
        Card(vertical: 18, horizontal: 22) {
            HStack(alignment: .center, spacing: 18) {
                FaceColumn(face: face, badge: badge, symbol: symbol, text: text, width: 132)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// D. Пришли деньги: happy с ручками вверх, крупно «+2 900 ₽», справа новый итог месяца.
/// Цифры прокручиваются, лицо подпрыгивает (`NotchViewModel.bounce`), играет монетка.
/// Закрывается крестиком справа.
private struct IncomeAlertView: View {
    let news: IncomeNews
    let model: NotchViewModel
    @State private var revealed = false
    @Environment(\.unrollsScrolling) private var isRendering

    var body: some View {
        AlertCard(face: .main(.happy, tone: DS.Tone.plus, hands: .up), badge: DS.Tone.plus, symbol: "plus") {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Пришли деньги · только что", "Money came in · just now"))
                        .font(.caption)
                        .foregroundStyle(DS.Ink.secondary)
                    HeroAmount(amount: revealed || isRendering ? news.amount : 0, currency: news.currency)
                    Text("\(news.projectName) · \(news.title)")
                        .font(.body)
                        .foregroundStyle(DS.Ink.body)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(DS.Surface.hairline).frame(width: 1, height: 64)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Words.monthName(news.month.month))
                        .font(.caption)
                        .foregroundStyle(DS.Ink.secondary)
                    Text(MoneyFormat.compact(revealed || isRendering ? news.after : news.before, news.currency, signed: true))
                        .font(.alertAside)
                        .monospacedDigit()
                        .foregroundStyle(DS.Money.text(for: news.after))
                        .contentTransition(.numericText(value: Double(revealed || isRendering ? news.after : news.before)))
                    Text(L("было ", "was ") + MoneyFormat.compact(news.before, news.currency, signed: true))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.Ink.secondary)
                }
                IconButton(systemImage: "xmark", help: L("Закрыть", "Close")) { model.dismissAlert() }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { revealed = true }
        }
    }
}

/// E. Пора платить: wide, свечение `minus`, бейдж «!». Кнопки «Открыть кабинет»
/// и «Напомни завтра».
private struct PayAlertView: View {
    let reminder: PayReminder
    let model: NotchViewModel
    let settings: AppSettings

    var body: some View {
        AlertCard(face: .main(.wide, tone: DS.Tone.minus), badge: DS.Tone.minus, symbol: "exclamationmark") {
            VStack(alignment: .leading, spacing: 6) {
                Text(when)
                    .font(.caption)
                    .foregroundStyle(DS.Ink.secondary)
                Text(L("Платить \(reminder.payee) — \(MoneyFormat.full(reminder.amount, reminder.currency))",
                       "Pay \(reminder.payee) — \(MoneyFormat.full(reminder.amount, reminder.currency))"))
                    .font(.alertTitle)
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(reminder.costName) · \(reminder.projectName)")
                    .font(.body)
                    .foregroundStyle(DS.Ink.body)
                    .lineLimit(1)
                HStack(spacing: DS.Spacing.xs) {
                    if let url = reminder.url {
                        PrimaryButton(L("Открыть кабинет", "Open dashboard"), systemImage: "arrow.up.right", iconAfter: true) {
                            NSWorkspace.shared.open(url)
                            settings.markPaymentReminded(reminder.id, until: .distantFuture)
                            model.dismissAlert()
                        }
                    } else {
                        PrimaryButton(L("Заплатил", "Paid")) {
                            settings.markPaymentReminded(reminder.id, until: .distantFuture)
                            model.dismissAlert()
                        }
                    }
                    SecondaryButton(L("Напомни завтра", "Remind me tomorrow")) {
                        settings.markPaymentReminded(reminder.id, until: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date())
                        model.dismissAlert()
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    /// «Через 2 дня · 22 октября», «Завтра · 22 октября», «Сегодня · 22 октября».
    private var when: String {
        let date = Words.dayMonth(reminder.dueDate.day, reminder.dueDate.month)
        switch reminder.daysLeft {
        case 0: return L("Сегодня · \(date)", "Today · \(date)")
        case 1: return L("Завтра · \(date)", "Tomorrow · \(date)")
        default:
            let days = Words.plural(reminder.daysLeft, ru: ("день", "дня", "дней"), en: ("day", "days"))
            return L("Через \(reminder.daysLeft) \(days) · \(date)", "In \(reminder.daysLeft) \(days) · \(date)")
        }
    }
}

/// Тревога ресурсов: worried, свечение `tips`, бейдж «!», кнопки «Показать /
/// Это нормально / Позже».
private struct ResourceAlertView: View {
    let alert: ResourceAlert
    let model: NotchViewModel
    let resources: ResourceMonitor
    let explain: ExplainService

    private var explainKey: String { "resource:\(alert.id)" }

    var body: some View {
        let state = explain.state(for: explainKey)
        let face = ExplainLook.face(state, default: .main(.worried, tone: DS.Tone.tips))
        let badge = ExplainLook.badge(state, default: DS.Tone.tips)
        let symbol = ExplainLook.symbol(state, default: "exclamationmark")
        let held = DurationFormat.short(Date().timeIntervalSince(alert.startedAt))
        AlertCard(face: face, badge: badge, symbol: symbol) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Больше обычного · держится \(held)", "More than usual · for \(held)"))
                    .font(.caption)
                    .foregroundStyle(DS.Ink.secondary)
                Text(Typography.bind(alert.title))
                    .font(.alertTitle)
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = alert.detail {
                    Text(Typography.bind(detail))
                        .font(.body)
                        .foregroundStyle(DS.Ink.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ExplainStateView(state: state, subject: subjectName, model: model, retry: { ask() })
                ResourceAlertButtons(alert: alert, resources: resources, onExplain: explainButton(state), onShow: { showSystem() })
                    .padding(.top, 4)
            }
        }
        .onAppear { resources.markSeen(alert) }
    }

    private var subjectName: String { alert.app?.name ?? L("мак", "the Mac") }

    private func explainButton(_ state: ExplainState?) -> (() -> Void)? {
        state == nil ? { ask() } : nil
    }

    private func showSystem() {
        model.show(.system, focus: SystemFocus(metric: SystemMetric(alert.kind), appKey: alert.app?.key))
    }

    private func ask() {
        let alert = alert
        explain.explain(explainKey) { ExplainFacts.resource(alert) }
    }
}

/// Тревога «Защиты». Опасное (ждёт ответа, `isLive`): wide и красное свечение, командная
/// строка моноширинным, кнопки по делу. «Стоит глянуть» (проверка кода после git pull,
/// подозрительный запуск уровня warning): worried и жёлтое, кнопки «Показать / Понятно».
private struct GuardAlertView: View {
    let event: GuardEvent
    let isLive: Bool
    let model: NotchViewModel
    let protection: GuardMonitor
    let explain: ExplainService

    private var explainKey: String { "guard:\(event.id)" }
    /// «Что это?» есть у того, за чем стоит процесс или соединение.
    private var canExplain: Bool { [.process, .network, .agent].contains(event.kind) }

    var body: some View {
        let critical = event.level == .critical
        let tone = critical ? DS.Tone.alarm : DS.Tone.tips
        let state = explain.state(for: explainKey)
        let face = ExplainLook.face(state, default: .main(critical ? .wide : .worried, tone: tone))
        let badge = ExplainLook.badge(state, default: tone)
        let symbol = ExplainLook.symbol(state, default: "exclamationmark")
        AlertCard(face: face, badge: badge, symbol: symbol) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Защита · ", "Guard · ") + (critical ? "" : L("стоит глянуть · ", "worth a look · ")) + event.at.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(DS.Ink.secondary)
                Text(Typography.bind(event.title))
                    .font(.alertTitle)
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail {
                    let lines = detail.split(separator: "\n").prefix(3).map(String.init)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(lines, id: \.self) { line in
                            Text(line).lineLimit(lines.count == 1 ? 2 : 1).truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).fill(DS.Surface.input))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous).stroke(DS.Surface.inputBorder, lineWidth: 1))
                }
                ExplainStateView(state: state, subject: GuardPhrase.programName(event), model: model, retry: { ask() })
                buttons(canAsk: canExplain && state == nil)
                    .padding(.top, 4)
            }
        }
    }

    /// Кнопки по виду записи; «Что это?» — пока не спросили.
    @ViewBuilder
    private func buttons(canAsk: Bool) -> some View {
        if isLive {
            GuardAlertButtons(event: event, canKill: protection.aliveProcesses.contains(event.id), showsShow: true, onExplain: canAsk ? { ask() } : nil) { response in
                protection.respond(event, with: response)
                model.dismissAlert()
            } onShow: {
                model.show(event.kind == .network ? .network : .protection)
            }
        } else if event.kind == .network, event.allowKey != nil {
            // Записка сети: новый адрес у скрипта. «Всегда» — этому скрипту сюда можно.
            FlowLayout(spacing: DS.Spacing.xs) {
                PrimaryButton(L("Понятно", "Got it")) { model.dismissAlert() }
                SecondaryButton(L("Показать", "Show")) { model.show(.network) }
                PlainButton(L("Всегда", "Always")) {
                    protection.respond(event, with: .always)
                    model.dismissAlert()
                }
                .help(L("Этому скрипту сюда можно — больше не замечать", "This script may go there — don’t note it again"))
                if canAsk {
                    PlainButton(L("Что это?", "What is this?")) { ask() }
                }
            }
        } else {
            FlowLayout(spacing: DS.Spacing.xs) {
                PrimaryButton(L("Показать", "Show")) { model.show(.protection) }
                SecondaryButton(L("Понятно", "Got it")) { model.dismissAlert() }
                if canAsk {
                    PlainButton(L("Что это?", "What is this?")) { ask() }
                }
            }
        }
    }

    private func ask() {
        let event = event
        explain.explain(explainKey) { ExplainFacts.guardEvent(event) }
    }
}
