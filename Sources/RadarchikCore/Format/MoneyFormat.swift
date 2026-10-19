import Foundation

/// Как показываем деньги. Форматируем руками, а не через NumberFormatter:
/// результат не зависит от локали системы и точно совпадает с ТЗ —
/// компактно в чёлке (`30,5к ₽`), полностью в деталях (`30 500 ₽`).
///
/// По-английски (2026-10-19) — символ впереди, точка в дробях и запятая
/// в разрядах: `$30.5k`, `$30,500`.
public enum MoneyFormat {
    /// Неразрывный пробел: между разрядами и перед символом валюты.
    static let nbsp = "\u{00A0}"
    /// Типографский минус, а не дефис.
    static let minus = "\u{2212}"

    /// «30 500 ₽», «1 200,50 $». Копейки — только если они есть.
    public static func full(_ minor: Int64, _ currency: Currency) -> String {
        compose(sign(of: minor, plus: false), fullBody(minor.magnitude), currency)
    }

    /// То же со знаком: «+30 500 ₽», «−30 500 ₽», «0 ₽». Для итогов.
    public static func signedFull(_ minor: Int64, _ currency: Currency) -> String {
        compose(sign(of: minor, plus: true), fullBody(minor.magnitude), currency)
    }

    /// Компактно для чёлки и чипов: «950 ₽», «30,5к ₽», «1,2м ₽».
    /// Округление «школьное», в целых числах, чтобы не ловить ошибки Double.
    public static func compact(_ minor: Int64, _ currency: Currency, signed: Bool = false) -> String {
        let value = minor.magnitude
        let body: String
        let wholeUnits = (value + 50) / 100
        if wholeUnits < 1_000 {
            body = "\(wholeUnits)"
        } else {
            // Десятые доли тысячи: 1к = 100 000 коп., 0,1к = 10 000 коп.
            let thousandsTenths = (value + 5_000) / 10_000
            if thousandsTenths < 10_000 {
                body = tenths(thousandsTenths) + L("к", "k")
            } else {
                let millionsTenths = (value + 5_000_000) / 10_000_000
                body = tenths(millionsTenths) + L("м", "M")
            }
        }
        let isZero = body == "0"
        return compose(isZero ? "" : sign(of: minor, plus: signed), body, currency)
    }

    /// Несколько валют через точку: «+46,8к ₽ · −200 $».
    public static func compactList(_ amounts: [CurrencyAmount], signed: Bool = false) -> String {
        amounts.map { compact($0.amount, $0.currency, signed: signed) }.joined(separator: " · ")
    }

    /// То же полностью: «30 500 ₽ · 20 $».
    public static func fullList(_ amounts: [CurrencyAmount], signed: Bool = false) -> String {
        amounts.map { signed ? signedFull($0.amount, $0.currency) : full($0.amount, $0.currency) }
            .joined(separator: " · ")
    }

    /// Рост: «+12%», «−4%», «0%».
    public static func percent(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded > 0 { return "+\(rounded)%" }
        if rounded < 0 { return minus + "\(-rounded)%" }
        return "0%"
    }

    // MARK: - Внутреннее

    /// По-русски символ после суммы, по-английски — перед ней (знак всё равно первый: «−$500»).
    private static func compose(_ sign: String, _ body: String, _ currency: Currency) -> String {
        switch Language.current {
        case .ru: sign + body + nbsp + currency.symbol
        case .en: sign + currency.symbol + body
        }
    }

    private static func sign(of value: Int64, plus: Bool) -> String {
        if value < 0 { return minus }
        if value > 0 && plus { return "+" }
        return ""
    }

    private static func fullBody(_ minor: UInt64) -> String {
        let units = minor / 100
        let cents = minor % 100
        let grouped = groupThousands(units)
        return cents == 0 ? grouped : grouped + L(",", ".") + String(format: "%02llu", cents)
    }

    /// 30500 → «30 500» (разряды через неразрывный пробел), по-английски «30,500».
    private static func groupThousands(_ value: UInt64) -> String {
        let separator = L(nbsp, ",")
        let digits = Array(String(value))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result += separator }
            result.append(digit)
        }
        return result
    }

    /// 305 → «30,5» (по-английски «30.5»), 300 → «30».
    private static func tenths(_ value: UInt64) -> String {
        value % 10 == 0 ? "\(value / 10)" : "\(value / 10)" + L(",", ".") + "\(value % 10)"
    }
}

/// Разбор суммы из поля ввода: «15 500», «15500,5», «1 200 ₽» → копейки.
/// По-английски запятая — разделитель тысяч: «15,500», «1,200.50».
public enum MoneyParser {
    /// nil — если не число, ноль, отрицательное или больше двух знаков после запятой.
    public static func parse(_ text: String) -> Int64? {
        var cleaned = text.filter { !$0.isWhitespace && !"₽$€_".contains($0) }
        switch Language.current {
        case .ru:
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        case .en:
            guard let ungrouped = ungroupEnglish(cleaned) else { return nil }
            cleaned = ungrouped
        }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isASCIIDigit)
        else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 2, fraction.allSatisfy(\.isASCIIDigit) else { return nil }
        fraction += String(repeating: "0", count: 2 - fraction.count)
        guard let units = Int64(whole), let cents = Int64(fraction) else { return nil }
        let (scaled, overflow) = units.multipliedReportingOverflow(by: 100)
        guard !overflow else { return nil }
        let value = scaled + cents
        return value > 0 ? value : nil
    }

    /// Обратно, для редактирования: «15500» или «15500,50» (по-английски «15500.50»).
    public static func editingString(_ minor: Int64) -> String {
        let units = minor / 100
        let cents = minor % 100
        return cents == 0 ? "\(units)" : "\(units)" + L(",", ".") + String(format: "%02lld", cents)
    }

    /// «1,234,567.89» → «1234567.89». Запятая не через три цифры — nil:
    /// «15,5» по-английски скорее опечатка, чем 15,5, — лучше переспросить.
    private static func ungroupEnglish(_ text: String) -> String? {
        guard text.contains(",") else { return text }
        let halves = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let groups = halves[0].split(separator: ",", omittingEmptySubsequences: false)
        guard let first = groups.first, (1...3).contains(first.count),
              groups.dropFirst().allSatisfy({ $0.count == 3 })
        else { return nil }
        return groups.joined() + (halves.count == 2 ? "." + halves[1] : "")
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
