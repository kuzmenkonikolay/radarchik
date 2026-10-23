import SwiftUI
import RadarchikCore

/// Экраны раскрытой чёлки (дизайн v2). Главная — пустой стек; всё остальное
/// кладётся поверх и закрывается «Esc» или кнопкой «домой» в тулбаре.
enum Route: Hashable {
    case project(UUID)
    /// nil — новый проект.
    case projectForm(editing: UUID?)
    case entryForm(EntryFormTarget)
    /// Советы дня (G) и разбор, который идёт прямо сейчас (F).
    case tips
    case review
    /// Куда платить в этом месяце.
    case payments
    /// Побочные экраны: лицо слева, содержимое справа.
    case system
    case protection
    /// «Сетевой надзор» (SPEC §3б, 2026-10-22).
    case network
    case settings
    case observation
    case today
    case claudeSettings
    case reviewPrompt
    /// Алерты (D, E и тревоги): раскрываются сами, без тулбара.
    case alert(PanelAlert)

    /// Экраны с полями ввода: панель должна забрать клавиатуру.
    var needsKeyboard: Bool {
        switch self {
        case .projectForm, .entryForm, .claudeSettings, .observation: true
        default: false
        }
    }

    var isAlert: Bool {
        if case .alert = self { return true }
        return false
    }

    /// Ширина панели под экран; высота — по содержимому.
    var panelWidth: CGFloat {
        switch self {
        case .project: DS.Panel.project
        case .projectForm, .entryForm: DS.Panel.add
        case .tips: DS.Panel.tips
        case .review: DS.Panel.review
        case .alert: DS.Panel.alert
        case .payments, .system, .protection, .network, .settings, .observation, .today, .claudeSettings, .reviewPrompt: DS.Panel.side
        }
    }
}

/// Что показывает алерт: пришли деньги (D), пора платить (E), приложение ест
/// больше обычного, опасное от «Защиты».
enum PanelAlert: Hashable {
    case income(IncomeNews)
    case pay(PayReminder)
    case resource(Int64)
    case guardEvent(GuardEvent)
}

/// Только что добавленный доход — для алерта «Пришли деньги».
struct IncomeNews: Hashable, Identifiable {
    let id: UUID
    let amount: Int64
    let currency: Currency
    let projectName: String
    let title: String
    /// Итог месяца по этой валюте до и после.
    let before: Int64
    let after: Int64
    let month: YearMonth
}

/// Что показывает экран «Система»: график и список — по одной величине.
enum SystemMetric: String, CaseIterable, Identifiable, Hashable {
    case cpu
    case memory
    case energy

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: L("Процессор", "CPU")
        case .memory: L("Память", "Memory")
        case .energy: L("Энергия", "Energy")
        }
    }

    /// Какая вкладка нужна тревоге этого вида.
    init(_ kind: ResourceKind) {
        switch kind {
        case .cpu, .thermal: self = .cpu
        case .memory, .pressure: self = .memory
        case .battery: self = .energy
        }
    }
}

/// С чем открыть экран «Система»: величина и приложение, которое подсветить.
struct SystemFocus: Hashable {
    var metric: SystemMetric
    var appKey: String?
}

/// Что за запись в форме.
enum EntryKind: String, CaseIterable, Identifiable, Hashable {
    case recurring
    case oneOff
    case income

    var id: Self { self }

    var title: String {
        switch self {
        case .recurring: L("Регулярная", "Recurring")
        case .oneOff: L("Разовая", "One-off")
        case .income: L("Доход", "Income")
        }
    }

    var longTitle: String {
        switch self {
        case .recurring: L("Регулярная трата", "Recurring cost")
        case .oneOff: L("Разовая трата", "One-off cost")
        case .income: L("Доход", "Income")
        }
    }
}

enum EntryFormTarget: Hashable {
    /// Новая запись; projectId — заранее выбранный проект (с экрана проекта).
    case new(EntryKind, projectId: UUID?)
    case editRecurring(UUID)
    case editOneOff(UUID)
    case editIncome(UUID)
}

/// Что нарисовано: свёрнутая полоска или раскрытая панель. Между ними — одна
/// пружина для ширины, высоты и радиуса (SPEC Coucou).
enum NotchStage: Equatable {
    case collapsed
    case expanded
}

/// Состояние чёлки: свёрнута или раскрыта, стек экранов, взгляд и сон Радарчика,
/// алерты. Мышью и окном управляет `NotchController`, экраны читают и меняют `path`.
@MainActor
@Observable
final class NotchViewModel {
    var geometry: NotchGeometry
    /// Раскрыта ли по смыслу — сразу, как навели или увели курсор.
    private(set) var isExpanded = false
    /// Что нарисовано: идёт к `isExpanded` пружиной.
    private(set) var stage = NotchStage.collapsed
    /// Содержимое проявляется с задержкой 80 мс после раскрытия и тает за 120 мс до сворачивания.
    private(set) var contentShown = false
    /// Стек экранов поверх главной; пустой — главная.
    private(set) var path: [Route] = []
    /// С чем открыли «Систему»: величина и приложение («Показать» у тревоги).
    private(set) var systemFocus: SystemFocus?
    /// Куда смотреть глазам: −1…1 по каждой оси (y вниз, как в SwiftUI).
    var gaze: CGPoint = .zero
    /// Давно никого нет (или ночь) — Радарчик спит.
    var isResting = false
    /// Навели курсор — на 200 мс глаза wide.
    private(set) var isStartled = false
    /// Размер видимой чёрной фигуры: по нему контроллер решает, где ловить мышь.
    var shapeSize: CGSize = .zero
    /// Где лицо в координатах корня панели — от него считается взгляд.
    var faceFrame: CGRect = .zero
    /// Звук включён (кнопка в тулбаре).
    var soundEnabled = true
    /// Пришли деньги: лицо подпрыгивает, цифры прокручиваются.
    private(set) var jump: CGFloat = 0

    /// Контроллер подписывается: формам нужна клавиатура, а после сворачивания её надо вернуть.
    @ObservationIgnored var onNeedsKeyboard: (() -> Void)?
    @ObservationIgnored var onCollapse: (() -> Void)?
    /// Экран просит свернуть чёлку («Пример тревоги»): сворачивает контроллер, он же отпускает мышь.
    @ObservationIgnored var onRequestCollapse: (() -> Void)?
    /// Алерт раскрыл панель сам: контроллер включает мышь.
    @ObservationIgnored var onPresentAlert: (() -> Void)?
    /// Что-то раскрылось или прозвучало — для звуков.
    @ObservationIgnored var onSound: ((SoundKind) -> Void)?
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var startleTask: Task<Void, Never>?
    /// Панель раскрыл алерт, а не ты: после ответа на него она свернётся целиком.
    @ObservationIgnored private var expandedByAlert = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var route: Route? { path.last }

    /// На формах панель не сворачивается, когда курсор уходит: иначе она
    /// закрывалась бы посреди ввода суммы. Закрыть — клик мимо или Esc.
    /// Алерт тоже держится: он пришёл сам, пока ты работал в другом окне, и
    /// уходит только по своей кнопке или Esc — ни уход мыши, ни клик мимо его не трогают.
    /// Остальные экраны (советы, проект, система) уходят вместе с курсором, как главная.
    var isPinned: Bool { (route?.needsKeyboard ?? false) || route?.isAlert == true }

    /// Ширина панели сейчас: по экрану, главная — 860.
    var panelWidth: CGFloat {
        let wanted = route?.panelWidth ?? DS.Panel.home
        return min(wanted, DS.Size.panelWidth - 2 * 60)
    }

    /// `animated: false` — сразу в конечный вид: листу экранов и ролику пружина не нужна.
    func expand(animated: Bool = true) {
        guard !isExpanded else { return }
        isExpanded = true
        expandedByAlert = false
        moveStage(to: .expanded, animated: animated)
    }

    func collapse(animated: Bool = true) {
        isExpanded = false
        expandedByAlert = false
        path.removeAll()
        systemFocus = nil
        onCollapse?()
        moveStage(to: .collapsed, animated: animated)
    }

    private func moveStage(to target: NotchStage, animated: Bool) {
        contentTask?.cancel()
        guard animated else {
            stage = target
            contentShown = target == .expanded
            return
        }
        guard stage != target else { return }
        withAnimation(DS.spring) { stage = target }
        if target == .expanded {
            contentTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.contentShown = true }
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) { contentShown = false }
        }
    }

    // MARK: - Экраны

    /// Смена экрана: панель меняет ширину и высоту той же пружиной.
    func push(_ route: Route) {
        withAnimation(DS.spring) {
            path.append(route)
        }
        if route.needsKeyboard { onNeedsKeyboard?() }
    }

    /// Открыть экран из тулбара: повторный клик по нему — домой.
    func toggle(_ route: Route) {
        if self.route == route {
            home()
        } else {
            show(route)
        }
    }

    /// Один экран поверх главной (тулбар): стек не копится.
    func show(_ route: Route, focus: SystemFocus? = nil) {
        withAnimation(DS.spring) {
            path = [route]
            systemFocus = focus
        }
        if route.needsKeyboard { onNeedsKeyboard?() }
    }

    func pop() {
        withAnimation(DS.spring) { _ = path.popLast() }
    }

    /// Заменить верхний экран (например, после создания проекта открыть его карточку).
    func replaceTop(with route: Route) {
        withAnimation(DS.spring) {
            _ = path.popLast()
            path.append(route)
        }
        if route.needsKeyboard { onNeedsKeyboard?() }
    }

    func home() {
        withAnimation(DS.spring) {
            path.removeAll()
            systemFocus = nil
        }
    }

    func requestCollapse() {
        onRequestCollapse?()
    }

    // MARK: - Алерты

    /// Показать алерт: раскрыть панель, если свёрнута, и завести таймер.
    func present(_ alert: PanelAlert) {
        if !isExpanded {
            isExpanded = true
            expandedByAlert = true
            moveStage(to: .expanded, animated: true)
            onPresentAlert?()
        }
        withAnimation(DS.spring) {
            path.removeAll { $0.isAlert }
            path.append(.alert(alert))
        }
        onSound?(alert.sound)
        if case .income = alert { bounce() }
    }

    /// Закрыть алерт: кнопка на нём, Esc или тревога прошла сама.
    func dismissAlert() {
        guard route?.isAlert == true else { return }
        if expandedByAlert {
            onRequestCollapse?()
        } else {
            pop()
        }
    }

    /// Прыжок лица на −6 pt пружиной (пришли деньги).
    func bounce() {
        jump = 6
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            self?.jump = 0
        }
    }

    /// Навели курсор на свёрнутую чёлку: на 200 мс глаза wide.
    func startle() {
        guard !isStartled else { return }
        isStartled = true
        startleTask?.cancel()
        startleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.isStartled = false
        }
    }
}

/// Короткие тихие звуки (кнопка в тулбаре их выключает).
/// Звуки Радарчика. У алертов — по серьёзности: монетка за доход, звоночек
/// «Пора платить», предупреждение о ресурсах, сигнал «Защиты». Раскрытие панели беззвучно.
enum SoundKind: CaseIterable {
    /// Пришли деньги.
    case coin
    /// «Пора платить»: мягкий звоночек из двух нот вверх.
    case chime
    /// Тревога ресурсов: два тона пониже и вниз, настойчивее.
    case warning
    /// Опасное от «Защиты»: три коротких сигнала, громче остальных.
    case alarm
    /// Заметил рутину, записал.
    case pencil

    /// Звук алерта, а не твоего действия: на звонке молчит.
    var isAlert: Bool {
        switch self {
        case .coin, .chime, .warning, .alarm: true
        case .pencil: false
        }
    }
}

extension PanelAlert {
    /// Чем звучит алерт — по серьёзности.
    var sound: SoundKind {
        switch self {
        case .income: .coin
        case .pay: .chime
        case .resource: .warning
        case .guardEvent(let event): event.level == .critical ? .alarm : .warning
        }
    }
}
