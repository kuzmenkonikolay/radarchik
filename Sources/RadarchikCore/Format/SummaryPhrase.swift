import Foundation

/// Что Радарчик говорит, когда выглядывает из чёлки. Это одна-три короткие
/// фразы по шаблону, без LLM. Например:
/// «Октябрь закрыли в плюсе и с ростом. «Лендинг» третий месяц в минусе,
/// «API для видео» проседает. К оплате 30,5к ₽, больше всего Selectel — 15,5к ₽.»
/// По-английски: «October closed in profit and growing. “Landing” is at a loss
/// for the 3rd month, “Video API” is dipping. Due: ₽30.5k, the biggest is Selectel — ₽15.5k.»
///
/// Итоги и настроение берутся за последний закрытый месяц, как у антенки.
/// Платежи — за текущий: платить надо сейчас. Текущий месяц «пока»
/// показывают крыло чёлки и график «Все проекты» (`MoneyEngine.monthTotals`).
public enum SummaryPhrase {
    /// `month` — текущий месяц.
    public static func make(month: YearMonth, ledger: Ledger) -> String {
        guard !ledger.activeProjects.isEmpty else {
            return L("Пока ни одного проекта. Заведи первый — и я начну считать.",
                     "No projects yet. Add your first one and I’ll start counting.")
        }
        let closed = month.previous
        let summaries = MoneyEngine.closedSummaries(currentMonth: month, ledger: ledger)
        let glances = MoneyEngine.glances(currentMonth: month, ledger: ledger).filter { !$0.isFirstMonth }

        var sentences: [String] = []
        if summaries.isEmpty {
            sentences.append(L("Закрытых месяцев пока нет — итог подведу, когда этот закончится.",
                               "No closed months yet — I’ll sum up when this one ends."))
        } else {
            sentences.append(statusSentence(closed: closed, summaries: summaries))
        }
        // С одним проектом его настроение уже сказано в первой фразе.
        if glances.count > 1, let problems = problemsSentence(glances) {
            sentences.append(problems)
        }
        if let payments = paymentsSentence(Payments.groups(month: month, ledger: ledger)) {
            sentences.append(payments)
        }
        return sentences.joined(separator: " ")
    }

    /// Как закрыт месяц — та же таблица, что цвет антенки.
    public static func describe(_ mood: Mood, net: Int64) -> String {
        switch mood {
        case .growing: L("в плюсе и с ростом", "in profit and growing")
        case .stable: net == 0 ? L("в ноль", "at break-even") : L("в плюсе, ровно", "in profit, steady")
        case .declining: L("в плюсе, но с просадкой", "in profit, but dipping")
        case .losing(let streak):
            streak >= 2
                ? L("в минусе — уже \(RussianWords.ordinal(streak)) месяц подряд", "at a loss — \(Words.ordinal(streak)) month in a row")
                : L("в минусе", "at a loss")
        case .sleeping: L("без доходов", "with no income")
        }
    }

    // MARK: - Фразы

    /// «Октябрь закрыли в плюсе и с ростом.» или, если валют несколько,
    /// «Октябрь: ₽ — в плюсе, ровно; $ — в минусе.»
    private static func statusSentence(closed: YearMonth, summaries: [CurrencySummary]) -> String {
        let name = Words.monthName(closed.month)
        if summaries.count == 1, let only = summaries.first {
            return L("\(name) закрыли", "\(name) closed") + " \(describe(only.mood, net: only.current.net))."
        }
        let parts = summaries.map { "\($0.currency.symbol) — \(describe($0.mood, net: $0.current.net))" }
        return "\(name): \(parts.joined(separator: "; "))."
    }

    /// Проблемные проекты: сначала в минусе (дольше — раньше), потом проседающие.
    private static func problemsSentence(_ glances: [ProjectGlance]) -> String? {
        func rank(_ mood: Mood?) -> (Int, Int)? {
            switch mood {
            case .losing(let streak)?: (2, streak)
            case .declining?: (1, 0)
            default: nil
            }
        }
        let problems = glances.enumerated()
            .compactMap { item in rank(item.element.mood).map { (glance: item.element, rank: $0, order: item.offset) } }
            // По убыванию ранга и длины серии, при равенстве — в исходном порядке.
            .sorted { ($1.rank.0, $1.rank.1, $0.order) < ($0.rank.0, $0.rank.1, $1.order) }
            .map { $0.glance }
        guard !problems.isEmpty else { return nil }

        let shown = problems.prefix(3).map { glance -> String in
            let name = Words.quoted(glance.project.name)
            switch glance.mood {
            case .losing(let streak)? where streak >= 2:
                return L("\(name) \(RussianWords.ordinal(streak)) месяц в минусе", "\(name) is at a loss for the \(Words.ordinal(streak)) month")
            case .losing?: return L("\(name) в минусе", "\(name) is at a loss")
            default: return L("\(name) проседает", "\(name) is dipping")
            }
        }
        var text = shown.joined(separator: ", ")
        if problems.count > 3 { text += L(" и ещё \(problems.count - 3)", " and \(problems.count - 3) more") }
        return text + "."
    }

    /// «К оплате 30,5к ₽, больше всего Selectel — 15,5к ₽.»
    private static func paymentsSentence(_ groups: [PaymentGroup]) -> String? {
        let totals = Payments.totals(of: groups)
        guard let primary = totals.max(by: { $0.amount < $1.amount })?.currency else { return nil }
        var text = L("К оплате ", "Due: ") + totals.map { MoneyFormat.compact($0.amount, $0.currency) }.joined(separator: L(" и ", " and "))
        let named = groups.filter { $0.id != Payments.otherGroupID }
        if groups.count == 1, let only = named.first {
            text += L(" — всё в \(only.title)", " — all to \(only.title)")
        } else if groups.count > 1, let top = named.first,
                  let topAmount = top.totals.first(where: { $0.currency == primary }) ?? top.totals.first {
            let amount = MoneyFormat.compact(topAmount.amount, topAmount.currency)
            text += L(", больше всего \(top.title) — \(amount)", ", the biggest is \(top.title) — \(amount)")
        }
        return text + "."
    }
}
