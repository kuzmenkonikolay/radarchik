import SwiftUI
import RadarchikCore

/// Дизайн-токены Радарчика — единственное место с размерами и цветами.
///
/// Панель чёрная, чтобы сливаться с вырезом. Чернила и линии взяты из
/// проверенной тёмной палитры (скилл dataviz). Цвета плюса и минуса прогнаны
/// валидатором на фоне #0F0F0F (2026-10-18):
/// - столбики #008300 / #EC835A различимы при протанопии и дейтеранопии (ΔE 10.1);
/// - текст #0CA30C / #EC835A — контраст на чёрном больше 6:1.
/// Сетка 4pt.
enum DS {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
    }

    enum Radius {
        static let field: CGFloat = 8
        static let chip: CGFloat = 10
        static let card: CGFloat = 14
        /// Нижние углы раскрытой чёлки.
        static let panel: CGFloat = 26
    }

    enum Size {
        /// Ширина раскрытой чёлки.
        static let expandedWidth: CGFloat = 480
        /// Окно панели: с запасом под самый высокий экран (проект).
        static let panelWidth: CGFloat = 540
        static let panelHeight: CGFloat = 720
        static let mascot: CGFloat = 64
        /// Ширина подписей слева в формах.
        static let formLabel: CGFloat = 116
        /// Записка о тревоге под свёрнутой чёлкой (этап 6).
        static let announcementWidth: CGFloat = 360
    }

    enum Ink {
        static let primary = Color(hex: "#F0EFEC")
        static let secondary = Color(hex: "#C3C2B7")
        static let muted = Color(hex: "#898781")
    }

    enum Surface {
        static let panel = Color.black
        static let card = Color.white.opacity(0.06)
        static let cardHover = Color.white.opacity(0.10)
        static let field = Color.white.opacity(0.08)
        static let hairline = Color.white.opacity(0.10)
        /// Нулевая линия графика.
        static let baseline = Color(hex: "#383835")
        static let warning = Color(hex: "#3A2A12")
        /// Выбранный вариант в переключателе, нажатая кнопка, выключенный тумблер.
        static let selected = Color.white.opacity(0.16)
        static let pressed = Color.white.opacity(0.14)
        static let switchOff = Color.white.opacity(0.18)
    }

    /// Акцент управления: включённый тумблер и рамка поля в фокусе — синий графиков.
    enum Accent {
        static let on = Color(hex: "#3987E5")
        static let focus = Color(hex: "#3987E5").opacity(0.8)
    }

    enum Money {
        static let positiveText = Color(hex: "#0CA30C")
        static let negativeText = Color(hex: "#EC835A")
        static let positiveBar = Color(hex: "#008300")
        static let negativeBar = Color(hex: "#EC835A")

        /// Плюс зелёный, минус оранжевый, ноль — обычным текстом.
        static func text(for value: Int64) -> Color {
            value > 0 ? positiveText : value < 0 ? negativeText : Ink.secondary
        }
    }

    /// Графики величин (одна серия, один оттенок): слот 1 тёмной палитры dataviz.
    enum Chart {
        static let bar = Color(hex: "#3987E5")
    }

    /// Цвета Радарчика (заглушка, пока персонаж не утверждён).
    enum Mascot {
        static let bodyTop = Color(hex: "#D3EEFB")
        static let bodyBottom = Color(hex: "#9DD2EF")
        static let ear = Color(hex: "#8CC6E8")
        static let earDish = Color(hex: "#5FA6D3")
        static let ink = Color(hex: "#23232B")
        static let coin = Color(hex: "#FAB219")
    }

    /// Огонёк антенки — главный индикатор денег.
    static func antenna(_ signal: AntennaSignal) -> Color {
        switch signal {
        case .green: Color(hex: "#0CA30C")
        case .blue: Color(hex: "#3987E5")
        case .yellow: Color(hex: "#FAB219")
        case .orange: Color(hex: "#EC835A")
        case .dim: Color(hex: "#898781").opacity(0.6)
        case .tipsReady: .white
        }
    }

    /// Цвета проектов: категориальные шаги тёмной палитры без зелёного
    /// и оранжевого, чтобы проект не путался с плюсом и минусом.
    static let projectColors = ["#3987E5", "#9085E9", "#D55181", "#199E70", "#C98500", "#E66767"]
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

extension Mood {
    /// Значок настроения в чипе: цвет никогда не говорит один, всегда со значком и подписью.
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
