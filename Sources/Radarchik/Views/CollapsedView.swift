import SwiftUI
import RadarchikCore

/// Свёрнутая чёлка. В самом вырезе пикселей нет, поэтому видно только то,
/// что выступает: подбородок с глазами (их рисует `NotchFace`).
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
    let resources: ResourceMonitor

    var body: some View {
        let showWings = settings.showNumbersWhenCollapsed && !tracker.isInCall
        let system = systemItems
        // «К оплате» — только вместо системы, если за ресурсами не следим: иначе правое крыло пустовало бы.
        let money = moneyItems + (system.isEmpty ? dueItems : [])
        let wings = showWings ? WingItem.arrange(money: money, system: system) : (leading: [], trailing: [])

        CollapsedMascot(notchSize: model.geometry.notchRect.size, leading: wings.leading, trailing: wings.trailing)
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
/// Глаза остаются в подбородке, как у свёрнутой (их рисует `NotchFace`), —
/// здесь под них только место, фраза ниже.
struct AnnouncementView: View {
    let alert: ResourceAlert
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight + NotchShape.chin.height)
            Text(alert.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Ink.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .frame(width: DS.Size.announcementWidth)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Радарчик: ", "Radarchik: ") + alert.speech)
    }
}
