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
}

/// Короткие события, на которые Радарчик реагирует отдельной анимацией.
public enum MascotEvent: Hashable, Sendable {
    case incomeAdded
}

/// Решает, в каком состоянии Радарчик:
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
        hasResourceAlert: Bool = false
    ) -> MascotState {
        if event == .incomeAdded { return .catchCoin }
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
