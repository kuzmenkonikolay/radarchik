import AppKit
import SwiftUI
import RadarchikCore

/// Всё про окно чёлки: где оно стоит, когда раскрываться и сворачиваться,
/// кому достаются клики, куда смотрит Радарчик и когда он спит.
///
/// Окно панели большое и прозрачное (как самая высокая раскрытая чёлка),
/// а видимая чёрная фигура внутри меняет размер. Поэтому клики пропускаются
/// везде, кроме фигуры: `ignoresMouseEvents` переключается на каждое движение
/// мыши. Так свёрнутая чёлка не мешает строке меню и вкладкам Chrome под ней.
@MainActor
final class NotchController {
    private let model: NotchViewModel
    private let store: MoneyStore
    private let settings: AppSettings
    private let tracker: ActivityTracker
    private let resources: ResourceMonitor
    private let panel = NotchPanel()

    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var restTask: Task<Void, Never>?
    /// Открыто меню («⋯», выбор проекта): оно вылезает за фигуру,
    /// и без этого флага чёлка свернулась бы прямо под ним.
    private var isMenuOpen = false

    /// Задержки против случайных срабатываний: курсор пролетел мимо выреза
    /// к пунктам меню — чёлка не дёргается.
    private let expandDelay: Duration = .milliseconds(120)
    private let collapseDelay: Duration = .milliseconds(260)

    init(store: MoneyStore, settings: AppSettings, tracker: ActivityTracker, review: ReviewService, resources: ResourceMonitor) {
        self.store = store
        self.settings = settings
        self.tracker = tracker
        self.resources = resources
        self.model = NotchViewModel(geometry: Self.currentGeometry().geometry)

        let hosting = NSHostingView(rootView: NotchRootView(
            model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources
        ))
        // Размер окна задаём сами, SwiftUI не должен его менять.
        hosting.sizingOptions = []
        panel.contentView = hosting

        model.onNeedsKeyboard = { [weak self] in self?.panel.makeKey() }
        model.onCollapse = { [weak self] in self?.returnKeyboard() }
        model.onRequestCollapse = { [weak self] in self?.collapse() }
        // Записка о тревоге нужна только свёрнутой чёлке.
        resources.isPanelExpanded = { [weak self] in self?.model.isExpanded ?? false }
    }

    func start() {
        layoutPanel()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        installEventMonitors()
        observeSystem()
        startRestingTimer()
    }

    // MARK: - Положение

    /// Экран с настоящей чёлкой, иначе главный (на нём рисуем виртуальную).
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } ?? NSScreen.screens.first
    }

    private static func currentGeometry() -> (geometry: NotchGeometry, screen: NSScreen?) {
        guard let screen = targetScreen() else {
            return (NotchGeometry(notchRect: CGRect(x: 0, y: 0, width: NotchGeometry.virtualWidth, height: 32), isHardware: false), nil)
        }
        // Высота строки меню на этом экране (0, если она скрыта) — для виртуальной чёлки.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let geometry = NotchGeometry.compute(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
            rightAreaWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight > 0 ? menuBarHeight : NSStatusBar.system.thickness
        )
        return (geometry, screen)
    }

    /// Окно по центру выреза, прижато к верхнему краю экрана.
    private func layoutPanel() {
        let (geometry, screen) = Self.currentGeometry()
        model.geometry = geometry
        guard let screen else { return }
        let width = DS.Size.panelWidth
        let height = min(DS.Size.panelHeight, screen.frame.height)
        panel.setFrame(
            CGRect(x: geometry.notchRect.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
            display: true
        )
    }

    /// Видимая фигура в координатах экрана: по центру окна, от верхнего края.
    private var shapeRect: CGRect {
        let size = model.shapeSize == .zero ? model.geometry.notchRect.size : model.shapeSize
        let frame = panel.frame
        return CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: - Мышь и клавиатура

    private func installEventMonitors() {
        // Для мыши разрешения не нужны (Accessibility нужен только для клавиш в чужих приложениях).
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) {
            eventMonitors.append(monitor)
        }
        // Над самой панелью события приходят нам, а не глобально.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) {
            eventMonitors.append(monitor)
        }
        // Клик в другом приложении — значит, мимо чёлки.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedElsewhere() }
        }) {
            eventMonitors.append(monitor)
        }
        // Esc: шаг назад, а со сводки — свернуть.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.escape() }
            return nil
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        let inside = shapeRect.contains(point)
        // Свёрнутая чёлка клики не ловит вовсе — только наведение (через глобальный
        // монитор). Так подбородок с глазами и уши не мешают строке меню и вкладкам.
        // Пишем только при смене: движений мыши сотни в секунду, а окну это лишняя работа.
        let ignores = !(inside && model.isExpanded)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
        if model.isResting { model.isResting = false }

        if model.isExpanded {
            updateGaze(towards: point)
            if inside || model.isPinned || isMenuOpen {
                cancelCollapse()
            } else if !shapeRect.insetBy(dx: -12, dy: -12).contains(point) {
                scheduleCollapse()
            }
        } else {
            if inside { scheduleExpand() } else { cancelExpand() }
            followCursorWhileCollapsed(point)
        }
    }

    private func clickedElsewhere() {
        guard model.isExpanded, !shapeRect.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    private func escape() {
        if model.isPinned {
            model.pop()
        } else if model.isExpanded {
            collapse()
        }
    }

    private func scheduleExpand() {
        guard expandTask == nil else { return }
        expandTask = Task { [weak self, expandDelay] in
            try? await Task.sleep(for: expandDelay)
            guard let self, !Task.isCancelled else { return }
            self.expandTask = nil
            if self.shapeRect.contains(NSEvent.mouseLocation) { self.expand() }
        }
    }

    private func cancelExpand() {
        expandTask?.cancel()
        expandTask = nil
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        collapseTask = Task { [weak self, collapseDelay] in
            try? await Task.sleep(for: collapseDelay)
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            let stillOutside = !self.shapeRect.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
            if stillOutside && !self.model.isPinned && !self.isMenuOpen { self.collapse() }
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func expand() {
        cancelCollapse()
        store.refreshMonth()
        // Раскрыли — тревога будет в облачке, записка больше не нужна.
        resources.dismissAnnouncement()
        model.expand()
        panel.ignoresMouseEvents = false
    }

    private func collapse() {
        cancelExpand()
        cancelCollapse()
        model.collapse()
        panel.ignoresMouseEvents = true
        // Пока была раскрыта, могла появиться тревога — теперь о ней можно сказать.
        resources.panelDidCollapse()
    }

    /// После формы панель остаётся «ключевой» и съедала бы нажатия клавиш.
    /// Переоткрываем окно без фокуса: клавиатура возвращается приложению,
    /// в котором ты работал.
    private func returnKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Где глаза в координатах экрана — от них считаем, куда смотреть.
    /// Верх фигуры — верх экрана, поэтому считаем от `maxY` (в AppKit y вверх).
    private var eyesCenter: CGPoint {
        let rect = shapeRect
        let notchHeight = model.geometry.notchRect.height
        if settings.mascotSkin == .livingNotch {
            // Лицо Живой чёлки всегда по центру: в подбородке или на сводке.
            let placement = FacePlacement(isExpanded: model.isExpanded, route: model.route)
            return CGPoint(x: rect.midX, y: rect.maxY - placement.eyeCenterY(notchHeight: notchHeight))
        }
        if !model.isExpanded {
            // Подбородок Домового — сразу под вырезом.
            return CGPoint(x: rect.midX, y: rect.minY + 8)
        }
        // Портрет на сводке — слева сверху, сразу под вырезом.
        return CGPoint(
            x: rect.minX + DS.Spacing.md + DS.Size.mascot / 2,
            y: rect.maxY - notchHeight - DS.Spacing.xs - DS.Size.mascot / 2
        )
    }

    /// Раскрыта — глаза смотрят на курсор.
    private func updateGaze(towards point: CGPoint) {
        let center = eyesCenter
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = max(hypot(dx, dy), 1)
        let strength = min(distance / 160, 1)
        // В AppKit y растёт вверх, в SwiftUI — вниз.
        let gaze = CGPoint(x: dx / distance * strength, y: -dy / distance * strength)
        if abs(gaze.x - model.gaze.x) > 0.02 || abs(gaze.y - model.gaze.y) > 0.02 {
            model.gaze = gaze
        }
    }

    /// Свёрнутая чёлка: глаза в подбородке следят за курсором, когда он ближе
    /// 400 pt к вырезу. Дальше — смотрят прямо, и перерисовок нет.
    private func followCursorWhileCollapsed(_ point: CGPoint) {
        let center = eyesCenter
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        let gaze: CGPoint
        if distance > 400 {
            gaze = .zero
        } else {
            let strength = min(distance / 120, 1)
            gaze = CGPoint(x: dx / max(distance, 1) * strength, y: -dy / max(distance, 1) * strength)
        }
        if abs(gaze.x - model.gaze.x) > 0.05 || abs(gaze.y - model.gaze.y) > 0.05 {
            model.gaze = gaze
        }
    }

    // MARK: - Система

    private func observeSystem() {
        let center = NotificationCenter.default
        // Подключили монитор, закрыли крышку, поменяли разрешение.
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        })
        // Наступил новый день: возможно, и новый месяц.
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refreshMonth() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.refreshMonth()
                self?.layoutPanel()
            }
        })
        // Меню наших кнопок (SwiftUI Menu и Picker — это NSMenu).
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMenuOpen = true
                self?.cancelCollapse()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuOpen = false }
        })
    }

    /// Раз в минуту: не пора ли Радарчику спать. Простой берём у системы
    /// (время с последнего нажатия или движения мыши, разрешения не нужны).
    /// На звонке клавиатуру не трогают, но человек здесь — не спим.
    private func startRestingTimer() {
        restTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(10))
                self?.updateResting()
            }
        }
    }

    private func updateResting() {
        let idle = ActivityTracker.idleSeconds()
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 1 && hour < 6
        let resting = !tracker.isInCall && (idle > 10 * 60 || (isNight && idle > 2 * 60))
        if model.isResting != resting { model.isResting = resting }
    }
}
