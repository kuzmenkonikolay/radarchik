import SwiftUI
import RadarchikCore

/// Лицо Живой чёлки поверх панели — одно на свёрнутый и раскрытый вид.
/// При раскрытии те же глаза растут и съезжают на сводку, на внутренних
/// экранах возвращаются в подбородок: не рисуются заново, а перетекают
/// (анимацию задаёт `NotchRootView` вместе с фигурой).
struct NotchFace: View {
    let model: NotchViewModel
    let store: MoneyStore
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let eyes: EyeStyle

    var body: some View {
        let placement = FacePlacement(isExpanded: model.isExpanded, route: model.route)
        let mood = store.overallMood
        let hasNewTips = review.newTipsCount > 0
        let state = MascotBrain.state(
            isExpanded: model.isExpanded,
            mood: mood,
            isResting: model.isResting,
            event: store.mascotEvent,
            hasNewTips: hasNewTips,
            isInCall: tracker.isInCall,
            // Кто-то ест больше обычного — беспокоится, пока не ответишь или не пройдёт.
            hasResourceAlert: resources.activeAlert != nil
        )
        // Готовы советы — глаза белые, пока их не открыли; иначе — цвет денег.
        let signal: AntennaSignal = hasNewTips ? .tipsReady : (mood?.antenna ?? .dim)
        GazingFace(
            model: model,
            state: state,
            signal: signal,
            scale: placement.scale,
            eyeCenterY: placement.eyeCenterY(notchHeight: model.geometry.notchRect.height),
            eyes: eyes
        )
    }
}

/// Отдельно, чтобы на движение мыши перерисовывались только глаза, а не
/// подсчёт настроения денег (SwiftUI следит за тем, что читает именно этот body).
private struct GazingFace: View {
    let model: NotchViewModel
    let state: MascotState
    let signal: AntennaSignal
    let scale: CGFloat
    let eyeCenterY: CGFloat
    let eyes: EyeStyle

    var body: some View {
        PlacedLivingFace(state: state, signal: signal, gaze: model.gaze, scale: scale, eyeCenterY: eyeCenterY, eyes: eyes)
    }
}
