import Foundation

/// Строка экрана «Куда платить»: одна регулярная трата этого месяца.
public struct PaymentItem: Identifiable, Hashable, Sendable {
    /// id регулярной траты — по нему открывается её редактирование.
    public let id: UUID
    public let costName: String
    public let projectId: UUID
    public let projectName: String
    public let projectColorHex: String
    public let currency: Currency
    public let amount: Int64
    public let period: CostPeriod
    public let url: URL?
}

/// Группа по месту оплаты: Selectel, Hetzner… или «Другое» для трат без ссылки.
public struct PaymentGroup: Identifiable, Hashable, Sendable {
    /// Домен (`selectel.ru`) или `Payments.otherGroupID`.
    public let id: String
    public let title: String
    /// Ссылка на кабинет — берётся у самой крупной траты группы.
    public let url: URL?
    /// По убыванию суммы.
    public let items: [PaymentItem]
    /// Сумма группы по каждой валюте (порядок: ₽, $, €).
    public let totals: [CurrencyAmount]
}

/// «Куда платить в этом месяце»: регулярные траты, сгруппированные по месту оплаты.
public enum Payments {
    public static let otherGroupID = "other"

    public static func groups(month: YearMonth, ledger: Ledger) -> [PaymentGroup] {
        let projects = Dictionary(uniqueKeysWithValues: ledger.activeProjects.map { ($0.id, $0) })
        let items: [(key: String, item: PaymentItem)] = ledger.recurringCosts.compactMap { cost in
            guard let project = projects[cost.projectId], let amount = cost.due(in: month) else { return nil }
            let item = PaymentItem(
                id: cost.id, costName: cost.name, projectId: project.id, projectName: project.name,
                projectColorHex: project.colorHex, currency: project.currency, amount: amount,
                period: cost.period, url: normalizedURL(cost.url)
            )
            return (key: payeeKey(for: cost.url) ?? otherGroupID, item: item)
        }

        let groups = Dictionary(grouping: items, by: { $0.key }).map { key, entries in
            let sorted = entries.map { $0.item }.sorted { $0.amount > $1.amount }
            return PaymentGroup(
                id: key,
                title: key == otherGroupID ? L("Другое", "Other") : payeeTitle(forKey: key),
                url: key == otherGroupID ? nil : sorted.first?.url,
                items: sorted,
                totals: sumByCurrency(sorted.map { CurrencyAmount(currency: $0.currency, amount: $0.amount) })
            )
        }

        // Сначала крупные получатели в «главной» валюте (где больше всего платежей),
        // при равенстве — по алфавиту. «Другое» всегда в конце.
        let primary = sumByCurrency(groups.flatMap(\.totals)).max { $0.amount < $1.amount }?.currency
        func weight(_ group: PaymentGroup) -> Int64 {
            group.totals.first { $0.currency == primary }?.amount ?? 0
        }
        return groups.sorted { a, b in
            if (a.id == otherGroupID) != (b.id == otherGroupID) { return b.id == otherGroupID }
            if weight(a) != weight(b) { return weight(a) > weight(b) }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
    }

    /// Всего к оплате по каждой валюте.
    public static func totals(of groups: [PaymentGroup]) -> [CurrencyAmount] {
        sumByCurrency(groups.flatMap(\.totals))
    }

    /// Ключ получателя — «регистрируемый» домен: последние две части хоста.
    /// `my.selectel.ru` → `selectel.ru`. Для .co.uk вышло бы неточно, но таких здесь нет.
    public static func payeeKey(for rawURL: String?) -> String? {
        guard let host = normalizedURL(rawURL)?.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").filter { $0 != "www" }
        guard labels.count >= 2 else { return labels.first.map(String.init) }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Название получателя из домена: `selectel.ru` → «Selectel».
    public static func payeeTitle(forKey key: String) -> String {
        let name = key.split(separator: ".").first.map(String.init) ?? key
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Ссылка из того, что ввели руками: без схемы добавляем https://.
    public static func normalizedURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return url
    }

    static func sumByCurrency(_ amounts: [CurrencyAmount]) -> [CurrencyAmount] {
        Currency.allCases.compactMap { currency in
            let matching = amounts.filter { $0.currency == currency }
            guard !matching.isEmpty else { return nil }
            return CurrencyAmount(currency: currency, amount: matching.reduce(0) { $0 + $1.amount })
        }
    }
}

// MARK: - «Пора платить»

/// Приближающееся списание регулярной траты — алерт «Пора платить» (дизайн v2, 2026-10-20).
/// Приходит за `within` дней до дня списания; день задаётся у траты (`dueDay`).
public struct PayReminder: Identifiable, Hashable, Sendable {
    public let costId: UUID
    public let costName: String
    public let projectName: String
    /// Кому платить: «Selectel» по домену ссылки, без ссылки — название траты.
    public let payee: String
    public let url: URL?
    public let amount: Int64
    public let currency: Currency
    public let dueDate: LocalDate
    /// 0 — сегодня, 1 — завтра…
    public let daysLeft: Int

    /// Одна трата — одно напоминание в месяц.
    public var id: String { "\(costId.uuidString)|\(dueDate.yearMonth.stringValue)" }

    public init(costId: UUID, costName: String, projectName: String, payee: String, url: URL?, amount: Int64, currency: Currency, dueDate: LocalDate, daysLeft: Int) {
        self.costId = costId
        self.costName = costName
        self.projectName = projectName
        self.payee = payee
        self.url = url
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
        self.daysLeft = daysLeft
    }
}

extension Payments {
    /// Списания в ближайшие `within` дней (включая сегодня), ближайшие первыми.
    /// Смотрим на текущий и следующий месяц: 30-го числа «через 2 дня» — уже в следующем.
    public static func upcoming(today: LocalDate, within days: Int, ledger: Ledger, calendar: Calendar = .current) -> [PayReminder] {
        let projects = Dictionary(uniqueKeysWithValues: ledger.activeProjects.map { ($0.id, $0) })
        var result: [PayReminder] = []
        for cost in ledger.recurringCosts {
            guard let dueDay = cost.dueDay, let project = projects[cost.projectId] else { continue }
            for month in [today.yearMonth, today.yearMonth.next] {
                guard let amount = cost.due(in: month) else { continue }
                let due = LocalDate(year: month.year, month: month.month, day: min(dueDay, LocalDate.daysIn(year: month.year, month: month.month)))
                let left = calendar.dateComponents([.day], from: today.date(calendar: calendar), to: due.date(calendar: calendar)).day ?? 0
                guard (0...days).contains(left) else { continue }
                let url = normalizedURL(cost.url)
                result.append(PayReminder(
                    costId: cost.id, costName: cost.name, projectName: project.name,
                    payee: payeeKey(for: cost.url).map(payeeTitle(forKey:)) ?? cost.name,
                    url: url, amount: amount, currency: project.currency, dueDate: due, daysLeft: left
                ))
            }
        }
        return result.sorted { ($0.daysLeft, $0.costName) < ($1.daysLeft, $1.costName) }
    }
}
