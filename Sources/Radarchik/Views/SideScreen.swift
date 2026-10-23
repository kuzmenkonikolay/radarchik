import SwiftUI
import RadarchikCore

/// Побочный экран (система, защита, настройки, наблюдение…): слева карточка
/// 200 с лицом и фразой от него, справа карточка с содержимым.
struct SideScreen<Content: View>: View {
    let face: FaceSpec
    let phrase: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.cards) {
            FaceCard(face: face, phrase: phrase)
            Card(vertical: 16, horizontal: 18) {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Узкая карточка с лицом и подписью — у форм и побочных экранов.
struct FaceCard: View {
    let face: FaceSpec
    let phrase: String
    var width: CGFloat = DS.Size.faceCard

    var body: some View {
        Card(vertical: 20, horizontal: 16) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                FacePlaceholder(spec: face, width: 120)
                Text(Typography.bind(phrase))
                    .font(.body)
                    .foregroundStyle(DS.Ink.body)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }
}

/// Колонка с лицом и бейджем статуса в левом верхнем углу — у главной, проекта, алертов.
struct FaceColumn: View {
    let face: FaceSpec
    let badge: Color
    var symbol: String?
    var text: String?
    var width: CGFloat = 140

    var body: some View {
        ZStack(alignment: .topLeading) {
            FacePlaceholder(spec: face, width: 120)
                .frame(width: width, height: 112)
            StatusBadge(color: badge, symbol: symbol, text: text)
        }
        .frame(width: width)
    }
}

/// Фразы Радарчика на побочных экранах — про то, что открыто.
@MainActor
enum SidePhrases {
    static func system(_ resources: ResourceMonitor) -> String {
        guard let system = resources.system else {
            return L("Первый замер — через пару секунд.", "First reading in a couple of seconds.")
        }
        var sentences: [String] = []
        if system.memory?.pressure == .critical {
            sentences.append(ResourcePhrase.pressure() + ".")
        } else if system.thermal >= .serious {
            sentences.append(ResourcePhrase.thermal(temperature: system.temperature) + ".")
        } else {
            sentences.append(L("Всё спокойно: никто не ест больше обычного.", "All calm: nothing is eating more than usual."))
        }
        if resources.normsCount == 0 {
            sentences.append(L("Нормы приложений копятся неделю.", "App norms take a week to learn."))
        }
        return sentences.joined(separator: " ")
    }

    static func observation(_ settings: AppSettings) -> String {
        settings.observationEnabled
            ? L("Записываю день: приложения, сайты, команды без секретов. Экран, клавиши и буфер — никогда.",
                "Logging the day: apps, sites, commands without secrets. Never the screen, keystrokes or clipboard.")
            : L("Ничего не пишу, только замечаю звонки, чтобы прятать цифры. Включи — и из дня будут советы.",
                "Logging nothing, only noticing calls to hide the numbers. Turn it on, and the day turns into tips.")
    }

    static func today(_ tracker: ActivityTracker) -> String {
        let today = tracker.todaySummary()
        guard today.activeSeconds > 0 || !today.apps.isEmpty || !today.commands.isEmpty || today.callCount > 0 else {
            return L("Сегодня пока ничего не записано.", "Nothing logged today yet.")
        }
        let active = DurationFormat.short(today.activeSeconds)
        guard let top = today.apps.first else {
            return L("За компьютером \(active).", "At the computer for \(active).")
        }
        return L("За компьютером \(active). Больше всего — \(top.appName), \(DurationFormat.short(top.seconds)).",
                 "At the computer for \(active). Most of it — \(top.appName), \(DurationFormat.short(top.seconds)).")
    }

    static func notch(_ model: NotchViewModel) -> String {
        let rect = model.geometry.notchRect
        let size = "\(Int(rect.width))×\(Int(rect.height)) pt"
        return model.geometry.isHardware
            ? L("Чёлка настоящая, \(size), — тут я и живу.", "A real notch, \(size) — that’s where I live.")
            : L("Выреза на этом экране нет — рисую свою чёлку по центру, \(size).", "This screen has no notch — I draw my own in the center, \(size).")
    }

    static func claude(_ review: ReviewService) -> String {
        review.hasAPIKey
            ? L("Ключ в Связке ключей. В Claude уходит только сводка дня.", "The key is in Keychain. Only the day’s summary goes to Claude.")
            : L("Чтобы разбирать день, нужен ключ Claude API. Сырой лог остаётся на маке.", "To review your day, add a Claude API key. The raw log stays on this Mac.")
    }

    static func payments(_ store: MoneyStore) -> String {
        let monthIn = RussianWords.monthPrepositional(store.month.month)
        let month = Words.monthName(store.month.month)
        let due = store.dueTotals
        guard !due.isEmpty else {
            return L("В \(monthIn) платить некуда: регулярных трат нет или все выключены.",
                     "Nothing to pay in \(month): no recurring costs, or they’re all turned off.")
        }
        return L("В \(monthIn) к оплате \(MoneyFormat.fullList(due)) — по ссылкам в кабинеты.",
                 "Due in \(month): \(MoneyFormat.fullList(due)) — the links open the dashboards.")
    }
}
