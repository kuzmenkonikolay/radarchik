import Foundation

/// Русские слова для фраз Радарчика: месяцы, порядковые, склонение по числу.
public enum RussianWords {
    private static let months = [
        "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
        "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
    ]
    private static let monthsShort = ["янв", "фев", "мар", "апр", "май", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
    /// «в октябре»
    private static let monthsPrepositional = [
        "январе", "феврале", "марте", "апреле", "мае", "июне",
        "июле", "августе", "сентябре", "октябре", "ноябре", "декабре",
    ]
    /// «18 октября»
    private static let monthsGenitive = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]
    /// «к сентябрю»
    private static let monthsDative = [
        "январю", "февралю", "марту", "апрелю", "маю", "июню",
        "июлю", "августу", "сентябрю", "октябрю", "ноябрю", "декабрю",
    ]
    private static let ordinals = [
        1: "первый", 2: "второй", 3: "третий", 4: "четвёртый", 5: "пятый", 6: "шестой",
        7: "седьмой", 8: "восьмой", 9: "девятый", 10: "десятый", 11: "одиннадцатый", 12: "двенадцатый",
    ]

    /// «Октябрь»
    public static func monthName(_ month: Int) -> String { months[month - 1] }
    /// «окт» — подписи на графике.
    public static func monthShort(_ month: Int) -> String { monthsShort[month - 1] }
    /// «октябре» — для «в октябре».
    public static func monthPrepositional(_ month: Int) -> String { monthsPrepositional[month - 1] }
    /// «октября» — для «18 октября».
    public static func monthGenitive(_ month: Int) -> String { monthsGenitive[month - 1] }
    /// «сентябрю» — для «к сентябрю».
    public static func monthDative(_ month: Int) -> String { monthsDative[month - 1] }
    /// «Октябрь 2026»
    public static func monthYear(_ month: YearMonth) -> String { "\(monthName(month.month)) \(month.year)" }

    /// Порядковое мужского рода: «третий» (месяц). Дальше двенадцати — «14-й».
    public static func ordinal(_ number: Int) -> String { ordinals[number] ?? "\(number)-й" }

    /// Форма слова по числу: 1 совет, 3 совета, 11 советов, 22 совета.
    public static func plural(_ number: Int, _ one: String, _ few: String, _ many: String) -> String {
        let lastDigit = abs(number) % 10
        let lastTwo = abs(number) % 100
        if lastDigit == 1 && lastTwo != 11 { return one }
        if (2...4).contains(lastDigit) && !(12...14).contains(lastTwo) { return few }
        return many
    }
}
