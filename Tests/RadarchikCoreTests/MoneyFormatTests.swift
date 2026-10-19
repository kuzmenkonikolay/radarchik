import Testing
@testable import RadarchikCore

@Suite("Формат и ввод сумм")
struct MoneyFormatTests {
    let nb = "\u{00A0}"
    let minus = "\u{2212}"

    @Test func fullGroupsThousandsAndShowsKopecksOnlyWhenNeeded() {
        #expect(MoneyFormat.full(3_050_000, .rub) == "30\(nb)500\(nb)₽")
        #expect(MoneyFormat.full(120_050, .usd) == "1\(nb)200,50\(nb)$")
        #expect(MoneyFormat.full(99_900, .rub) == "999\(nb)₽")
        #expect(MoneyFormat.full(-50_000, .eur) == "\(minus)500\(nb)€")
        #expect(MoneyFormat.full(12_345_678_900, .rub) == "123\(nb)456\(nb)789\(nb)₽")
    }

    @Test func signedFullAlwaysHasSignExceptZero() {
        #expect(MoneyFormat.signedFull(4_680_000, .rub) == "+46\(nb)800\(nb)₽")
        #expect(MoneyFormat.signedFull(-4_680_000, .rub) == "\(minus)46\(nb)800\(nb)₽")
        #expect(MoneyFormat.signedFull(0, .rub) == "0\(nb)₽")
    }

    @Test func compactForTheNotch() {
        #expect(MoneyFormat.compact(3_050_000, .rub) == "30,5к\(nb)₽")
        #expect(MoneyFormat.compact(4_680_000, .rub, signed: true) == "+46,8к\(nb)₽")
        #expect(MoneyFormat.compact(-1_550_000, .rub, signed: true) == "\(minus)15,5к\(nb)₽")
        #expect(MoneyFormat.compact(3_000_000, .rub) == "30к\(nb)₽")
        #expect(MoneyFormat.compact(95_000, .rub) == "950\(nb)₽")
        #expect(MoneyFormat.compact(2_000, .usd) == "20\(nb)$")
        #expect(MoneyFormat.compact(120_000_000, .rub) == "1,2м\(nb)₽")
        #expect(MoneyFormat.compact(99_995_000, .rub) == "1м\(nb)₽")   // 999 950 ₽ округляем до миллиона
        #expect(MoneyFormat.compact(99_950, .rub) == "1к\(nb)₽")       // 999,50 ₽ → 1к
        #expect(MoneyFormat.compact(0, .rub, signed: true) == "0\(nb)₽")
    }

    @Test func compactListJoinsCurrencies() {
        let amounts = [CurrencyAmount(currency: .rub, amount: 4_680_000), CurrencyAmount(currency: .usd, amount: -20_000)]
        #expect(MoneyFormat.compactList(amounts, signed: true) == "+46,8к\(nb)₽ · \(minus)200\(nb)$")
    }

    @Test func percentIsRoundedWithSign() {
        #expect(MoneyFormat.percent(12.4) == "+12%")
        #expect(MoneyFormat.percent(-3.6) == "\(minus)4%")
        #expect(MoneyFormat.percent(0.2) == "0%")
    }

    @Test(arguments: [
        ("15500", Int64(1_550_000)),
        ("15 500", 1_550_000),
        ("15\u{00A0}500,5", 1_550_050),
        ("15500.50", 1_550_050),
        ("1 200 ₽", 120_000),
        ("$20", 2_000),
    ])
    func parsesHumanInput(text: String, expected: Int64) {
        #expect(MoneyParser.parse(text) == expected)
    }

    @Test(arguments: ["", "0", "0,00", "-100", "12,345", "abc", "1.2.3", ",5"])
    func rejectsNonsense(text: String) {
        #expect(MoneyParser.parse(text) == nil)
    }

    @Test func editingStringIsPlain() {
        #expect(MoneyParser.editingString(1_550_000) == "15500")
        #expect(MoneyParser.editingString(1_550_050) == "15500,50")
        #expect(MoneyParser.editingString(1_550_005) == "15500,05")
    }

    // MARK: - По-английски (2026-10-19): символ впереди, точка в дробях, запятая в разрядах

    @Test func englishFormats() {
        english {
            #expect(MoneyFormat.full(3_050_000, .rub) == "₽30,500")
            #expect(MoneyFormat.full(120_050, .usd) == "$1,200.50")
            #expect(MoneyFormat.full(-50_000, .eur) == "\(minus)€500")
            #expect(MoneyFormat.signedFull(4_680_000, .usd) == "+$46,800")
            #expect(MoneyFormat.signedFull(0, .usd) == "$0")
            #expect(MoneyFormat.compact(3_050_000, .usd) == "$30.5k")
            #expect(MoneyFormat.compact(-1_550_000, .usd, signed: true) == "\(minus)$15.5k")
            #expect(MoneyFormat.compact(120_000_000, .rub) == "₽1.2M")
            #expect(MoneyFormat.compact(95_000, .eur) == "€950")
            #expect(MoneyFormat.compact(0, .usd, signed: true) == "$0")
            let amounts = [CurrencyAmount(currency: .rub, amount: 4_680_000), CurrencyAmount(currency: .usd, amount: -20_000)]
            #expect(MoneyFormat.compactList(amounts, signed: true) == "+₽46.8k · \(minus)$200")
        }
    }

    @Test(arguments: [
        ("15500", Int64(1_550_000)),
        ("15,500", 1_550_000),
        ("1,200.50", 120_050),
        ("15500.5", 1_550_050),
        ("$20", 2_000),
        ("1,234,567", 123_456_700),
    ])
    func parsesEnglishInput(text: String, expected: Int64) {
        english { #expect(MoneyParser.parse(text) == expected) }
    }

    /// По-английски запятая — только разделитель тысяч: «15,5» — ошибка, а не 15,5.
    @Test(arguments: ["15,5", "12,34", "1,2345", ",500", "1.2.3", "0"])
    func rejectsAmbiguousEnglishInput(text: String) {
        english { #expect(MoneyParser.parse(text) == nil) }
    }

    @Test func englishEditingStringUsesDot() {
        english { #expect(MoneyParser.editingString(1_550_050) == "15500.50") }
    }
}
