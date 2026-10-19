import Foundation

/// Русская типографика для текста на экране: неразрывные пробелы там, где
/// перенос выглядит неряшливо. Сами фразы (`SummaryPhrase`, `ResourcePhrase`)
/// остаются как есть, правило применяется при показе — в облачке, на карточках.
public enum Typography {
    /// - короткое слово (1–2 буквы: «к», «в», «и», «на») приклеивается к следующему;
    /// - тире приклеивается к предыдущему слову и не начинает строку.
    /// Числа («4к ₽») и слова длиннее не трогаем.
    public static func bind(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = shortWord.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\u{00A0}")
        result = result.replacingOccurrences(of: " —", with: "\u{00A0}—")
        return result
    }

    /// Слово из 1–2 букв, перед которым не буква и не цифра, и пробел после него.
    private static let shortWord = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(\\p{L}{1,2}) ")
}
