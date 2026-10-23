import AppKit
import SwiftUI
import RadarchikCore

/// Клипы для 22-секундного ролика-стинга в стиле keynote (`--render-sting-clips <папка>`,
/// 2026-10-20). Чёлка и панель живут как в приложении: те же `PromoPose` и
/// `PromoNotchView`, что в промо, но без обоев и камеры — прозрачный фон, 2x,
/// 59.94 кадра в секунду, по папке на клип. Камеру, склейки, подписи и звук
/// добавляет `launch/sting/sting.html`.
///
/// - `intro` — свёрнутая чёлка с крыльями, глаза следят за курсором;
/// - `money` — курсор наводит, панель раскрывается на деньгах, график растёт, глаза-монетки;
/// - `project` — экран проекта Notely;
/// - `alert` — процессор и температура лезут вверх, выезжает записка про Arc;
/// - `tips` — глаза белеют (советы готовы), панель раскрывается на советах;
/// - `guard` — в крыле жёлтый замок с отсчётом, потом красные глаза и тревога про node -e.
@MainActor
enum StingClips {
    static let fps = 60_000.0 / 1_001.0

    struct Clip {
        let name: String
        let duration: Double
        /// Высота холста в точках — по самому высокому состоянию клипа.
        let height: CGFloat
        let pose: (Double) -> PromoPose
    }

    static func render(to folder: URL) throws {
        Language.setAppWide(.en)
        let world = try PromoWorld(withGuard: true)
        for clip in clips(world: world) {
            let dir = folder.appendingPathComponent(clip.name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let count = Int((clip.duration * fps).rounded())
            for frame in 0..<count {
                try autoreleasepool {
                    let pose = clip.pose(Double(frame) / fps)
                    world.show(pose.shownRoute)
                    let renderer = ImageRenderer(content: StingFrame(pose: pose, world: world, height: clip.height))
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { throw PromoRenderer.Failure(description: "\(clip.name): frame \(frame) not rendered") }
                    try data.write(to: dir.appendingPathComponent(String(format: "%04d.png", frame)))
                }
            }
            print("\(clip.name): \(count) frames, \(Int(DS.Size.panelWidth * 2))×\(Int(clip.height * 2))")
        }
    }

    /// Свёрнутая чёлка с крыльями: итог месяца, процессор, температура — как на скриншотах.
    private static func collapsed() -> PromoPose {
        var pose = PromoPose()
        pose.chin = 1
        pose.wings = 1
        pose.faceOpacity = 1
        pose.money = 292_300
        pose.cpu = 16
        pose.temperature = 54
        return pose
    }

    private static func clips(world: PromoWorld) -> [Clip] {
        let project = Route.project(world.preview.mainProject.id)
        return [
            // S1: курсор появляется справа на 0.9 с и ныряет к иконке внизу слева.
            Clip(name: "intro", duration: 2.4, height: 110) { t in
                var pose = collapsed()
                pose.lids = PromoTimeline.blink(t, at: [0.7, 1.9])
                pose.gaze = Keyframes<CGPoint>(keys: [
                    (0.9, .zero), (1.2, CGPoint(x: 0.9, y: 0.8)), (1.6, CGPoint(x: 0.6, y: 0.9)), (2.0, CGPoint(x: 0.1, y: 1.0)),
                ], mix: lerp).value(at: t)
                return pose
            },
            // S3 + глава «Деньги»: курсор поднимается снизу, на 0.5 с наводит — панель
            // раскрывается по кривой приложения; на 2.05 с растёт график; на 3.35 с глаза-монетки.
            Clip(name: "money", duration: 4.84, height: 470) { t in
                var pose = collapsed()
                pose.gaze = Keyframes<CGPoint>(keys: [(0.03, CGPoint(x: 0.3, y: 1)), (0.3, CGPoint(x: 0.2, y: 0.7))], mix: lerp).value(at: t)
                (pose.widen, pose.expand) = PromoTimeline.panelSteps(t, open: 0.5, close: 99)
                pose.chartReveal = Ease.progress(t, 2.05, 3.2)
                if t >= 0.5 { pose.state = .happy; pose.gaze = .zero }
                if (3.35..<4.1).contains(t) { pose.state = .catchCoin }
                pose.lids = PromoTimeline.blink(t, at: [1.4, 4.5])
                return pose
            },
            // Глава «Деньги», второй экран: проект Notely целиком.
            Clip(name: "project", duration: 1.0, height: 790) { t in
                var pose = collapsed()
                pose.widen = 1
                pose.expand = 1
                pose.route = project
                pose.state = .happy
                pose.lids = PromoTimeline.blink(t, at: [0.5])
                return pose
            },
            // Глава «Мак»: процессор 16 → 74 %, температура 54 → 71°, Радарчик тревожится,
            // на 1.0 с выезжает записка «Arc is using 4.1 GB — 3× its usual».
            Clip(name: "alert", duration: 2.9, height: 170) { t in
                var pose = collapsed()
                pose.cpu = lerp(16, 74, Ease.inOut(Ease.progress(t, 0.15, 0.95)))
                pose.temperature = lerp(54, 71, Ease.inOut(Ease.progress(t, 0.25, 1.05)))
                pose.announce = Ease.spring(t - 1.0, response: 0.38, damping: 1)
                if t >= 0.9 { pose.state = .worried; pose.gaze = CGPoint(x: 0, y: 0.6) }
                return pose
            },
            // Глава «Советы»: глаза белеют — советы готовы; курсор наводит, панель
            // раскрывается на советах, Радарчик машет.
            Clip(name: "tips", duration: 2.9, height: 680) { t in
                var pose = collapsed()
                pose.signal = .tipsReady
                pose.gaze = Keyframes<CGPoint>(keys: [(0.03, CGPoint(x: 0.3, y: 1)), (0.3, CGPoint(x: 0.2, y: 0.7))], mix: lerp).value(at: t)
                (pose.widen, pose.expand) = PromoTimeline.panelSteps(t, open: 0.4, close: 99)
                pose.route = .tips
                if t >= 0.4 { pose.state = .tipWave; pose.gaze = .zero }
                pose.lids = PromoTimeline.blink(t, at: [2.0])
                return pose
            },
            // Глава «Защита»: ssh открыт, в крыле жёлтый замок с отсчётом; на 1.1 с глаза
            // краснеют, на 1.2 с выезжает тревога «node -e — started by Cursor».
            Clip(name: "guard", duration: 2.9, height: 170) { t in
                var pose = collapsed()
                let remaining = 252 - Int(t)
                pose.guardWing = String(format: "ssh %d:%02d", remaining / 60, remaining % 60)
                pose.alarm = true
                pose.announce = Ease.spring(t - 1.2, response: 0.38, damping: 1)
                if t >= 1.1 { pose.state = .alarm; pose.gaze = CGPoint(x: 0, y: 0.6) }
                pose.lids = PromoTimeline.blink(t, at: [0.6])
                return pose
            },
        ]
    }
}

/// Кадр клипа: чёлка сверху по центру на прозрачном холсте шириной с панель.
private struct StingFrame: View {
    let pose: PromoPose
    let world: PromoWorld
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            PromoNotchView(pose: pose, world: world)
        }
        .frame(width: DS.Size.panelWidth, height: height, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.unrollsScrolling, true)
    }
}
