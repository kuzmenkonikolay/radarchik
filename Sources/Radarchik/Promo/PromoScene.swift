import SwiftUI
import RadarchikCore

// Ролик для X и Contra (2026-10-19, главы «Защиты» 2026-10-24): Радарчик рисует его
// сам, из настоящих экранов на выдуманных данных (английский `PreviewWorld` с «Защитой»).
// Кадр — функция времени: `PromoTimeline.pose(at:)` говорит, что где, `PromoFrame` рисует.
//
// Сюжет, ~41 с: голая чёлка → просыпается → крылья с итогом месяца и маком →
// наведение раскрывает главную → тревога «Arc ест 4,1 ГБ» → замок открытого ключа
// в крыле → скрипт из npm пошёл на голый адрес → «Что это?» спрашивает Claude →
// «Убить» → советы Claude → заставка со ссылкой на GitHub. Денег и оплаты в алертах
// нет (2026-10-24, пользователь).

/// Формат кадра: широкий — для X и Contra, квадратный — для ленты с телефона.
enum PromoFormat: String {
    case wide
    case square

    var size: CGSize {
        switch self {
        case .wide: CGSize(width: 1_920, height: 1_080)
        case .square: CGSize(width: 1_080, height: 1_080)
        }
    }

    /// Во сколько раз крупнее экран мака, пока камера отъехала: весь по ширине.
    var baseScale: CGFloat { size.width / PromoWorld.screen.width }

    /// Приближение у свёрнутой чёлки и у раскрытой панели (к `baseScale`).
    /// Панель дизайна v2 широкая (860), поэтому к ней камера почти не приближается.
    var closeZoom: Double { self == .wide ? 2.2 : 2.6 }
    /// Ещё ближе, пока Радарчик просыпается: полоска без цифр, лицо крупно.
    var wakeZoom: Double { self == .wide ? 3.0 : 4.0 }
    var panelZoom: Double { self == .wide ? 1.0 : 1.45 }
    /// У алерта: самый высокий (с ответом Claude) и подпись под ним влезают в кадр.
    var alertZoom: Double { self == .wide ? 1.35 : 2.1 }
    /// Сдвиг чёлки вправо, пока панель раскрыта: слева место для подписи.
    var panelPan: Double { self == .wide ? 340 : 0 }
}

/// Алерт, который выезжает из чёлки.
enum PromoAlert: Hashable {
    /// Arc ест 4,1 ГБ — втрое больше обычного.
    case resource
    /// node -e из Cursor (ролик-стинг).
    case process
    /// Скрипт из npm сразу после установки пошёл на голый адрес (сетевой надзор).
    case network
}

/// «Что это?» в алерте: не спрашивали, Claude думает (шаг 1…3), ответил.
enum PromoExplain: Hashable {
    case none
    case thinking(Int)
    case answer
}

/// Что нарисовано в раскрытой чёлке: экран (nil — главная) или алерт.
enum PromoShown: Hashable {
    case screen(Route?)
    case alert(PromoAlert, PromoExplain)
}

/// Мир ролика: английские выдуманные данные и размеры экранов, измеренные один раз.
@MainActor
final class PromoWorld {
    /// Экран 14-дюймового MacBook Pro в точках и чёлка того же размера, что в листе экранов.
    nonisolated static let screen = CGSize(width: 1_512, height: 982)
    let notch = CGSize(width: 220, height: 38)

    let preview: PreviewWorld
    /// Размеры видов панели и лицо, которое каждый просит (`faceSlot`), — меряются
    /// один раз: лицо и высота перетекают из прошлого вида алерта в новый.
    private var sizes: [PromoShown: CGSize] = [:]
    private var faces: [PromoShown: FaceSpec] = [:]
    /// Ширина свёрнутой полоски по тому, насколько выдвинут замок (0…1 шагом 1/20):
    /// стороны раскладки равны большей, поэтому полоска растёт не линейно — мерим.
    private var barWidths: [CGFloat] = []
    /// Что сейчас открыто в модели.
    private var current: PromoShown?

    /// `withGuard` — включить «Защиту»: кнопки Guard и сети в тулбаре.
    init(withGuard: Bool = false) throws {
        preview = try PreviewWorld(language: .en, withGuard: withGuard)
        barWidths = (0...20).map { step in
            var pose = Self.fullBar
            pose.lock = Double(step) / 20
            return Self.measure(PromoBar(pose: pose, notch: notch)).size.width
        }
        let explains: [PromoExplain] = [.none, .thinking(1), .thinking(2), .thinking(3), .answer]
        let all: [PromoShown] = [.screen(nil), .screen(.tips), .screen(.project(preview.mainProject.id)), .alert(.resource, .none), .alert(.process, .none)]
            + explains.map { .alert(.network, $0) }
        for shown in all {
            show(shown)
            (sizes[shown], faces[shown]) = Self.measure(panel())
        }
        show(.screen(nil))
    }

    /// Полоска с самыми широкими цифрами и замком — чтобы она не дёргалась.
    private static var fullBar: PromoPose {
        var pose = PromoPose()
        pose.money = 888_800
        pose.cpu = 88
        pose.temperature = 88
        pose.guardWing = "ssh 8:88"
        pose.signal = .tipsReady
        return pose
    }

    /// Открыть нужный вид в модели — до того, как кадр начнут рисовать:
    /// менять состояние посреди отрисовки SwiftUI не любит.
    func show(_ shown: PromoShown) {
        guard shown != current else { return }
        current = shown
        preview.showCalm()
        for key in ["resource:1", "guard:900", "guard:920"] { preview.review.explain.reset(key) }
        switch shown {
        case .screen(let route):
            // Экран советов, нарисовавшись, отмечает их прочитанными (`onAppear`),
            // а на главной они должны быть «готовы» — с бейджем.
            if route != .tips { preview.settings.tipsSeenAt = nil }
            open(route)
        case .alert(let alert, let explain):
            let route: PanelAlert
            let key: String
            switch alert {
            case .resource:
                let resources = preview.resources
                resources.preview(ResourceState(
                    system: resources.system, apps: resources.apps, history: resources.history,
                    alerts: [arcAlert()], normsCount: 0
                ))
                (route, key) = (.resource(1), "resource:1")
            case .process:
                preview.showGuardAlert()
                (route, key) = (.guardEvent(preview.guardEvent(900)), "guard:900")
            case .network:
                preview.showNetworkAlarm()
                (route, key) = (.guardEvent(preview.guardEvent(920)), "guard:920")
            }
            switch explain {
            case .none: break
            case .thinking(let step): preview.review.explain.preview(key, .thinking(step: step))
            case .answer: preview.review.explain.preview(key, .answer(alert == .resource ? preview.explainedResource : preview.explainedNetwork))
            }
            open(.alert(route))
        }
    }

    private func open(_ route: Route?) {
        let model = preview.model
        model.collapse(animated: false)
        model.expand(animated: false)
        if let route { model.push(route) }
    }

    /// Тревога про Arc. «Держится 3 мин» считается от сейчас, поэтому собирается
    /// в момент показа: рендер идёт минутами, и цифра бы поползла.
    private func arcAlert() -> ResourceAlert {
        let gib = 1_073_741_824.0
        let now = Date()
        return ResourceAlert(
            id: 1, kind: .memory, app: AppIdentity(key: "company.thebrowser.Browser", name: "Arc"),
            value: 4.1 * gib, usual: 1.37 * gib, startedAt: now.addingTimeInterval(-180), createdAt: now,
            title: ResourcePhrase.memory(app: "Arc", bytes: 4.1 * gib, usual: 1.37 * gib, totalBytes: 48 * gib), detail: nil,
            status: .active, statusChangedAt: nil
        )
    }

    /// Содержимое раскрытой панели — как его кладёт `NotchRootView`. Вид
    /// в модели должен быть уже открыт (`show`).
    func panel() -> some View {
        ExpandedView(
            model: preview.model, store: preview.store, settings: preview.settings, tracker: preview.tracker, review: preview.review,
            resources: preview.resources, protection: preview.protection
        )
        .frame(width: preview.model.panelWidth)
    }

    /// Свечение раскрытой панели — по правилам приложения (`PanelGlow.of`), растёт с раскрытием.
    func glow(_ progress: Double) -> PanelGlow {
        let model = preview.model
        let look = FaceDirector.look(
            model: model, store: preview.store, review: preview.review, tracker: preview.tracker,
            resources: preview.resources, protection: preview.protection
        )
        var glow = PanelGlow.of(model.route, look: look, store: preview.store, isOpen: true)
        glow.alpha *= Ease.clamp01(progress)
        return glow
    }

    func size(of shown: PromoShown) -> CGSize {
        sizes[shown] ?? sizes[.screen(nil)] ?? CGSize(width: DS.Panel.home, height: 300)
    }

    func face(of shown: PromoShown) -> FaceSpec? { faces[shown] }

    /// Ширина свёрнутой полоски: лицо, замок (насколько выдвинут), итог месяца, система и бейдж.
    func barWidth(lock: Double) -> CGFloat {
        guard barWidths.count == 21 else { return DS.Size.collapsedWidth }
        let x = Ease.clamp01(lock) * 20
        let step = min(Int(x), 19)
        return lerp(barWidths[step], barWidths[step + 1], x - Double(step))
    }

    /// Лицо в свёрнутой полоске — как в `CollapsedBar`: 34 pt слева.
    var barFaceCenter: CGPoint { CGPoint(x: 10 + DS.Size.collapsedHeight / 2, y: (notch.height + 2) / 2) }

    /// Размер вида и лицо, которое он просит под своё место.
    private static func measure(_ view: some View) -> (size: CGSize, face: FaceSpec?) {
        let probe = FaceProbe()
        let content = view
            .overlayPreferenceValue(FaceSlotKey.self) { slot in
                let _ = probe.keep(slot?.spec)
                Color.clear
            }
            .environment(\.colorScheme, .dark)
            .environment(\.unrollsScrolling, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return (.zero, nil) }
        return (CGSize(width: image.width, height: image.height), probe.spec)
    }
}

/// Запоминает лицо, которое попросил экран, пока его меряют.
@MainActor
private final class FaceProbe {
    private(set) var spec: FaceSpec?

    func keep(_ spec: FaceSpec?) {
        self.spec = spec
    }
}

/// Что в кадре в момент `t`.
struct PromoPose {
    /// Голая чёлка выросла в полоску 300 pt с лицом слева (цифр ещё нет), 0…1.
    var chin = 0.0
    /// Крылья раздвинулись, 0…1.
    var wings = 0.0
    /// Панель раздалась вширь — первый шаг раскрытия, как в приложении (`NotchViewModel.stage`).
    var widen = 0.0
    /// Панель опустилась (пружина, может чуть перелететь 1).
    var expand = 0.0
    var chartReveal = 1.0
    /// Алерт под чёлкой, 0…1 (пружина).
    var announce = 0.0
    /// Какой алерт и что с «Что это?».
    var alert = PromoAlert.resource
    var explain = PromoExplain.none
    /// Прошлый вид алерта и насколько от него ушли (0…1, пружина): лицо и высота перетекают.
    var previous: PromoShown?
    var morph = 1.0
    var money: Int64 = 292_300
    var cpu = 16.0
    var temperature = 54.0
    /// Открытый через «Защиту» ключ в крыле («ssh 4:12»); nil — замка нет.
    var guardWing: String?
    /// Насколько замок выдвинулся в крыло, 0…1.
    var lock = 0.0
    /// Экран панели: nil — главная.
    var route: Route?

    /// Что показывать панели в этот момент: тревога раскрывается алертом.
    var shown: PromoShown { announce > 0.001 ? .alert(alert, explain) : .screen(route) }

    var faceOpacity = 0.0
    var lids = 0.0
    var state = MascotState.idleScan
    var signal = AntennaSignal.green
    var gaze = CGPoint.zero

    /// Кончик курсора в точках экрана; nil — курсора нет.
    var cursor: CGPoint?
    /// Нажатие, 0…1: стрелка чуть сжимается.
    var press = 0.0

    var zoom = 1.0
    var pan = 0.0
    /// Заставка в конце, 0…1.
    var outro = 0.0
}

/// Подпись поверх кадра: заголовок и строка пояснения.
struct PromoCaption {
    enum Placement { case bottom, left }

    let start: Double
    let end: Double
    let title: String
    let subtitle: String
    var placement = Placement.bottom
}

enum PromoTimeline {
    static let duration = 41.0

    static let captions = [
        PromoCaption(start: 0.5, end: 2.4, title: "Your MacBook notch.", subtitle: "It just sits there."),
        PromoCaption(start: 3.1, end: 5.3, title: "Meet Radarchik.", subtitle: "A tiny face that lives in the notch."),
        PromoCaption(start: 5.8, end: 9.4, title: "Your month and your Mac.", subtitle: "The net of all your projects on the left, CPU and temperature on the right."),
        PromoCaption(start: 11.1, end: 14.2, title: "Hover for the full picture.", subtitle: "The month’s net, a line from Radarchik, every project one click away.", placement: .left),
        PromoCaption(start: 15.5, end: 19.0, title: "It watches your Mac.", subtitle: "And speaks up when an app eats more than usual."),
        PromoCaption(start: 19.9, end: 23.3, title: "It guards your keys.", subtitle: "SSH, AWS and project keys stay locked. Touch ID opens them, a timer locks them again."),
        PromoCaption(start: 23.9, end: 27.2, title: "It sees where scripts go.", subtitle: "npm scripts and Claude Code commands reaching new addresses — with who launched them."),
        PromoCaption(start: 27.6, end: 31.7, title: "Not sure what it is? Ask Claude.", subtitle: "It reads the path, signature and launch chain, and says what to do."),
        PromoCaption(start: 33.9, end: 36.6, title: "Daily tips from Claude.", subtitle: "It reviews your routine and suggests what to automate.", placement: .left),
    ]

    /// Звуки приложения (`SoundPlayer`) в те секунды, когда выезжает алерт: у ресурсов —
    /// предупреждение, у опасного от «Защиты» — сигнал (`PanelAlert.sound`).
    static let sounds: [(time: Double, kind: SoundKind)] = [(15.8, .warning), (23.6, .alarm)]

    static let repository = "github.com/kuzmenkonikolay/radarchik"

    /// Центр выреза по горизонтали на экране мака.
    private static var notchX: CGFloat { PromoWorld.screen.width / 2 }

    /// Где кнопки алерта сети, от центра выреза и от верха экрана, в точках: «Что это?»
    /// до вопроса и «Убить» после ответа (ответ сдвигает кнопки вниз).
    private static let askButton = CGPoint(x: 150, y: 244)
    private static let killButton = CGPoint(x: -88, y: 378)

    static func pose(at t: Double, format: PromoFormat) -> PromoPose {
        var pose = PromoPose()

        // 1–2. Голая чёлка просыпается: вырастает в полоску, открываются глаза, оглядывается.
        pose.chin = Ease.spring(t - 2.4, response: 0.5, damping: 1)
        pose.faceOpacity = Ease.smooth(Ease.progress(t, 2.7, 3.1))
        pose.lids = 1 - Ease.out(Ease.progress(t, 2.8, 3.3))
        pose.lids = max(pose.lids, blink(t, at: [5.0, 9.0, 16.9, 21.7, 34.9, 39.6]))
        let glance = Keyframes<CGPoint>(keys: [
            (3.5, .zero), (3.9, CGPoint(x: -1, y: 0.35)), (4.3, CGPoint(x: -1, y: 0.35)),
            (4.7, CGPoint(x: 1, y: 0.35)), (5.1, CGPoint(x: 1, y: 0.35)), (5.5, .zero),
        ], mix: lerp)
        pose.gaze = glance.value(at: t)

        // 3. Крылья: слева итог месяца, справа процессор и температура; глаза косятся на оба.
        pose.wings = Ease.spring(t - 5.4, response: 0.45, damping: 1)
        if (6.2..<8.8).contains(t) {
            pose.gaze = Keyframes<CGPoint>(keys: [
                (6.2, .zero), (6.5, CGPoint(x: -1, y: 0.2)), (7.2, CGPoint(x: -1, y: 0.2)),
                (7.6, CGPoint(x: 1, y: 0.2)), (8.4, CGPoint(x: 1, y: 0.2)), (8.8, .zero),
            ], mix: lerp).value(at: t)
        }

        // 4. Курсор наводит — чёлка расходится вширь и опускается в главную.
        (pose.widen, pose.expand) = panelSteps(t, open: 10.55, close: 14.3)
        if (10.55..<14.3).contains(t) { pose.state = .happy }

        // 5. Мак: процессор и температура лезут вверх, выезжает алерт про Arc.
        pose.cpu = lerp(16, 74, Ease.inOut(Ease.progress(t, 14.9, 15.7)))
        pose.temperature = lerp(54, 71, Ease.inOut(Ease.progress(t, 15.0, 16.0)))
        if t > 19.2 {
            pose.cpu = lerp(74, 18, Ease.inOut(Ease.progress(t, 19.2, 20.0)))
            pose.temperature = lerp(71, 56, Ease.inOut(Ease.progress(t, 19.2, 20.4)))
        }
        pose.announce = Ease.there(andBack: t, start: 15.8, end: 19.1, response: 0.38, damping: 1, backDamping: 1)
        if (15.6..<19.2).contains(t) {
            pose.state = .worried
            pose.gaze = CGPoint(x: 0, y: 0.6)
        }

        // 6. «Защита»: ssh открыт по Touch ID — в крыле выдвигается замок с отсчётом.
        if t >= 19.6 {
            let left = 252 - Int(t - 19.6)
            pose.guardWing = String(format: "ssh %d:%02d", left / 60, left % 60)
            pose.lock = Ease.spring(t - 19.6, response: 0.45, damping: 1)
        }
        if (20.0..<22.8).contains(t) {
            pose.gaze = Keyframes<CGPoint>(keys: [
                (20.0, .zero), (20.3, CGPoint(x: -1, y: 0.25)), (22.4, CGPoint(x: -1, y: 0.25)), (22.8, .zero),
            ], mix: lerp).value(at: t)
        }

        // 7. Скрипт из npm пошёл на голый адрес: глаза краснеют, выезжает алерт сети.
        // Курсор жмёт «Что это?» — Claude думает три шага и отвечает; потом «Убить».
        if t >= 23.0 {
            pose.alert = .network
            pose.announce = Ease.there(andBack: t, start: 23.6, end: 31.65, response: 0.38, damping: 1, backDamping: 1)
            let steps: [(time: Double, from: PromoExplain, to: PromoExplain)] = [
                (27.25, .none, .thinking(1)), (27.75, .thinking(1), .thinking(2)),
                (29.2, .thinking(2), .thinking(3)), (29.6, .thinking(3), .answer),
            ]
            if let step = steps.last(where: { t >= $0.time }) {
                pose.explain = step.to
                pose.previous = .alert(.network, step.from)
                pose.morph = Ease.spring(t - step.time, response: 0.38, damping: 0.78)
            }
        }
        if (23.4..<31.7).contains(t) {
            pose.state = .alarm
            pose.gaze = CGPoint(x: 0, y: 0.6)
        }

        // 8. Советы готовы — глаза белеют; курсор открывает «Советы дня».
        if t >= 32.4 && t < 36.9 { pose.signal = .tipsReady }
        if t >= 33.4 {
            (pose.widen, pose.expand) = panelSteps(t, open: 33.4, close: 36.55)
            pose.route = .tips
            if t < 36.55 { pose.state = .tipWave }
        }

        // 9. Заставка: камера отъезжает, Радарчик доволен.
        if t >= 36.9 { pose.state = .happy }
        pose.outro = Ease.smooth(Ease.progress(t, 37.5, 38.3))

        // За курсором глаза следят только из свёрнутой чёлки; в раскрытой панели
        // смотрят прямо, как в приложении (2026-10-20).
        pose.cursor = cursor(at: t)
        pose.press = blink(t, at: [27.05, 31.45])
        if let cursor = pose.cursor, t > 9.9, pose.expand <= 0.001, pose.announce <= 0.001 {
            pose.gaze = gaze(towards: cursor, pose: pose)
        }

        // Камера: общий план → к чёлке → отъезд под панель → к алертам и замку → общий план.
        let (close, panel, alert, pan) = (format.closeZoom, format.panelZoom, format.alertZoom, format.panelPan)
        let camera = Keyframes<(Double, Double)>(keys: [
            (0, (1.0, 0)), (2.2, (1.04, 0)), (3.6, (format.wakeZoom, 0)), (5.0, (format.wakeZoom, 0)), (6.0, (close, 0)), (9.7, (close + 0.08, 0)),
            (10.7, (panel, pan)), (14.2, (panel, pan)),
            (15.3, (alert, 0)), (19.2, (alert, 0)),
            (20.0, (close, 0)), (23.0, (close + 0.06, 0)),
            (23.9, (alert, 0)), (31.6, (alert, 0)),
            (32.5, (close, 0)), (32.75, (close, 0)),
            (33.65, (panel, pan)), (36.4, (panel, pan)),
            (38.0, (1.0, 0)),
        ], mix: { a, b, x in (lerp(a.0, b.0, x), lerp(a.1, b.1, x)) })
        (pose.zoom, pose.pan) = camera.value(at: t)
        return pose
    }

    /// Раскрытие панели — одной пружиной для ширины, высоты и радиуса, как в
    /// приложении (`DS.spring`: response 0.38, damping 0.78). Ширина и высота идут
    /// вместе: `widen` равен `drop`.
    static func panelSteps(_ t: Double, open: Double, close: Double) -> (widen: Double, drop: Double) {
        let value: Double
        if t < close {
            value = Ease.spring(t - open, response: 0.38, damping: 0.78)
        } else {
            value = Ease.spring(close - open, response: 0.38, damping: 0.78) * (1 - Ease.spring(t - close, response: 0.38, damping: 0.78))
        }
        return (value, value)
    }

    /// Моргание: веки опускаются и поднимаются за четверть секунды.
    static func blink(_ t: Double, at moments: [Double]) -> Double {
        moments.map { moment in
            let x = (t - moment) / 0.24
            return x > 0 && x < 1 ? sin(x * .pi) : 0
        }.max() ?? 0
    }

    /// Курсор: наводит на чёлку и гуляет по главной; жмёт кнопки алерта сети; открывает советы.
    private static func cursor(at t: Double) -> CGPoint? {
        let x = notchX
        if (9.4..<14.8).contains(t) {
            return Keyframes<CGPoint>(keys: [
                (9.4, CGPoint(x: x + 560, y: 420)), (10.5, CGPoint(x: x + 26, y: 24)),
                (11.6, CGPoint(x: x + 40, y: 36)), (12.4, CGPoint(x: x - 130, y: 236)), (13.2, CGPoint(x: x + 120, y: 240)),
                (13.8, CGPoint(x: x + 60, y: 318)), (14.7, CGPoint(x: x + 560, y: 600)),
            ], mix: lerp).value(at: t)
        }
        if (26.2..<32.4).contains(t) {
            let ask = CGPoint(x: x + askButton.x, y: askButton.y)
            let kill = CGPoint(x: x + killButton.x, y: killButton.y)
            return Keyframes<CGPoint>(keys: [
                // Пока Claude думает, курсор отходит за правый край алерта — не загораживает шаги.
                (26.2, CGPoint(x: x + 560, y: 560)), (27.0, ask), (27.5, ask), (28.3, CGPoint(x: x + 380, y: 280)),
                (30.4, CGPoint(x: x + 380, y: 280)), (31.3, kill), (31.65, kill), (32.4, CGPoint(x: x + 560, y: 640)),
            ], mix: lerp).value(at: t)
        }
        if (32.45..<36.9).contains(t) {
            return Keyframes<CGPoint>(keys: [
                (32.45, CGPoint(x: x + 600, y: 380)), (33.35, CGPoint(x: x + 20, y: 22)),
                (34.35, CGPoint(x: x + 50, y: 120)), (35.25, CGPoint(x: x + 140, y: 218)),
                (35.95, CGPoint(x: x + 150, y: 222)), (36.8, CGPoint(x: x + 600, y: 620)),
            ], mix: lerp).value(at: t)
        }
        return nil
    }

    /// Взгляд на курсор — как `NotchController.updateGaze`: −1…1 по осям.
    private static func gaze(towards cursor: CGPoint, pose: PromoPose) -> CGPoint {
        let eyeY: CGFloat = 38 + 30
        let dx = (cursor.x - notchX) / 160
        let dy = (cursor.y - eyeY) / 140
        return CGPoint(x: min(max(dx, -1), 1), y: min(max(dy, -1), 1))
    }
}

// MARK: - Кадр

struct PromoFrame: View {
    let t: Double
    let world: PromoWorld
    let format: PromoFormat

    var body: some View {
        let pose = PromoTimeline.pose(at: t, format: format)
        let size = format.size
        ZStack(alignment: .top) {
            // Обои стоят на месте и закрывают весь кадр: камера двигает только экран.
            PromoWallpaper(size: size)

            PromoScreen(pose: pose, world: world)
                .frame(width: PromoWorld.screen.width, height: PromoWorld.screen.height, alignment: .top)
                .scaleEffect(format.baseScale * pose.zoom, anchor: .top)
                .offset(x: pose.pan)
                .frame(width: size.width, height: size.height, alignment: .top)

            ForEach(Array(PromoTimeline.captions.enumerated()), id: \.offset) { _, caption in
                PromoCaptionView(caption: caption, t: t, format: format)
            }

            PromoOutro(progress: pose.outro, format: format)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.unrollsScrolling, true)
    }
}

/// Верх экрана мака: чёлка и курсор. Строки меню нет — в ролике только то, что
/// рисует сам Радарчик (2026-10-20).
private struct PromoScreen: View {
    let pose: PromoPose
    let world: PromoWorld

    var body: some View {
        ZStack(alignment: .top) {
            PromoNotchView(pose: pose, world: world)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            if let cursor = pose.cursor {
                PromoCursor(press: pose.press).offset(x: cursor.x, y: cursor.y)
            }
        }
    }
}

/// Чёлка в любом промежуточном виде: голая, полоска с лицом и цифрами, раскрытая
/// панель или алерт. Фигура и лицо перетекают, как в приложении (дизайн v2).
struct PromoNotchView: View {
    let pose: PromoPose
    let world: PromoWorld

    var body: some View {
        let notch = world.notch
        // Голая чёлка → полоска без цифр → с цифрами (и замком). Ширины — без ушей фигуры (2 × 6).
        let barHeight = lerp(notch.height, notch.height + 2, pose.chin)
        let plainWidth = lerp(notch.width - 12, DS.Size.collapsedWidth, pose.chin)
        let barWidth = lerp(plainWidth, world.barWidth(lock: pose.guardWing == nil ? 0 : pose.lock), pose.wings)
        let isPanel = pose.widen > 0.001 || pose.expand > 0.001 || pose.announce > 0.001
        let p = Ease.clamp01(isPanel ? max(pose.expand, pose.announce) : 0)
        let full = panelSize
        let width = lerp(barWidth, full.width, Ease.clamp01(max(pose.widen, p)))
        let height = lerp(barHeight, full.height, p)
        let top: CGFloat = lerp(CGFloat(6), CGFloat(10), p)
        let shape = PanelShape(topRadius: top, bottomRadius: lerp(DS.Radius.collapsed, DS.Radius.panel, p))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(0.5 * p), radius: 70, y: 30)
            PanelBackground(shape: shape, glow: isPanel ? world.glow(p) : .none)
            ZStack(alignment: .top) {
                if isPanel {
                    world.panel()
                        .environment(\.chartReveal, pose.chartReveal)
                        .scaleEffect(lerp(0.96, 1, p), anchor: .top)
                        .opacity(Ease.smooth(Ease.progress(p, 0.3, 0.85)))
                }
                // Цифры гаснут в первую четверть раскрытия и проявляются в последнюю четверть
                // сворачивания: между полоской и панелью не остаётся пустой чёрной фигуры.
                PromoBar(pose: pose, notch: notch)
                    .opacity(Ease.smooth(Ease.progress(pose.wings, 0.2, 0.9)) * (1 - Ease.smooth(Ease.progress(p, 0, 0.25))))
            }
            .padding(.horizontal, top)
            .overlayPreferenceValue(FaceSlotKey.self) { slot in
                GeometryReader { proxy in
                    // Содержимое шире фигуры (полоска с цифрами, пока крылья не раскрылись) стоит
                    // по центру: лицу полоски нужен левый край фигуры, а не содержимого.
                    let shift = (proxy.size.width - (width + 2 * top)) / 2
                    let bar = barRect(top: top).offsetBy(dx: shift, dy: 0)
                    let rect = isPanel ? lerpRect(bar, slot.map { proxy[$0.anchor] } ?? bar, p) : bar
                    FaceCanvas(geometry: faceGeometry(panel: isPanel ? slot?.spec : nil, progress: p), blink: pose.lids, look: pose.gaze)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(pose.faceOpacity)
                }
            }
        }
        .frame(width: width + 2 * top, height: height, alignment: .top)
        .clipShape(shape)
    }

    /// Размер панели: от прошлого вида алерта к нынешнему (ответ Claude её вытягивает).
    private var panelSize: CGSize {
        let size = world.size(of: pose.shown)
        guard let previous = pose.previous else { return size }
        return lerp(world.size(of: previous), size, pose.morph)
    }

    /// Лицо 34 слева в полоске.
    private func barRect(top: CGFloat) -> CGRect {
        let center = world.barFaceCenter
        let size = faceSize(DS.Size.collapsedHeight)
        return CGRect(x: top + center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func lerpRect(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    /// Лицо: в полоске — по позе ролика, в панели — то, что просит экран (`faceSlot`),
    /// как в приложении. Из полоски в панель и из прошлого вида алерта — перетекает.
    private func faceGeometry(panel spec: FaceSpec?, progress: Double) -> FaceGeometry {
        let bar = FaceGeometry(barFace)
        guard let spec else { return bar }
        var panel = FaceGeometry(spec)
        if let previous = pose.previous.flatMap(world.face(of:)) {
            panel = .mix(FaceGeometry(previous), panel, pose.morph)
        }
        return .mix(bar, panel, progress)
    }

    /// Лицо в полоске: эмоция из состояния, цвет из сигнала.
    private var barFace: FaceSpec {
        let tone: Color = switch pose.state {
        case .alarm: DS.Tone.alarm
        case .sleep: DS.Tone.dim
        case .worried: DS.Tone.tips
        case .catchCoin, .happy: DS.Tone.plus
        default: DS.tone(pose.signal)
        }
        return .main(pose.state.emotion, tone: tone, hands: pose.state.hands, glasses: pose.state.wearsGlasses)
    }
}

private extension FaceGeometry {
    /// Лицо между двумя: все числа модели — по прямой.
    static func mix(_ a: FaceGeometry, _ b: FaceGeometry, _ t: Double) -> FaceGeometry {
        let t = Ease.clamp01(t)
        return FaceGeometry(vector: zip(a.vector, b.vector).map { lerp($0, $1, t) })
    }
}

/// Свёрнутая полоска ролика: место под лицо, замок открытого ключа, итог месяца,
/// процессор, температура, бейдж.
struct PromoBar: View {
    let pose: PromoPose
    let notch: CGSize

    var body: some View {
        // Та же симметричная раскладка, что у настоящей полоски (`CollapsedBar`).
        NotchBarLayout(gap: notch.width + 24, minWidth: DS.Size.collapsedWidth - 20) {
            HStack(spacing: 8) {
                Color.clear.frame(width: DS.Size.collapsedHeight, height: DS.Size.collapsedHeight * 2 / 3)
                HStack(spacing: 0) {
                    if let wing = pose.guardWing {
                        Reveal(fraction: pose.lock) {
                            WingItemView(item: WingItem(id: "guard", icon: "lock.open.fill", text: wing, color: DS.Tone.tips, iconColor: DS.Tone.tips, widest: "ssh 8:88"))
                                .padding(.trailing, 8)
                        }
                        .clipped()
                        .opacity(pose.lock)
                    }
                    WingItemView(item: WingItem(id: "month", icon: nil, text: MoneyFormat.compact(pose.money, .usd, signed: true), color: DS.Money.text(for: pose.money), widest: "+$8.8k"))
                }
            }
            HStack(spacing: 8) {
                WingItemView(item: WingItem(id: "cpu", icon: "cpu", text: ResourceFormat.percent(pose.cpu), widest: "88%"))
                WingItemView(item: WingItem(id: "temperature", icon: "thermometer.medium", text: ResourceFormat.temperature(pose.temperature), widest: "88°"))
                if pose.signal == .tipsReady { CountBadge(count: 2) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: notch.height + 2)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Выдвигает содержимое слева направо: ширина — доля настоящей, содержимое прижато вправо.
private struct Reveal: Layout {
    var fraction: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.width * Ease.clamp01(fraction), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        subview.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(size))
    }
}

/// Свои обои: тёмные, с мягкими пятнами цвета — экран не отвлекает от чёлки.
/// Пятна рассчитаны на экран мака шириной 1512 pt и растянуты на весь кадр.
private struct PromoWallpaper: View {
    let size: CGSize

    var body: some View {
        let k = max(size.width, size.height) / PromoWorld.screen.width
        ZStack {
            Color(hex: "#0B0D1A")
            RadialGradient(colors: [Color(hex: "#3A2B8C").opacity(0.9), .clear], center: UnitPoint(x: 0.16, y: 0.95), startRadius: 0, endRadius: 900 * k)
            RadialGradient(colors: [Color(hex: "#0F6B7A").opacity(0.75), .clear], center: UnitPoint(x: 0.92, y: 0.78), startRadius: 0, endRadius: 820 * k)
            RadialGradient(colors: [Color(hex: "#1F3C9E").opacity(0.5), .clear], center: UnitPoint(x: 0.55, y: 0.18), startRadius: 0, endRadius: 700 * k)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Стрелка курсора macOS: чёрная с белой обводкой и мягкой тенью; на нажатии сжимается.
private struct PromoCursor: View {
    var press = 0.0

    var body: some View {
        let arrow = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 0, y: 17.5))
            path.addLine(to: CGPoint(x: 4.3, y: 13.6))
            path.addLine(to: CGPoint(x: 7.1, y: 20.2))
            path.addLine(to: CGPoint(x: 9.9, y: 19))
            path.addLine(to: CGPoint(x: 7.1, y: 12.6))
            path.addLine(to: CGPoint(x: 12.6, y: 12.6))
            path.closeSubpath()
        }
        ZStack(alignment: .topLeading) {
            arrow.stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            arrow.fill(Color.black)
        }
        .frame(width: 14, height: 21, alignment: .topLeading)
        .scaleEffect(1 - 0.18 * press, anchor: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// Подпись: выплывает снизу и тает вверх. Снизу по центру или слева от панели.
private struct PromoCaptionView: View {
    let caption: PromoCaption
    let t: Double
    let format: PromoFormat

    var body: some View {
        let appear = Ease.out(Ease.progress(t, caption.start, caption.start + 0.5))
        let subAppear = Ease.out(Ease.progress(t, caption.start + 0.14, caption.start + 0.64))
        let leave = Ease.inOut(Ease.progress(t, caption.end - 0.35, caption.end))
        let isLeft = caption.placement == .left && format == .wide
        let size = format.size

        VStack(alignment: isLeft ? .leading : .center, spacing: 14) {
            Text(caption.title)
                .font(.system(size: format == .wide ? 66 : 60, weight: .bold))
                .foregroundStyle(Color.white)
                .opacity(appear)
                .offset(y: (1 - appear) * 28)
            Text(caption.subtitle)
                .font(.system(size: format == .wide ? 32 : 30, weight: .medium))
                .foregroundStyle(DS.Ink.secondary)
                .opacity(subAppear)
                .offset(y: (1 - subAppear) * 22)
        }
        .multilineTextAlignment(isLeft ? .leading : .center)
        .lineSpacing(4)
        .frame(width: isLeft ? 660 : size.width - 220, alignment: isLeft ? .leading : .center)
        .shadow(color: .black.opacity(0.55), radius: 18)
        .opacity(1 - leave)
        .offset(y: -leave * 14)
        .padding(.leading, isLeft ? 110 : 0)
        .padding(.bottom, isLeft ? 0 : 90)
        .frame(width: size.width, height: size.height, alignment: isLeft ? .leading : .bottom)
        .opacity(t >= caption.start && t <= caption.end ? 1 : 0)
    }
}

/// Заставка: иконка, название, что это и где взять.
private struct PromoOutro: View {
    let progress: Double
    let format: PromoFormat

    var body: some View {
        let size = format.size
        ZStack {
            Color.black.opacity(0.55 * progress)
            VStack(spacing: 18) {
                AppIconArt()
                    .scaleEffect(0.19)
                    .frame(width: 195, height: 195)
                Text("Radarchik")
                    .font(.system(size: format == .wide ? 118 : 104, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Ink.primary)
                Text("A tiny mascot that lives in your MacBook notch")
                    .font(.system(size: format == .wide ? 38 : 34, weight: .medium))
                    .foregroundStyle(DS.Ink.secondary)
                    .multilineTextAlignment(.center)
                Text("Open source · Native Swift · Your data stays on your Mac")
                    .font(.system(size: format == .wide ? 28 : 26))
                    .foregroundStyle(DS.Ink.muted)
                    .multilineTextAlignment(.center)
                Text(PromoTimeline.repository)
                    .font(.system(size: format == .wide ? 32 : 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Accent.on)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 60)
            .padding(.top, 120)
            .opacity(progress)
            .offset(y: (1 - progress) * 30)
        }
        .frame(width: size.width, height: size.height)
    }
}
