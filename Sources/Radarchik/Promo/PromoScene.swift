import SwiftUI
import RadarchikCore

// Ролик для X и Contra (2026-10-19): Радарчик рисует его сам, из настоящих
// экранов на выдуманных данных (английский `PreviewWorld`). Кадр — функция
// времени: `PromoTimeline.pose(at:)` говорит, что где, `PromoFrame` рисует.
//
// Сюжет, ~28 с: голая чёлка → просыпается → крылья с итогом месяца, который
// растёт из минуса в плюс → наведение раскрывает сводку с графиком → тревога
// «Arc ест 4,1 ГБ» → советы Claude → заставка со ссылкой на GitHub.

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
    var closeZoom: Double { self == .wide ? 2.2 : 3.0 }
    var panelZoom: Double { self == .wide ? 1.0 : 1.45 }
    /// Сдвиг чёлки вправо, пока панель раскрыта: слева место для подписи.
    var panelPan: Double { self == .wide ? 340 : 0 }
}

/// Мир ролика: английские выдуманные данные и размеры экранов, измеренные один раз.
@MainActor
final class PromoWorld {
    /// Экран 14-дюймового MacBook Pro в точках и чёлка того же размера, что в листе экранов.
    nonisolated static let screen = CGSize(width: 1_512, height: 982)
    let notch = CGSize(width: 220, height: 38)

    let preview: PreviewWorld
    let alert: ResourceAlert
    /// Размеры экранов панели по маршруту — меряются один раз.
    private var sizes: [Route?: CGSize] = [:]
    /// Тревога «Защиты» для ролика: та же, что в листе экранов (`PreviewWorld.showGuardAlert`).
    let guardEvent: Int64 = 900

    /// `withGuard` — включить «Защиту»: кнопка Guard в тулбаре и замок в полоске (ролик-стинг).
    init(withGuard: Bool = false) throws {
        preview = try PreviewWorld(language: .en, withGuard: withGuard)
        let gib = 1_073_741_824.0
        let now = Date()
        alert = ResourceAlert(
            id: 1, kind: .memory, app: AppIdentity(key: "company.thebrowser.Browser", name: "Arc"),
            value: 4.1 * gib, usual: 1.37 * gib, startedAt: now.addingTimeInterval(-180), createdAt: now,
            title: ResourcePhrase.memory(app: "Arc", bytes: 4.1 * gib, usual: 1.37 * gib, totalBytes: 48 * gib), detail: nil,
            status: .active, statusChangedAt: nil
        )
        barSizes = [
            false: Self.measure(PromoBar(pose: Self.fullBar(guard: nil), notch: notch)),
            true: Self.measure(PromoBar(pose: Self.fullBar(guard: "ssh 8:88"), notch: notch)),
        ]
        for route in [nil, .tips, .project(preview.mainProject.id), .alert(.resource(alert.id))] as [Route?] {
            show(route)
            sizes[route] = Self.measure(panel())
        }
        show(nil)
    }

    /// Ширина свёрнутой полоски — под самые широкие цифры, чтобы она не дёргалась.
    private var barSizes: [Bool: CGSize] = [:]

    private static func fullBar(guard: String?) -> PromoPose {
        var pose = PromoPose()
        pose.money = 888_800
        pose.cpu = 88
        pose.temperature = 88
        pose.guardWing = `guard`
        pose.signal = .tipsReady
        return pose
    }

    /// Тревога про Arc активна только пока показывается её алерт: иначе она
    /// заняла бы место фразы на главной.
    private func setAlertActive(_ active: Bool) {
        let resources = preview.resources
        guard (resources.activeAlert != nil) != active else { return }
        resources.preview(ResourceState(
            system: resources.system, apps: resources.apps, history: resources.history,
            alerts: active ? [alert] : [], normsCount: 0
        ))
    }

    /// Открыть нужный экран в модели — до того, как кадр начнут рисовать:
    /// менять состояние посреди отрисовки SwiftUI не любит.
    func show(_ route: Route?) {
        // Экран советов, нарисовавшись, отмечает их прочитанными (`onAppear`),
        // а на главной они должны быть «готовы» — с бейджем.
        if route != .tips { preview.settings.tipsSeenAt = nil }
        setAlertActive(route == .alert(.resource(alert.id)))
        let model = preview.model
        guard model.route != route || !model.isExpanded else { return }
        model.collapse(animated: false)
        model.expand(animated: false)
        if let route { model.push(route) }
    }

    /// Содержимое раскрытой панели — как его кладёт `NotchRootView`. Экран
    /// в модели должен быть уже открыт (`show`).
    func panel() -> some View {
        ExpandedView(
            model: preview.model, store: preview.store, settings: preview.settings, tracker: preview.tracker, review: preview.review,
            resources: preview.resources, protection: preview.protection
        )
        .frame(width: preview.model.panelWidth)
    }

    func size(of route: Route?) -> CGSize {
        sizes[route] ?? sizes[nil] ?? CGSize(width: DS.Panel.home, height: 300)
    }

    /// Ширина свёрнутой полоски: лицо, итог месяца, система и бейдж.
    func barWidth(guard: Bool) -> CGFloat { barSizes[`guard`]?.width ?? DS.Size.collapsedWidth }

    /// Лицо в свёрнутой полоске — как в `CollapsedBar`: 34 pt слева.
    var barFaceCenter: CGPoint { CGPoint(x: 10 + DS.Size.collapsedHeight / 2, y: (notch.height + 2) / 2) }

    private static func measure(_ view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.unrollsScrolling, true))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }
}

/// Что в кадре в момент `t`.
struct PromoPose {
    /// Подбородок вырос из голой чёлки, 0…1.
    var chin = 0.0
    /// Крылья раздвинулись, 0…1.
    var wings = 0.0
    /// Панель раздалась вширь — первый шаг раскрытия, как в приложении (`NotchViewModel.stage`).
    var widen = 0.0
    /// Панель опустилась (пружина, может чуть перелететь 1).
    var expand = 0.0
    var chartReveal = 1.0
    /// Записка о тревоге под чёлкой.
    var announce = 0.0
    var money: Int64 = -102_700
    var cpu = 16.0
    var temperature = 54.0
    /// Открытый через «Защиту» ключ в крыле («ssh 4:12»); nil — замка нет.
    var guardWing: String?
    /// Записка — тревога «Защиты» (красный щит), а не о ресурсах.
    var alarm = false
    /// Экран панели: nil — главная.
    var route: Route?

    /// Что показывать панели в этот момент: тревога раскрывается алертом.
    var shownRoute: Route? { announce > 0.001 ? .alert(.resource(1)) : route }

    var faceOpacity = 0.0
    var lids = 0.0
    var state = MascotState.idleScan
    var signal = AntennaSignal.green
    var gaze = CGPoint.zero

    /// Кончик курсора в точках экрана; nil — курсора нет.
    var cursor: CGPoint?

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
    static let duration = 28.0

    static let captions = [
        PromoCaption(start: 0.5, end: 2.4, title: "Your MacBook notch.", subtitle: "It just sits there."),
        PromoCaption(start: 3.1, end: 5.3, title: "Meet Radarchik.", subtitle: "A tiny mascot that lives in the notch."),
        PromoCaption(start: 5.8, end: 9.5, title: "Your month at a glance.", subtitle: "Net of all your projects — red early in the month, green as income lands."),
        PromoCaption(start: 11.1, end: 14.2, title: "Hover for the full picture.", subtitle: "The month’s net, a line from Radarchik, every project one click away.", placement: .left),
        PromoCaption(start: 15.5, end: 19.0, title: "It watches your Mac.", subtitle: "And speaks up when an app eats more than usual."),
        PromoCaption(start: 20.9, end: 23.5, title: "Daily tips from Claude.", subtitle: "It reviews your routine and suggests what to automate.", placement: .left),
    ]

    static let repository = "github.com/kuzmenkonikolay/radarchik"

    /// Центр выреза по горизонтали на экране мака.
    private static var notchX: CGFloat { PromoWorld.screen.width / 2 }

    static func pose(at t: Double, format: PromoFormat) -> PromoPose {
        var pose = PromoPose()

        // 1–2. Голая чёлка просыпается: растёт подбородок, открываются глаза, оглядывается.
        pose.chin = Ease.spring(t - 2.4, response: 0.5, damping: 1)
        pose.faceOpacity = Ease.smooth(Ease.progress(t, 2.7, 3.1))
        pose.lids = 1 - Ease.out(Ease.progress(t, 2.8, 3.3))
        pose.lids = max(pose.lids, blink(t, at: [5.0, 9.0, 16.9, 25.6]))
        let glance = Keyframes<CGPoint>(keys: [
            (3.5, .zero), (3.9, CGPoint(x: -1, y: 0.35)), (4.3, CGPoint(x: -1, y: 0.35)),
            (4.7, CGPoint(x: 1, y: 0.35)), (5.1, CGPoint(x: 1, y: 0.35)), (5.5, .zero),
        ], mix: lerp)
        pose.gaze = glance.value(at: t)

        // 3. Крылья: итог месяца бежит из минуса в плюс, на каждый доход — глаза-монетки.
        pose.wings = Ease.spring(t - 5.4, response: 0.45, damping: 1)
        let money = Keyframes<Double>(keys: [(6.6, -102_700), (7.1, 17_300), (7.9, 17_300), (8.4, 292_300)], mix: lerp)
        pose.money = Int64(money.value(at: t))
        if (6.5..<7.6).contains(t) || (7.8..<8.9).contains(t) { pose.state = .catchCoin }

        // 4. Курсор наводит — чёлка расходится вширь, опускается в сводку, график растёт.
        (pose.widen, pose.expand) = panelSteps(t, open: 10.55, close: 14.3)
        pose.chartReveal = Ease.progress(t, 11.05, 12.25)
        if (10.55..<14.3).contains(t) { pose.state = .happy }

        // 5. Тревога: процессор и температура лезут вверх, выезжает записка.
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

        // 6. Советы готовы — глаза белеют; курсор открывает «Советы дня».
        if t >= 19.4 && t < 23.9 { pose.signal = .tipsReady }
        if t >= 20.45 {
            (pose.widen, pose.expand) = panelSteps(t, open: 20.45, close: 23.6)
            pose.route = .tips
            if t < 23.6 { pose.state = .tipWave }
        }

        // 7. Заставка: камера отъезжает, Радарчик доволен.
        if t >= 23.9 { pose.state = .happy }
        pose.outro = Ease.smooth(Ease.progress(t, 24.5, 25.3))

        // За курсором глаза следят только из свёрнутой чёлки; в раскрытой панели
        // смотрят прямо, как в приложении (2026-10-20).
        pose.cursor = cursor(at: t)
        if let cursor = pose.cursor, t > 9.9, pose.expand <= 0.001 { pose.gaze = gaze(towards: cursor, pose: pose) }

        // Камера: общий план → к чёлке → отъезд под панель → снова к чёлке → общий план.
        let camera = Keyframes<(Double, Double)>(keys: [
            (0, (1.0, 0)), (2.2, (1.04, 0)), (4.0, (format.closeZoom, 0)), (9.7, (format.closeZoom + 0.08, 0)),
            (10.7, (format.panelZoom, format.panelPan)), (14.2, (format.panelZoom, format.panelPan)),
            (15.2, (format.closeZoom, 0)), (19.8, (format.closeZoom, 0)),
            (20.7, (format.panelZoom, format.panelPan)), (23.5, (format.panelZoom, format.panelPan)),
            (25.0, (1.0, 0)),
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

    /// Курсор: появляется справа, наводит на чёлку, гуляет по панели и уходит.
    private static func cursor(at t: Double) -> CGPoint? {
        let x = notchX
        if (9.4..<14.8).contains(t) {
            return Keyframes<CGPoint>(keys: [
                (9.4, CGPoint(x: x + 560, y: 420)), (10.5, CGPoint(x: x + 26, y: 24)),
                (11.6, CGPoint(x: x + 40, y: 36)), (12.4, CGPoint(x: x - 130, y: 236)), (13.2, CGPoint(x: x + 120, y: 240)),
                (13.8, CGPoint(x: x + 60, y: 318)), (14.7, CGPoint(x: x + 560, y: 600)),
            ], mix: lerp).value(at: t)
        }
        if (19.5..<23.9).contains(t) {
            return Keyframes<CGPoint>(keys: [
                (19.5, CGPoint(x: x + 600, y: 380)), (20.4, CGPoint(x: x + 20, y: 22)),
                (21.4, CGPoint(x: x + 50, y: 120)), (22.3, CGPoint(x: x + 140, y: 218)),
                (23.0, CGPoint(x: x + 150, y: 222)), (23.85, CGPoint(x: x + 600, y: 620)),
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

/// Экран мака: обои, строка меню, чёлка и курсор.
private struct PromoScreen: View {
    let pose: PromoPose
    let world: PromoWorld

    var body: some View {
        ZStack(alignment: .top) {
            PromoWallpaper()
            PromoMenuBar(height: world.notch.height)
            PromoNotchView(pose: pose, world: world)
        }
        .overlay(alignment: .topLeading) {
            if let cursor = pose.cursor {
                PromoCursor().offset(x: cursor.x, y: cursor.y)
            }
        }
        .clipped()
    }
}

/// Чёлка в любом промежуточном виде: голая, полоска с лицом и цифрами, раскрытая
/// панель или алерт. Фигура и лицо перетекают, как в приложении (дизайн v2).
struct PromoNotchView: View {
    let pose: PromoPose
    let world: PromoWorld

    var body: some View {
        let notch = world.notch
        let barHeight = notch.height + 2
        let barWidth = lerp(notch.width + 2 * 10, world.barWidth(guard: pose.guardWing != nil), pose.wings)
        let isPanel = pose.widen > 0.001 || pose.expand > 0.001 || pose.announce > 0.001
        let p = Ease.clamp01(isPanel ? max(pose.expand, pose.announce) : 0)
        let full = world.size(of: pose.shownRoute)
        let width = lerp(barWidth, full.width, Ease.clamp01(max(pose.widen, p)))
        let height = lerp(barHeight, full.height, p)
        let top: CGFloat = lerp(CGFloat(6), CGFloat(10), p)
        let shape = PanelShape(topRadius: top, bottomRadius: lerp(DS.Radius.collapsed, DS.Radius.panel, p))
        let spec = faceSpec
        let glow = PanelGlow(color: spec.glow, alpha: 0.2 * p)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(0.5 * p), radius: 70, y: 30)
            PanelBackground(shape: shape, glow: glow)
            ZStack(alignment: .top) {
                if isPanel {
                    world.panel()
                        .environment(\.chartReveal, pose.chartReveal)
                        .scaleEffect(lerp(0.96, 1, p), anchor: .top)
                        .opacity(Ease.smooth(Ease.progress(p, 0.3, 0.85)))
                } else {
                    PromoBar(pose: pose, notch: notch)
                        .opacity(Ease.smooth(Ease.progress(pose.wings, 0.2, 0.9)))
                }
            }
            .padding(.horizontal, top)
            .overlayPreferenceValue(FaceSlotKey.self) { slot in
                GeometryReader { proxy in
                    let target = slot.map { proxy[$0.anchor] } ?? barRect(top: top)
                    let rect = isPanel ? lerpRect(barRect(top: top), target, p) : barRect(top: top)
                    FaceCanvas(geometry: FaceGeometry(spec), blink: pose.lids, look: pose.gaze)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(pose.faceOpacity)
                }
            }
        }
        .frame(width: width + 2 * top, height: height, alignment: .top)
        .clipShape(shape)
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

    /// Лицо по позе: эмоция из состояния, цвет из сигнала; веки — моргание ролика.
    private var faceSpec: FaceSpec {
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

/// Свёрнутая полоска ролика: место под лицо, итог месяца, процессор, температура, бейдж.
struct PromoBar: View {
    let pose: PromoPose
    let notch: CGSize

    var body: some View {
        // Та же симметричная раскладка, что у настоящей полоски (`CollapsedBar`).
        NotchBarLayout(gap: notch.width + 24, minWidth: DS.Size.collapsedWidth - 20) {
            HStack(spacing: 8) {
                Color.clear.frame(width: DS.Size.collapsedHeight, height: DS.Size.collapsedHeight * 2 / 3)
                if let wing = pose.guardWing {
                    WingItemView(item: WingItem(id: "guard", icon: "lock.open.fill", text: wing, color: DS.Tone.tips, iconColor: DS.Tone.tips, widest: "ssh 8:88"))
                }
                WingItemView(item: WingItem(id: "month", icon: nil, text: MoneyFormat.compact(pose.money, .usd, signed: true), color: DS.Money.text(for: pose.money), widest: "+$8.8k"))
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

/// Свои обои: тёмные, с мягкими пятнами цвета — экран не отвлекает от чёлки.
private struct PromoWallpaper: View {
    var body: some View {
        ZStack {
            Color(hex: "#0B0D1A")
            RadialGradient(colors: [Color(hex: "#3A2B8C").opacity(0.9), .clear], center: UnitPoint(x: 0.16, y: 0.95), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: "#0F6B7A").opacity(0.75), .clear], center: UnitPoint(x: 0.92, y: 0.78), startRadius: 0, endRadius: 820)
            RadialGradient(colors: [Color(hex: "#1F3C9E").opacity(0.5), .clear], center: UnitPoint(x: 0.55, y: 0.18), startRadius: 0, endRadius: 700)
        }
    }
}

/// Строка меню: полупрозрачная, как на тёмных обоях; посередине её закрывает чёлка.
private struct PromoMenuBar: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 20) {
                Text("Finder").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            }
            Spacer()
            HStack(spacing: 18) {
                Image(systemName: "battery.100percent")
                Image(systemName: "wifi")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
                Text("Mon Oct 19  9:41")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: height)
        .background(Color.black.opacity(0.24))
    }
}

/// Стрелка курсора macOS: чёрная с белой обводкой и мягкой тенью.
private struct PromoCursor: View {
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
