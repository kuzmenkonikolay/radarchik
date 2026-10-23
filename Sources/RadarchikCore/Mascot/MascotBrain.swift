import Foundation

/// Состояния Радарчика. Сырые значения — имена клипов анимации из ТЗ:
/// когда появится настоящий персонаж (Rive или 3D), рендерер будет
/// проигрывать клип с этим именем.
public enum MascotState: String, CaseIterable, Sendable {
    /// Спрятан в чёлке, торчат уши и антенка.
    case idleScan = "idle_scan"
    /// Выглянул по наведению, настроение ровное.
    case peek
    /// Заметил повторяющееся действие (этап 3).
    case write
    case happy
    case worried
    case nervous
    /// Готов разбор дня (этап 4).
    case tipWave = "tip_wave"
    /// Только что добавили доход.
    case catchCoin = "catch_coin"
    /// Ночь или давно никого нет.
    case sleep
    /// Идёт звонок: глаза прикрыты и тусклые, цифры спрятаны — вдруг ты показываешь экран.
    case onCall = "on_call"
    /// «Защита» заметила опасное: чужая программа взяла SSH-ключ, node -e с eval.
    /// Глаза серьёзные и красные, пока не ответишь (2026-10-20).
    case alarm
}

/// Короткие события, на которые Радарчик реагирует отдельной анимацией.
public enum MascotEvent: Hashable, Sendable {
    case incomeAdded
    /// Итог месяца вырос (доход, убрал или удешевил трату) — на миг радуется (2026-10-19).
    case netGrew
}

/// Решает, в каком состоянии Радарчик:
/// - тревога «Защиты» — серьёзный и красный, что бы ни происходило: опасное важнее
///   звонка, сна и денег (записка о нём тоже висит и на звонке);
/// - свёрнут — сканирует, спит, притих на звонке или беспокоится, если приложение
///   ест больше обычного (о новых советах тогда говорит белый огонёк);
/// - раскрыт — беспокоится о тревоге (о ней облачко), машет блокнотом, если готовы
///   советы, иначе показывает настроение денег.
/// Состояние `write` (заметил повтор) появится, когда эвристики начнут работать на лету.
public enum MascotBrain {
    public static func state(
        isExpanded: Bool,
        mood: Mood?,
        isResting: Bool,
        event: MascotEvent?,
        hasNewTips: Bool = false,
        isInCall: Bool = false,
        hasResourceAlert: Bool = false,
        hasGuardAlarm: Bool = false
    ) -> MascotState {
        if hasGuardAlarm { return .alarm }
        if event == .incomeAdded { return .catchCoin }
        // Итог месяца вырос — щурится от радости, свёрнутый или раскрытый.
        if event == .netGrew { return .happy }
        guard isExpanded else {
            // Звонок важнее сна: человек здесь, просто не трогает клавиатуру.
            // И важнее тревоги: на звонке Радарчик молчит (SPEC §3а).
            if isInCall { return .onCall }
            if isResting { return .sleep }
            // Кто-то ест больше обычного — беспокоится и свёрнутой.
            return hasResourceAlert ? .worried : .idleScan
        }
        // Облачко говорит о тревоге — и лицо под стать.
        if hasResourceAlert { return .worried }
        if hasNewTips { return .tipWave }
        // Раскрыт — значит, ты навёл курсор и ты здесь: не спим, показываем дела.
        switch mood {
        case .growing: return .happy
        case .declining: return .worried
        case .losing: return .nervous
        case .stable, .sleeping, nil: return .peek
        }
    }
}

// MARK: - Лицо (дизайн v2, 2026-10-20)

/// Эмоции лица из мокапа: только глаза и рот, выражение делают форма и наклон век.
public enum FaceEmotion: String, CaseIterable, Sendable {
    /// По умолчанию — «я всё записал».
    case smug
    /// Заметил тебя, пора платить.
    case wide
    /// В плюсе и растёт, пришли деньги.
    case happy
    /// Проседает (с каплей пота).
    case worried
    /// В минусе.
    case sad
    /// Записал, заметил рутину — правый глаз прищурен сильнее.
    case squint
    /// Ночь, ты отошёл.
    case sleep
}

/// Где ручки.
public enum HandsMode: String, Sendable {
    case none
    case down
    case wave
    case up
}

extension MascotState {
    /// Какое лицо у состояния.
    public var emotion: FaceEmotion {
        switch self {
        case .idleScan, .peek, .tipWave: .smug
        case .write: .squint
        case .happy, .catchCoin: .happy
        case .worried: .worried
        case .nervous: .sad
        case .sleep, .onCall: .sleep
        case .alarm: .wide
        }
    }

    /// Советы готовы — надел очки.
    public var wearsGlasses: Bool { self == .tipWave }

    /// Ловит монетку — ручки вверх, советы готовы — машет.
    public var hands: HandsMode {
        switch self {
        case .catchCoin: .up
        case .tipWave: .wave
        default: .none
        }
    }
}

extension Mood {
    /// Лицо проекта в пилюле и на его экране (таблица «Состояния → лицо»).
    public var emotion: FaceEmotion {
        switch self {
        case .growing: .happy
        case .stable: .smug
        case .declining: .worried
        case .losing: .sad
        case .sleeping: .sleep
        }
    }
}
