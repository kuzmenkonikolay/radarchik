import SwiftUI
import RadarchikCore

/// Свёрнутая чёлка. В самом вырезе пикселей нет, поэтому видно только то,
/// что выступает: подбородок с глазами, а у запасных обликов — ухо и огонёк.
/// По настройке «Цифры по бокам чёлки» по бокам выреза крылья:
/// - слева деньги — итог текущего месяца по всем проектам, доходы минус траты
///   (решение 2026-10-19). В начале месяца он в минусе: траты начислены с 1-го,
///   а доходы ещё не пришли, — и растёт по мере доходов;
/// - справа система — процессор и температура (градусов не узнать — занятая память).
/// Чего-то одного нет — оставшееся делится на оба крыла (`WingItem.arrange`).
/// На звонке крыльев нет: вдруг ты показываешь экран.
struct CollapsedView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor

    var body: some View {
        // Готовы советы — огонёк (или глаза) белые, пока их не открыли; иначе — деньги.
        let signal: AntennaSignal = review.newTipsCount > 0 ? .tipsReady : (store.overallMood?.antenna ?? .dim)
        let state = MascotBrain.state(
            isExpanded: false, mood: store.overallMood, isResting: model.isResting, event: store.mascotEvent,
            isInCall: tracker.isInCall, hasResourceAlert: resources.activeAlert != nil
        )
        let showWings = settings.showNumbersWhenCollapsed && !tracker.isInCall
        let system = systemItems
        // «К оплате» — только вместо системы, если за ресурсами не следим: иначе правое крыло пустовало бы.
        let money = moneyItems + (system.isEmpty ? dueItems : [])
        let wings = showWings ? WingItem.arrange(money: money, system: system) : (leading: [], trailing: [])

        CollapsedMascot(
            skin: settings.mascotSkin, state: state, signal: signal, gazeModel: model,
            notchSize: model.geometry.notchRect.size, leading: wings.leading, trailing: wings.trailing
        )
        .contentShape(Rectangle())
    }

    /// Деньги: итог месяца «пока» по всем проектам. Одна валюта — цветом плюса
    /// или минуса; несколько — обычным текстом, через точку.
    private var moneyItems: [WingItem] {
        let totals = store.monthTotals
        guard !totals.isEmpty else { return [] }
        let color = totals.count == 1 ? DS.Money.text(for: totals[0].amount) : DS.Ink.secondary
        return [WingItem(id: "month", icon: "chart.bar.fill", text: MoneyFormat.compactList(totals, signed: true), color: color)]
    }

    /// К оплате в этом месяце — запасная цифра для правого крыла.
    private var dueItems: [WingItem] {
        let due = store.dueTotals
        return due.isEmpty ? [] : [WingItem(id: "due", icon: "creditcard", text: MoneyFormat.compactList(due))]
    }

    /// Система: процессор всего мака и температура чипа, а без датчиков — занятая память.
    private var systemItems: [WingItem] {
        guard settings.resourcesEnabled, let system = resources.system else { return [] }
        var items = [WingItem(id: "cpu", icon: "cpu", text: ResourceFormat.percent(system.cpuPercent), widest: "88%")]
        if let temperature = system.temperature {
            items.append(WingItem(id: "temperature", icon: "thermometer.medium", text: ResourceFormat.temperature(temperature), widest: "88°"))
        } else if let memory = system.memory {
            items.append(WingItem(id: "memory", icon: "memorychip", text: ResourceFormat.bytes(Double(memory.usedBytes)), widest: L("88 ГБ", "88 GB")))
        }
        return items
    }
}

/// Записка под чёлкой (этап 6): Радарчик сам выглядывает и говорит о тревоге —
/// «Chrome ест 4,1 ГБ — в 3 раза больше обычного». Держится 8 секунд; навёл
/// курсор — чёлка раскроется, и в облачке будут кнопки.
///
/// У Живой чёлки глаза остаются в подбородке, как у свёрнутой (их рисует
/// `NotchFace`), — здесь под них только место, фраза ниже.
struct AnnouncementView: View {
    let alert: ResourceAlert
    let skin: MascotSkin
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            if skin == .livingNotch {
                Color.clear.frame(height: skin.bump.height)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // У запасных обликов лица в подбородке нет — тревогу обозначает значок.
                if skin != .livingNotch {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.antenna(.yellow))
                }
                Text(alert.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, skin == .livingNotch ? 4 : DS.Spacing.xs)
            .padding(.bottom, 10)
        }
        .frame(width: DS.Size.announcementWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Радарчик: ", "Radarchik: ") + alert.speech)
    }
}

/// Ухо-локатор Радарчика в свёрнутом виде (заглушка до настоящего персонажа).
struct MascotEar: View {
    var isResting: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(DS.Mascot.ear).frame(width: 12, height: 15)
            Ellipse().fill(DS.Mascot.earDish).frame(width: 7, height: 10).offset(x: -1)
        }
        .rotationEffect(.degrees(isResting ? 35 : -15))
        .opacity(isResting ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.6), value: isResting)
    }
}

/// Огонёк антенки — главный индикатор. Пока Радарчик спит, он тусклее;
/// когда пришёл доход, коротко вспыхивает.
struct AntennaLight: View {
    var signal: AntennaSignal
    var caught = false
    var isResting = false

    var body: some View {
        let color = DS.antenna(signal)
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(isResting ? 0 : 0.9), radius: caught ? 7 : 4)
            .scaleEffect(caught ? 1.35 : 1)
            .opacity(isResting ? 0.45 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: caught)
            .animation(.easeInOut(duration: 0.6), value: isResting)
            .accessibilityLabel(L("Антенка: ", "Antenna: ") + signal.spokenName)
    }
}

extension AntennaSignal {
    var spokenName: String {
        switch self {
        case .green: L("в плюсе и растём", "in profit and growing")
        case .blue: L("в плюсе, ровно", "in profit, steady")
        case .yellow: L("в плюсе, но проседаем", "in profit, but dipping")
        case .orange: L("в минусе", "at a loss")
        case .dim: L("доходов пока нет", "no income yet")
        case .tipsReady: L("готовы советы", "tips are ready")
        }
    }
}
