import Testing
@testable import RadarchikCore

/// Язык интерфейса (решение 2026-10-19): по умолчанию как в системе —
/// русская система даёт русский, любая другая английский. В настройках
/// можно выбрать вручную.
@Suite("Язык интерфейса")
struct LanguageTests {
    @Test func russianSystemMeansRussian() {
        #expect(LanguageChoice.system.resolved(preferred: ["ru-RU", "en-US"]) == .ru)
        #expect(LanguageChoice.system.resolved(preferred: ["ru"]) == .ru)
        #expect(LanguageChoice.system.resolved(preferred: ["ru_RU"]) == .ru)
    }

    @Test func anyOtherSystemMeansEnglish() {
        #expect(LanguageChoice.system.resolved(preferred: ["en-US", "ru-RU"]) == .en)
        // Смотрим только на главный язык системы: русский вторым не считается.
        #expect(LanguageChoice.system.resolved(preferred: ["de-DE", "ru-RU"]) == .en)
        #expect(LanguageChoice.system.resolved(preferred: ["uk-UA"]) == .en)
        // Русинский — не русский, хоть код и начинается с «ru».
        #expect(LanguageChoice.system.resolved(preferred: ["rue"]) == .en)
        #expect(LanguageChoice.system.resolved(preferred: []) == .en)
    }

    @Test func manualChoiceWinsOverSystem() {
        #expect(LanguageChoice.en.resolved(preferred: ["ru-RU"]) == .en)
        #expect(LanguageChoice.ru.resolved(preferred: ["en-US"]) == .ru)
    }

    @Test func textFollowsTheCurrentLanguage() {
        english {
            #expect(L("Настройки", "Settings") == "Settings")
        }
        Language.$override.withValue(.ru) {
            #expect(L("Настройки", "Settings") == "Настройки")
        }
    }

    @Test func wordsInBothLanguages() {
        #expect(Words.monthName(10) == "Октябрь")
        #expect(Words.monthShort(10) == "окт")
        #expect(Words.monthYear(ym("2026-10")) == "Октябрь 2026")
        #expect(Words.ordinal(3) == "третий")
        #expect(Words.plural(3, ru: ("совет", "совета", "советов"), en: ("tip", "tips")) == "совета")
        english {
            #expect(Words.monthName(10) == "October")
            #expect(Words.monthShort(10) == "Oct")
            #expect(Words.monthYear(ym("2026-10")) == "October 2026")
            #expect(Words.ordinal(1) == "1st")
            #expect(Words.ordinal(2) == "2nd")
            #expect(Words.ordinal(3) == "3rd")
            #expect(Words.ordinal(4) == "4th")
            #expect(Words.ordinal(11) == "11th")
            #expect(Words.ordinal(12) == "12th")
            #expect(Words.ordinal(13) == "13th")
            #expect(Words.ordinal(21) == "21st")
            #expect(Words.ordinal(22) == "22nd")
            #expect(Words.ordinal(111) == "111th")
            #expect(Words.plural(1, ru: ("совет", "совета", "советов"), en: ("tip", "tips")) == "tip")
            #expect(Words.plural(3, ru: ("совет", "совета", "советов"), en: ("tip", "tips")) == "tips")
            #expect(Words.plural(0, ru: ("совет", "совета", "советов"), en: ("tip", "tips")) == "tips")
        }
    }

    @Test func dayAndMonth() {
        #expect(Words.dayMonth(18, 10) == "18 октября")
        #expect(Words.dayMonth(18, 10, year: 2025) == "18 октября 2025")
        english {
            #expect(Words.dayMonth(18, 10) == "October 18")
            #expect(Words.dayMonth(18, 10, year: 2025) == "October 18, 2025")
        }
    }

    @Test func quotesFollowTheLanguage() {
        #expect(Words.quoted("Лендинг") == "«Лендинг»")
        english {
            #expect(Words.quoted("Landing") == "“Landing”")
        }
    }
}
