import Foundation

// Как регулярная трата превращается в деньги по месяцам.
// Две разные величины:
// - accrual — сколько траты приходится на месяц в ИТОГЕ проекта (прибыль, настроение);
// - due — сколько надо ЗАПЛАТИТЬ в месяце (экран «Куда платить»).
// У месячной траты они совпадают, у годовой — нет (решение 2026-10-18):
// итог получает 1/12 каждый месяц, а платёж целиком стоит в месяце продления.

extension RecurringCost {
    /// Цена, действующая в месяце: последняя смена цены не позже него.
    public func price(at month: YearMonth) -> Int64? {
        guard month >= startMonth else { return nil }
        return prices.last(where: { $0.effectiveFrom <= month })?.amount ?? prices.first?.amount
    }

    /// Доля траты в итоге проекта за месяц.
    public func accrual(in month: YearMonth) -> Int64 {
        guard month >= startMonth else { return 0 }
        switch period {
        case .monthly:
            if let endMonth, month > endMonth { return 0 }
            return price(at: month) ?? 0
        case .yearly:
            let offset = month.months(since: startMonth)
            // Месяц продления того «года», в который попадает month.
            let renewal = startMonth.adding(months: offset / 12 * 12)
            // Продления не было (трату выключили раньше) — этот год не начисляем.
            // А уже оплаченный год доначисляется до конца, даже если трату выключили.
            if let endMonth, renewal > endMonth { return 0 }
            let yearly = price(at: renewal) ?? 0
            // Делим на 12 без потерь: остаток копеек раздаём первым месяцам года,
            // чтобы 12 начислений в сумме давали ровно цену.
            let base = yearly / 12
            let remainder = yearly % 12
            return base + (Int64(offset % 12) < remainder ? 1 : 0)
        }
    }

    /// Сколько нужно заплатить в месяце; nil — в этом месяце платить не нужно.
    public func due(in month: YearMonth) -> Int64? {
        guard month >= startMonth else { return nil }
        if let endMonth, month > endMonth { return nil }
        switch period {
        case .monthly:
            return price(at: month)
        case .yearly:
            return month.months(since: startMonth) % 12 == 0 ? price(at: month) : nil
        }
    }

    /// Действует ли трата в этом месяце (переключатель «Активна» в форме).
    /// Трата с будущим стартом тоже считается активной — она запланирована.
    public func isActive(asOf month: YearMonth) -> Bool {
        guard let endMonth else { return true }
        return month <= endMonth
    }

    /// Новая цена с месяца `from`. Более поздние смены цены отбрасываются: новая
    /// цена действует «отсюда и дальше». Месяц раньше старта означает исправить
    /// цену с самого начала (например, опечатку при вводе).
    public func changingPrice(to amount: Int64, from: YearMonth) -> RecurringCost {
        let effective = max(from, startMonth)
        var copy = self
        copy.prices = prices.filter { $0.effectiveFrom < effective }
            + [PriceChange(effectiveFrom: effective, amount: amount)]
        return copy
    }

    /// Сдвиг месяца старта. Первой ценой становится та, что действовала
    /// в новом месяце старта (или самая первая, если старт сдвинули раньше).
    public func withStartMonth(_ newStart: YearMonth) -> RecurringCost {
        var copy = self
        copy.startMonth = newStart
        guard !prices.isEmpty else { return copy }
        let baseIndex = prices.lastIndex(where: { $0.effectiveFrom <= newStart }) ?? 0
        let later = prices[(baseIndex + 1)...].filter { $0.effectiveFrom > newStart }
        copy.prices = [PriceChange(effectiveFrom: newStart, amount: prices[baseIndex].amount)] + later
        return copy
    }
}
