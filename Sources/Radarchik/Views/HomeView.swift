import SwiftUI
import RadarchikCore

/// Главная (экран A): слева лицо, месяц, крупный итог месяца «пока», одна фраза
/// и чип «К оплате»; справа проекты пилюлями. Если есть тревога (приложение
/// ест больше обычного, опасное от «Защиты»), фраза и чип уступают ей место:
/// одна мысль за раз.
struct HomeView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor

    var body: some View {
        let look = FaceDirector.look(model: model, store: store, review: review, tracker: tracker, resources: resources, protection: protection)
        let available = model.panelWidth - 2 * DS.Spacing.panel - DS.Spacing.cards
        HStack(alignment: .top, spacing: DS.Spacing.cards) {
            Card(vertical: 18, horizontal: 20) {
                HStack(alignment: .center, spacing: 16) {
                    FaceColumn(face: look.spec, badge: look.tone, width: 128)
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(dot: look.tone, title: Words.monthName(store.month.month), subtitle: dayLabel)
                        totals
                        message(look)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: available * 1.15 / 2.15)
            ProjectsCard(store: store, onSelect: { model.push(.project($0)) }, onAdd: { model.push(.projectForm(editing: nil)) })
                .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// «идёт 20-й день».
    private var dayLabel: String {
        let day = Calendar.current.component(.day, from: Date())
        return L("идёт \(day)-й день", "day \(day)")
    }

    /// Крупный итог месяца «пока» по всем проектам; валют несколько — остальные мельче.
    @ViewBuilder
    private var totals: some View {
        let totals = store.monthTotals
        if let main = totals.first {
            HeroAmount(amount: main.amount, currency: main.currency)
            if totals.count > 1 {
                Text(MoneyFormat.compactList(Array(totals.dropFirst()), signed: true))
                    .font(.captionMedium)
                    .monospacedDigit()
                    .foregroundStyle(DS.Ink.secondary)
            }
        } else {
            Text(L("0", "0"))
                .font(.hero)
                .foregroundStyle(DS.Ink.secondary)
        }
    }

    /// Фраза и чип — или тревога с кнопками.
    @ViewBuilder
    private func message(_ look: MascotLook) -> some View {
        if let event = protection.activeAlert {
            phrase(event.title)
            GuardAlertButtons(event: event, canKill: protection.aliveProcesses.contains(event.id), showsShow: true) { response in
                protection.respond(event, with: response)
            } onShow: {
                model.show(.protection)
            }
        } else if let alert = resources.activeAlert {
            phrase(alert.title)
            ResourceAlertButtons(alert: alert, resources: resources) {
                model.show(.system, focus: SystemFocus(metric: SystemMetric(alert.kind), appKey: alert.app?.key))
            }
            .onAppear { resources.markSeen(alert) }
        } else {
            phrase(store.homePhrase)
            if let chip = SummaryPhrase.payChip(store.payments) {
                ChipButton(text: chip) { model.push(.payments) }
                    .padding(.top, 2)
            }
        }
    }

    private func phrase(_ text: String) -> some View {
        Text(Typography.bind(text))
            .font(.body)
            .foregroundStyle(DS.Ink.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
    }
}

/// Кнопки тревоги ресурсов: «Показать», «Это нормально», «Позже».
struct ResourceAlertButtons: View {
    let alert: ResourceAlert
    let resources: ResourceMonitor
    /// «Что это?» — спросить Claude; nil — кнопки нет (на главной и когда уже спросили).
    var onExplain: (() -> Void)? = nil
    let onShow: () -> Void

    var body: some View {
        FlowLayout(spacing: DS.Spacing.xs) {
            PrimaryButton(L("Показать", "Show"), action: onShow)
            SecondaryButton(L("Это нормально", "That’s normal")) { resources.respond(alert, with: .normal) }
            PlainButton(L("Позже", "Later")) { resources.respond(alert, with: .later) }
            if let onExplain {
                PlainButton(L("Что это?", "What is this?")) { onExplain() }
                    .help(L("Спросить Claude, что это за процесс", "Ask Claude what this process is"))
            }
        }
        .padding(.top, 4)
    }
}

/// Кнопки тревоги «Защиты» по её виду: процесс — «Убить / Один раз / Всегда»,
/// чужой с SSH-ключом — «Убить / Понятно / Всегда», остальное — «Показать / Понятно».
struct GuardAlertButtons: View {
    let event: GuardEvent
    var canKill = false
    var showsShow = true
    /// «Что это?» — спросить Claude; nil — кнопки нет.
    var onExplain: (() -> Void)? = nil
    let onRespond: (GuardResponse) -> Void
    let onShow: () -> Void

    var body: some View {
        FlowLayout(spacing: DS.Spacing.xs) {
            if event.kind == .process {
                if canKill {
                    PrimaryButton(L("Убить", "Kill"), systemImage: "xmark.octagon.fill") { onRespond(.kill) }
                    SecondaryButton(L("Один раз", "Allow once")) { onRespond(.once) }
                } else {
                    PrimaryButton(L("Один раз", "Allow once")) { onRespond(.once) }
                }
                PlainButton(L("Всегда", "Always")) { onRespond(.always) }
                    .help(L("Больше не спрашивать про эту программу из этого места", "Don’t ask again about this program from this parent"))
            } else if event.kind == .agent || event.kind == .network {
                if canKill {
                    PrimaryButton(L("Убить", "Kill"), systemImage: "xmark.octagon.fill") { onRespond(.kill) }
                    SecondaryButton(L("Понятно", "Got it")) { onRespond(.dismiss) }
                } else {
                    PrimaryButton(L("Понятно", "Got it")) { onRespond(.dismiss) }
                }
                PlainButton(L("Всегда", "Always")) { onRespond(.always) }
                    .help(event.kind == .network
                        ? L("Этому скрипту сюда можно — больше не тревожиться", "This script may go there — don’t alarm again")
                        : L("Эта программа пользуется ключом законно — больше не тревожиться", "This program uses the key legitimately — don’t alarm again"))
            } else {
                if showsShow {
                    PrimaryButton(L("Показать", "Show"), action: onShow)
                    SecondaryButton(L("Понятно", "Got it")) { onRespond(.dismiss) }
                } else {
                    PrimaryButton(L("Понятно", "Got it")) { onRespond(.dismiss) }
                }
            }
            if let onExplain {
                PlainButton(L("Что это?", "What is this?")) { onExplain() }
                    .help(L("Спросить Claude, что это", "Ask Claude what this is"))
            }
        }
        .padding(.top, 4)
    }
}
