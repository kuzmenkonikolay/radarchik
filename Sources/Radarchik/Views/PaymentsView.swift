import AppKit
import SwiftUI
import RadarchikCore

/// Куда платить в этом месяце: регулярные траты по месту оплаты, со ссылками
/// на кабинеты. Годовые стоят целиком в месяц продления. Сумму месяца говорит лицо.
struct PaymentsScreen: View {
    let model: NotchViewModel
    let store: MoneyStore
    let look: MascotLook

    var body: some View {
        SideScreen(face: look.spec, phrase: SidePhrases.payments(store)) {
            let groups = store.payments
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack {
                    Text(L("Куда платить", "Where to pay"))
                        .font(.bodyBold)
                        .foregroundStyle(DS.Ink.primary)
                    Spacer(minLength: 0)
                    if !store.dueTotals.isEmpty {
                        Text(MoneyFormat.fullList(store.dueTotals))
                            .font(.bodyBold)
                            .monospacedDigit()
                            .foregroundStyle(DS.Tone.payChipText)
                    }
                }
                if groups.isEmpty {
                    Hint(L("Заведи регулярную трату — она появится здесь вместе со ссылкой, где платить.",
                           "Add a recurring cost — it will show up here with a link to where you pay."))
                } else {
                    FitOrScroll(maxHeight: 420) { list(groups) }
                }
            }
        }
    }

    private func list(_ groups: [PaymentGroup]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(groups) { group in
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(group.title)
                            .font(.bodySemibold)
                            .foregroundStyle(DS.Ink.primary)
                            .lineLimit(1)
                        if let url = group.url {
                            IconButton(systemImage: "arrow.up.right", help: L("Открыть ", "Open ") + (url.host() ?? L("кабинет", "dashboard"))) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Spacer(minLength: DS.Spacing.xs)
                        Text(MoneyFormat.fullList(group.totals))
                            .font(.bodySemibold)
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
                .background(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).fill(DS.Surface.group))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous).stroke(DS.Surface.groupBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous))
            }
        }
    }
}
