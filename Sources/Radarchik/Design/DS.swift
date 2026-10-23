import SwiftUI
import RadarchikCore

/// Дизайн-токены Радарчика (дизайн v2, 2026-10-20, по мотивам Coucou) —
/// единственное место с цветами, радиусами и размерами.
///
/// Монохром: панель чисто чёрная в цвет выреза, карточки чуть светлее и
/// полупрозрачные (сквозь них просвечивает свечение снизу), текст белый и серый.
/// Цвет только со смыслом — состояние денег или настроение проекта; единственное
/// яркое пятно — лицо.
enum DS {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        /// Между карточками.
        static let cards: CGFloat = 10
        /// Отступ панели по бокам и снизу.
        static let panel: CGFloat = 12
    }

    enum Radius {
        static let field: CGFloat = 10
        static let button: CGFloat = 11
        static let chip: CGFloat = 10
        static let pill: CGFloat = 13
        static let card: CGFloat = 22
        static let segment: CGFloat = 12
        static let segmentInner: CGFloat = 9
        static let toolbar: CGFloat = 10
        /// Нижние углы панели: раскрытой и свёрнутой.
        static let panel: CGFloat = 30
        static let collapsed: CGFloat = 14
    }

    enum Size {
        /// Окно панели — с запасом под самую широкую панель и её тень.
        static let panelWidth: CGFloat = 1_040
        static let panelHeight: CGFloat = 760
        /// Свёрнуто: 300×34.
        static let collapsedWidth: CGFloat = 300
        static let collapsedHeight: CGFloat = 34
        /// Тулбар в «ушах» выреза.
        static let toolbarHeight: CGFloat = 40
        static let toolbarButton = CGSize(width: 38, height: 30)
        /// Левая карточка с лицом у формы и у побочных экранов.
        static let faceCard: CGFloat = 200
        /// Пилюля проекта и чип мини-лица в ней.
        static let pillHeight: CGFloat = 42
        static let faceChip = CGSize(width: 36, height: 30)
        /// Высота полей и кнопок: интерфейс для мыши.
        static let control: CGFloat = 34
        static let button: CGFloat = 34
        /// Ползунок разбора: чёрная капсула с мини-лицом.
        static let thumb = CGSize(width: 44, height: 30)
    }

    /// Ширина панели по экранам (высота — по содержимому).
    enum Panel {
        static let home: CGFloat = 860
        static let project: CGFloat = 860
        static let alert: CGFloat = 620
        static let review: CGFloat = 700
        static let tips: CGFloat = 760
        static let add: CGFloat = 820
        /// Побочные экраны: лицо слева, содержимое справа.
        static let side: CGFloat = 760
    }

    enum Ink {
        static let primary = Color(hex: "#F2F3F5")
        /// Фразы, описания.
        static let body = Color(hex: "#C9CCD5")
        /// Подписи, даты.
        static let secondary = Color(hex: "#8E93A0")
        /// Подсказки мелким шрифтом.
        static let muted = Color(hex: "#6B7080")
        /// То, что ещё впереди (пустые кружки шагов).
        static let faint = Color(hex: "#4A4E58")
    }

    enum Surface {
        /// Панель — чёрная, как вырез.
        static let panel = Color.black
        /// Карточки: чуть светлее и полупрозрачные, чтобы просвечивало свечение.
        static let card = Color(red: 22 / 255, green: 23 / 255, blue: 28 / 255).opacity(0.82)
        static let cardBorder = Color.white.opacity(0.07)
        /// Поля, сегмент-контрол, чип мини-лица.
        static let input = Color(hex: "#0B0C0E")
        static let inputBorder = Color(hex: "#26282E")
        /// Пилюли проектов.
        static let pill = Color.white.opacity(0.035)
        static let pillBorder = Color.white.opacity(0.06)
        static let pillHover = Color.white.opacity(0.07)
        /// Второстепенная кнопка и чип сложности.
        static let secondaryButton = Color.white.opacity(0.08)
        static let secondaryHover = Color.white.opacity(0.12)
        static let chip = Color.white.opacity(0.07)
        /// Активная кнопка тулбара.
        static let toolbarActive = Color.white.opacity(0.10)
        static let toolbarHover = Color.white.opacity(0.06)
        /// Тонкая линия между строками.
        static let hairline = Color.white.opacity(0.07)
        /// Дорожка прогресса и рамка ползунка.
        static let progressTrack = Color(hex: "#22242A")
        static let thumbBorder = Color(hex: "#2E3138")
        /// Нулевая линия мини-графика.
        static let baseline = Color(hex: "#2A2D35")
        /// Подложка «цифр по бокам» и значка в строке меню.
        /// Группа строк в настройках — внутри карточки чуть светлее её.
        static let group = Color.white.opacity(0.035)
        static let groupBorder = Color.white.opacity(0.06)
        /// Наведение на строку списка.
        static let rowHover = Color.white.opacity(0.05)
        /// Выбранный сегмент в маленьком переключателе внутри строки.
        static let selected = Color.white.opacity(0.14)
        /// Жёлтая подложка ошибки.
        static let warning = Color(hex: "#2A2112")
    }

    /// Акцент управления: включённый тумблер и рамка поля в фокусе.
    enum Accent {
        static let on = Tone.info
        static let focus = Color.white.opacity(0.28)
    }

    /// Цвета со смыслом.
    enum Tone {
        /// Плюс, успех, «растёт».
        static let plus = Color(hex: "#5BE3A6")
        /// Минус, «пора платить» — оранжевый, не красный.
        static let minus = Color(hex: "#FF8F52")
        /// Разбор дня, «думаю», ровно.
        static let info = Color(hex: "#7FB2FF")
        /// Советы, «проседает».
        static let tips = Color(hex: "#F7C76A")
        static let link = Color(hex: "#8FB8FF")
        /// Проект без доходов — спит.
        static let asleep = Color(hex: "#C9BFF0")
        /// Ночь, нет данных.
        static let dim = Color(hex: "#8E93A0")
        /// Лицо по умолчанию — тёплый белый.
        static let face = Color(hex: "#F4F1EA")
        /// Капля пота.
        static let sweat = Color(hex: "#8EC9FF")
        /// Текст чипа «≈ 2 ч в неделю».
        static let plusChipText = Color(hex: "#6EE7B0")
        /// Чип «К оплате».
        static let payChipBg = Color(hex: "#FF8F52").opacity(0.12)
        static let payChipText = Color(hex: "#FFB08A")
        /// Опасное от «Защиты»: красный — исключение из палитры, чтобы отличаться от «пора платить».
        static let alarm = Color(hex: "#FF5A4F")
    }

    enum Money {
        static let positiveText = Tone.plus
        static let negativeText = Tone.minus
        /// Столбики графика: обычные и последний.
        static let positiveBar = Color(hex: "#2F8F68")
        static let positiveBarLast = Tone.plus
        static let negativeBar = Color(hex: "#A4532B")
        static let negativeBarLast = Tone.minus

        /// Плюс зелёный, минус оранжевый, ноль — обычным текстом.
        static func text(for value: Int64) -> Color {
            value > 0 ? positiveText : value < 0 ? negativeText : Ink.body
        }
    }

    /// Графики величин (процессор, память): спокойный синий.
    enum Chart {
        static let bar = Tone.info
    }

    /// Свечение снизу панели: цвет состояния и его сила по экранам.
    enum Glow {
        static let home = 0.20
        static let project = 0.22
        static let income = 0.32
        static let pay = 0.30
        static let review = 0.22
        static let tips = 0.20
        static let add = 0.07
        static let side = 0.12
    }

    /// Пружина панели и лица (SPEC Coucou).
    static var spring: Animation { .spring(response: 0.38, dampingFraction: 0.78) }
    /// Смена эмоции.
    static var emotionAnimation: Animation { .easeInOut(duration: 0.25) }
    /// Взгляд за курсором.
    static var gazeAnimation: Animation { .spring(response: 0.35, dampingFraction: 0.8) }

    /// Цвет огонька по сигналу денег — им светится лицо.
    static func antenna(_ signal: AntennaSignal) -> Color { tone(signal) }

    static func tone(_ signal: AntennaSignal) -> Color {
        switch signal {
        case .green: Tone.plus
        case .blue: Tone.info
        case .yellow: Tone.tips
        case .orange: Tone.minus
        case .dim: Tone.dim
        case .tipsReady: Tone.tips
        }
    }

    /// Цвет настроения проекта: по нему красятся лицо в пилюле и точка в шапке.
    static func tone(_ mood: Mood) -> Color {
        switch mood {
        case .growing: Tone.plus
        case .stable: Tone.info
        case .declining: Tone.tips
        case .losing: Tone.minus
        case .sleeping: Tone.asleep
        }
    }

    /// Палитра цветов проекта (выбирается при создании): лицо проекта,
    /// пока у него нет закрытого месяца и настроения.
    static let projectColors = ["#5BE3A6", "#7FB2FF", "#F7C76A", "#FF9F73", "#C9BFF0", "#5CD6E0", "#F59BD0", "#E8E8EC"]
}

extension Color {
    /// «#RRGGBB» → Color (sRGB). Неверная строка даёт чёрный.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Font {
    /// Главная цифра: 34 bold, трекинг −0.7 (трекинг вешается отдельно).
    static let hero = Font.system(size: 34, weight: .bold)
    static let projectHero = Font.system(size: 32, weight: .bold)
    static let alertTitle = Font.system(size: 21, weight: .bold)
    static let tipTitle = Font.system(size: 18, weight: .bold)
    static let alertAside = Font.system(size: 22, weight: .bold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodyBold = Font.system(size: 13, weight: .bold)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let captionBold = Font.system(size: 12, weight: .bold)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let label = Font.system(size: 11, weight: .semibold)
    static let badge = Font.system(size: 11, weight: .bold)
}

extension Mood {
    /// Значок настроения: цвет никогда не говорит один.
    var icon: String {
        switch self {
        case .growing: "arrow.up.right"
        case .stable: "arrow.right"
        case .declining: "arrow.down.right"
        case .losing: "exclamationmark"
        case .sleeping: "moon.zzz"
        }
    }

    var label: String {
        switch self {
        case .growing: L("растёт", "growing")
        case .stable: L("ровно", "steady")
        case .declining: L("проседает", "dipping")
        case .losing(let streak): streak >= 2 ? L("в минусе \(streak)-й месяц", "at a loss, \(Words.ordinal(streak)) month") : L("в минусе", "at a loss")
        case .sleeping: L("пока без доходов", "no income yet")
        }
    }
}
