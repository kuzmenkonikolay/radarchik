import Foundation

/// Настроение проекта (или всей валюты) за месяц — таблица из ТЗ, раздел 2.
public enum Mood: Hashable, Sendable {
    /// Итог > 0 и рост ≥ +5% (или прошлый месяц был ровно в нуле).
    case growing
    /// Итог > 0 и рост от −5% до +5%. Сюда же ровный ноль («вышли в ноль»).
    case stable
    /// Итог > 0, но рост < −5%.
    case declining
    /// Итог < 0. `streak` — сколько месяцев подряд, включая этот, считая с первого дохода.
    case losing(streak: Int)
    /// Доходов ещё не было ни разу.
    case sleeping

    /// Чем больше, тем хуже. «Спит» — самый слабый сигнал: он не перебивает
    /// настоящие цифры других валют, но если спят все, антенка тусклая.
    var severity: Int {
        switch self {
        case .sleeping: 0
        case .growing: 1
        case .stable: 2
        case .declining: 3
        case .losing: 4
        }
    }

    /// Худшее настроение: по нему горит антенка, когда валют несколько.
    public static func worst(_ moods: [Mood]) -> Mood? {
        moods.max { $0.severity < $1.severity }
    }

    public var antenna: AntennaSignal {
        switch self {
        case .growing: .green
        case .stable: .blue
        case .declining: .yellow
        case .losing: .orange
        case .sleeping: .dim
        }
    }
}

/// Огонёк на антенке — главный индикатор Радарчика.
public enum AntennaSignal: Hashable, Sendable {
    case green
    case blue
    case yellow
    case orange
    /// Нет данных или доходов ещё не было.
    case dim
    /// Мигает белым: готовы советы дня (этап 4).
    case tipsReady
}
