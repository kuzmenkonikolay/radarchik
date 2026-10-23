import SwiftUI
import RadarchikCore

/// Как выглядит Радарчик прямо сейчас: состояние (`MascotBrain`), сигнал денег
/// и готовый `FaceSpec` для главного лица. Экраны со своим лицом (проект,
/// алерты, советы, разбор, формы) задают спецификацию сами.
struct MascotLook {
    let state: MascotState
    let signal: AntennaSignal
    /// Цвет состояния: им светится лицо и свечение панели.
    let tone: Color
    let spec: FaceSpec
}

@MainActor
enum FaceDirector {
    static func look(
        model: NotchViewModel, store: MoneyStore, review: ReviewService, tracker: ActivityTracker,
        resources: ResourceMonitor, protection: GuardMonitor
    ) -> MascotLook {
        let mood = store.overallMood
        let hasNewTips = review.newTipsCount > 0
        let state = MascotBrain.state(
            isExpanded: model.isExpanded,
            mood: mood,
            isResting: model.isResting,
            event: store.mascotEvent,
            hasNewTips: hasNewTips,
            isInCall: tracker.isInCall,
            hasResourceAlert: resources.activeAlert != nil,
            hasGuardAlarm: protection.activeAlert != nil
        )
        let signal: AntennaSignal = hasNewTips ? .tipsReady : (mood?.antenna ?? .dim)
        let tone: Color = switch state {
        case .alarm: DS.Tone.alarm
        case .sleep, .onCall: DS.Tone.dim
        case .catchCoin, .happy: DS.Tone.plus
        case .worried: DS.Tone.tips
        case .nervous: DS.Tone.minus
        default: DS.tone(signal)
        }
        // Навёл курсор на свёрнутую чёлку — на миг заметил тебя.
        let emotion: FaceEmotion = model.isStartled && !model.isExpanded && state != .alarm ? .wide : state.emotion
        return MascotLook(state: state, signal: signal, tone: tone, spec: .main(emotion, tone: tone, hands: state.hands, glasses: state.wearsGlasses))
    }

    /// Лицо на экране проекта: эмоция и цвет настроения; без закрытого месяца — цвет проекта.
    static func project(_ glance: ProjectGlance?) -> FaceSpec {
        guard let glance else { return .main(.smug, tone: DS.Tone.dim) }
        return .project(glance.mood, colorHex: glance.project.colorHex)
    }

    /// Цвет настроения проекта — для точки в шапке, рамки пилюли и свечения.
    static func tone(_ glance: ProjectGlance) -> Color {
        glance.mood.map(DS.tone) ?? Color(hex: glance.project.colorHex)
    }
}
