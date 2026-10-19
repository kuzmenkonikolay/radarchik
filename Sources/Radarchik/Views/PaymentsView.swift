import SwiftUI
import RadarchikCore

/// «Куда платить» в этом месяце: регулярные траты, сгруппированные по месту
/// оплаты, со ссылками на кабинеты. Годовые стоят целиком в месяц продления.
struct PaymentsView: View {
    let model: NotchViewModel
    let store: MoneyStore

    var body: some View {
        let groups = store.payments
        let monthIn = RussianWords.monthPrepositional(store.month.month)
        let month = Words.monthName(store.month.month)

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: L("Куда платить в \(monthIn)", "Where to pay in \(month)"), onBack: { model.pop() }) {
                if !groups.isEmpty {
                    Text(MoneyFormat.fullList(store.dueTotals))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.Ink.primary)
                }
            }

            if groups.isEmpty {
                Hint(L("В \(monthIn) платить некуда: регулярных трат нет или все выключены.",
                       "Nothing to pay in \(month): no recurring costs, or they’re all turned off."))
            } else {
                FitOrScroll(maxHeight: 560) { list(groups) }
            }
        }
    }

    private func list(_ groups: [PaymentGroup]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(groups) { group in
                // Одна карточка: место оплаты с суммой и ссылкой, ниже — траты.
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Ink.primary)
                            .lineLimit(1)
                        // Ссылка — у названия: суммы справа встают ровной колонкой.
                        if let url = group.url {
                            IconButton(systemImage: "arrow.up.right.square", help: L("Открыть ", "Open ") + (url.host() ?? L("кабинет", "dashboard"))) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Spacer(minLength: DS.Spacing.xs)
                        Text(MoneyFormat.fullList(group.totals))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(DS.Ink.primary)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    ForEach(group.items) { item in
                        Rectangle().fill(DS.Surface.hairline).frame(height: 1).padding(.leading, 12)
                        EntryRow(
                            title: item.costName,
                            subtitle: item.period == .yearly ? item.projectName + L(" · раз в год", " · yearly") : item.projectName,
                            amount: MoneyFormat.full(item.amount, item.currency),
                            link: group.url == item.url ? nil : item.url,
                            inGroup: true
                        ) {
                            model.push(.entryForm(.editRecurring(item.id)))
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Surface.card))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            }
        }
    }
}
