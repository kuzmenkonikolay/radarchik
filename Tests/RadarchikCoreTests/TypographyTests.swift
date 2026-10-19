import Testing
@testable import RadarchikCore

/// Неразрывные пробелы в тексте для экрана: «К» не остаётся в конце строки,
/// а тире не начинает новую (скриншот 2026-10-19: «…закончится. К / оплате 4к ₽»).
@Suite("Типографика")
struct TypographyTests {
    let nb = "\u{00A0}"

    @Test func shortWordsStickToTheNextOne() {
        #expect(Typography.bind("К оплате 4к ₽.") == "К\(nb)оплате 4к ₽.")
        #expect(Typography.bind("в плюсе и с ростом") == "в\(nb)плюсе и\(nb)с\(nb)ростом")
        #expect(Typography.bind("Рост к сентябрю") == "Рост к\(nb)сентябрю")
    }

    @Test func dashStaysWithThePreviousWord() {
        #expect(Typography.bind("Закрытых месяцев пока нет — итог") == "Закрытых месяцев пока нет\(nb)— итог")
    }

    @Test func numbersAndLongWordsAreLeftAlone() {
        // «4к» — не слово из букв: пробел перед ₽ уже неразрывный в MoneyFormat.
        #expect(Typography.bind("Октябрь пока: 4к ₽") == "Октябрь пока: 4к ₽")
        #expect(Typography.bind("API для видео") == "API для видео")
        #expect(Typography.bind("") == "")
    }
}
