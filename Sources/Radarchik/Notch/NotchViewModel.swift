import SwiftUI
import RadarchikCore

/// Экраны раскрытой чёлки поверх сводки.
enum Route: Hashable {
    case project(UUID)
    case payments
    case settings
    /// nil — новый проект.
    case projectForm(editing: UUID?)
    case entryForm(EntryFormTarget)
    /// Наблюдение: разрешения, терминал, исключения (этап 3).
    case observation
    /// Что записано сегодня.
    case today
    /// Советы дня (этап 4).
    case tips
    /// Ключ, модель, время разбора, прокси.
    case claudeSettings
    /// Что уходит в Claude.
    case reviewPrompt
    /// Ресурсы мака (этап 6): график за час и кто больше всех ест.
    /// `focus` — с чем открыли (кнопка «Показать» у тревоги).
    case system(SystemFocus?)

    /// Экраны с полями ввода: панель должна забрать клавиатуру.
    var needsKeyboard: Bool {
        switch self {
        case .projectForm, .entryForm, .observation, .claudeSettings: true
        case .project, .payments, .settings, .today, .tips, .reviewPrompt, .system: false
        }
    }
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

/// С чем открыть экран «Система»: вкладка и приложение, которое подсветить.
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

/// Состояние чёлки: свёрнута или раскрыта, стек экранов, взгляд и сон Радарчика.
/// Мышью и окном управляет `NotchController`, экраны только читают и меняют `path`.
@MainActor
@Observable
final class NotchViewModel {
    var geometry: NotchGeometry
    private(set) var isExpanded = false
    /// Стек экранов поверх сводки; пустой — сводка.
    private(set) var path: [Route] = []
    /// Куда смотреть глазам: −1…1 по каждой оси (y вниз, как в SwiftUI).
    var gaze: CGPoint = .zero
    /// Давно никого нет (или ночь) — Радарчик спит.
    var isResting = false
    /// Размер видимой чёрной фигуры: по нему контроллер решает, где ловить мышь.
    var shapeSize: CGSize = .zero

    /// Контроллер подписывается: формам нужна клавиатура, а после сворачивания её надо вернуть.
    @ObservationIgnored var onNeedsKeyboard: (() -> Void)?
    @ObservationIgnored var onCollapse: (() -> Void)?
    /// Экран просит свернуть чёлку («Пример тревоги»): сворачивает контроллер, он же отпускает мышь.
    @ObservationIgnored var onRequestCollapse: (() -> Void)?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var route: Route? { path.last }

    /// На внутренних экранах панель не сворачивается, когда курсор уходит:
    /// иначе она закрывалась бы посреди ввода суммы. Закрыть — клик мимо или Esc.
    var isPinned: Bool { !path.isEmpty }

    func expand() {
        isExpanded = true
    }

    func collapse() {
        isExpanded = false
        path.removeAll()
        onCollapse?()
    }

    func push(_ route: Route) {
        path.append(route)
        if route.needsKeyboard { onNeedsKeyboard?() }
    }

    func pop() {
        _ = path.popLast()
    }

    /// Заменить верхний экран (например, после создания проекта открыть его карточку).
    func replaceTop(with route: Route) {
        _ = path.popLast()
        push(route)
    }

    func popToRoot() {
        path.removeAll()
    }

    func requestCollapse() {
        onRequestCollapse?()
    }
}
