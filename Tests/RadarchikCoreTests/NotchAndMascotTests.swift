import CoreGraphics
import Testing
@testable import RadarchikCore

@Suite("Геометрия чёлки")
struct NotchGeometryTests {
    @Test func hardwareNotchIsBetweenAuxiliaryAreas() {
        let geometry = NotchGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 38, leftAreaWidth: 662, rightAreaWidth: 662, menuBarHeight: 38
        )
        #expect(geometry.isHardware)
        #expect(geometry.notchRect == CGRect(x: 662, y: 944, width: 188, height: 38))
    }

    @Test func screenOffsetIsRespected() {
        let geometry = NotchGeometry.compute(
            screenFrame: CGRect(x: -1512, y: 200, width: 1512, height: 982),
            safeAreaTop: 38, leftAreaWidth: 662, rightAreaWidth: 662, menuBarHeight: 38
        )
        #expect(geometry.notchRect.origin == CGPoint(x: -850, y: 1144))
    }

    @Test func virtualNotchWithoutCutout() {
        let geometry = NotchGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, leftAreaWidth: nil, rightAreaWidth: nil, menuBarHeight: 24
        )
        let width = NotchGeometry.virtualWidth
        #expect(!geometry.isHardware)
        #expect(geometry.notchRect == CGRect(x: 1280 - width / 2, y: 1416, width: width, height: 24))
    }
}

@Suite("Состояние Радарчика")
struct MascotBrainTests {
    @Test func collapsedScansOrSleeps() {
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: false, event: nil) == .idleScan)
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: true, event: nil) == .sleep)
    }

    @Test func expandedShowsMood() {
        #expect(MascotBrain.state(isExpanded: true, mood: .growing, isResting: false, event: nil) == .happy)
        #expect(MascotBrain.state(isExpanded: true, mood: .declining, isResting: false, event: nil) == .worried)
        #expect(MascotBrain.state(isExpanded: true, mood: .losing(streak: 2), isResting: false, event: nil) == .nervous)
        #expect(MascotBrain.state(isExpanded: true, mood: .stable, isResting: false, event: nil) == .peek)
        #expect(MascotBrain.state(isExpanded: true, mood: .sleeping, isResting: false, event: nil) == .peek)
        #expect(MascotBrain.state(isExpanded: true, mood: nil, isResting: false, event: nil) == .peek)
        // Раз навёл курсор на чёлку — значит, ты здесь, и Радарчик не спит.
        #expect(MascotBrain.state(isExpanded: true, mood: .growing, isResting: true, event: nil) == .happy)
    }

    @Test func newIncomeIsCaught() {
        #expect(MascotBrain.state(isExpanded: false, mood: .losing(streak: 1), isResting: false, event: .incomeAdded) == .catchCoin)
    }

    @Test func callHushesCollapsedMascot() {
        // На звонке свёрнутая чёлка притихает: глаза прикрыты, цифры спрятаны.
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: false, event: nil, isInCall: true) == .onCall)
        // Звонок важнее сна: человек здесь, просто не трогает клавиатуру.
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: true, event: nil, isInCall: true) == .onCall)
        // Советы подождут: белые глаза посреди звонка ни к чему.
        #expect(MascotBrain.state(isExpanded: false, mood: nil, isResting: false, event: nil, hasNewTips: true, isInCall: true) == .onCall)
        // Раскрыл чёлку сам — значит, смотрит: показываем дела как обычно.
        #expect(MascotBrain.state(isExpanded: true, mood: .growing, isResting: false, event: nil, isInCall: true) == .happy)
    }

    @Test func resourceAlertWorriesButStaysQuietOnCalls() {
        // Приложение ест больше обычного — чёлка беспокоится и свёрнутой.
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: false, event: nil, hasResourceAlert: true) == .worried)
        // На звонке молчит: притихшее лицо, а не тревога.
        #expect(MascotBrain.state(isExpanded: false, mood: .growing, isResting: false, event: nil, isInCall: true, hasResourceAlert: true) == .onCall)
        // Никого нет — спит; тревога подождёт.
        #expect(MascotBrain.state(isExpanded: false, mood: nil, isResting: true, event: nil, hasResourceAlert: true) == .sleep)
        // Раскрыта: облачко говорит о тревоге — лицо под стать, даже если готовы советы.
        #expect(MascotBrain.state(isExpanded: true, mood: .growing, isResting: false, event: nil, hasNewTips: true, hasResourceAlert: true) == .worried)
        // Поймать монетку — всё равно радость.
        #expect(MascotBrain.state(isExpanded: true, mood: .growing, isResting: false, event: .incomeAdded, hasResourceAlert: true) == .catchCoin)
    }

    @Test func antennaFollowsMood() {
        #expect(Mood.growing.antenna == .green)
        #expect(Mood.stable.antenna == .blue)
        #expect(Mood.declining.antenna == .yellow)
        #expect(Mood.losing(streak: 3).antenna == .orange)
        #expect(Mood.sleeping.antenna == .dim)
    }

    @Test func worstMoodWins() {
        #expect(Mood.worst([.growing, .stable]) == .stable)
        #expect(Mood.worst([.sleeping, .growing]) == .growing)
        #expect(Mood.worst([.sleeping]) == .sleeping)
        #expect(Mood.worst([]) == nil)
        #expect(Mood.worst([.declining, .losing(streak: 1)]) == .losing(streak: 1))
    }
}
