import SwiftUI
import RadarchikCore

/// Корень панели. Чёрная фигура растёт из выреза вниз. Свёрнута — под
/// вырезом подбородок с глазами, раскрыта — текущий экран. Размер фигуры задаёт содержимое, контроллер
/// узнаёт его через `model.shapeSize`.
///
/// Лицо Живой чёлки (`NotchFace`) лежит поверх содержимого и переживает
/// смену экранов: при раскрытии оно растёт той же пружиной, что и фигура.
///
/// Тревога о ресурсах (этап 6) выдвигает из свёрнутой чёлки записку:
/// подбородок расширяется в плашку с фразой, глаза остаются на месте.
struct NotchRootView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor

    var body: some View {
        // Свёрнутая чёлка — с «подбородком» под вырезом, где глаза.
        let notchHeight = model.geometry.notchRect.height
        let shape: NotchShape = if model.isExpanded {
            .expanded(notchHeight: notchHeight)
        } else if resources.announcement != nil {
            .announcement(notchHeight: notchHeight)
        } else {
            .collapsed(notchHeight: notchHeight)
        }
        VStack(spacing: 0) {
            content
                .background(shape.fill(DS.Surface.panel))
                .overlay(alignment: .top) {
                    NotchFace(model: model, store: store, tracker: tracker, review: review, resources: resources, eyes: settings.eyeStyle)
                }
                .clipShape(shape)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    model.shapeSize = size
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: model.isExpanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.path)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: resources.announcement?.id)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, settings.language.locale)
        // Тексты берутся из `Language.current`, а не из окружения SwiftUI, —
        // сменили язык в настройках, и панель собирается заново. Экран не
        // теряется: стек экранов живёт в модели.
        .id(settings.language)
    }

    @ViewBuilder
    private var content: some View {
        if model.isExpanded {
            ExpandedView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources)
                // Под самим вырезом пикселей нет — содержимое начинается ниже,
                // под лицом.
                .padding(.top, model.geometry.notchRect.height + FacePlacement(isExpanded: true, route: model.route).contentTop)
                .frame(width: DS.Size.expandedWidth)
                .transition(.opacity)
        } else if let alert = resources.announcement {
            AnnouncementView(alert: alert, notchHeight: model.geometry.notchRect.height)
                .transition(.opacity)
        } else {
            CollapsedView(model: model, store: store, settings: settings, tracker: tracker, resources: resources)
                .transition(.opacity)
        }
    }
}

/// Форма чёлки: верхняя полоса — сам вырез с вогнутыми «плечиками», под ней
/// по центру «подбородок». Свёрнутая чёлка — полоса и маленький подбородок
/// с глазами; раскрытая — подбородок во всю ширину, то есть просто панель
/// со скруглённым низом. Поэтому при раскрытии подбородок разрастается
/// в панель — чёлка набухает каплей, а глаза растут внутри неё.
struct NotchShape: Shape {
    /// Вогнутые плечики сверху.
    var topRadius: CGFloat
    /// Нижние углы полосы по бокам от подбородка.
    var bandRadius: CGFloat
    /// Высота полосы — выреза. Всё, что ниже, — подбородок.
    var bandHeight: CGFloat
    /// Ширина подбородка; если больше фигуры — во всю ширину.
    var chinWidth: CGFloat
    /// Нижние углы подбородка.
    var chinRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(topRadius, bandRadius), AnimatablePair(bandHeight, AnimatablePair(chinWidth, chinRadius))) }
        set {
            topRadius = newValue.first.first
            bandRadius = newValue.first.second
            bandHeight = newValue.second.first
            chinWidth = newValue.second.second.first
            chinRadius = newValue.second.second.second
        }
    }

    /// «Подбородок» под вырезом в свёрнутой чёлке — там глаза.
    /// Внутри самого выреза пикселей нет, поэтому лицо — ниже него.
    /// nonisolated: по нему раскладывают лицо (`FacePlacement`) вне вида.
    nonisolated static let chin = CGSize(width: 46, height: 15)

    /// Свёрнутая: полоса выреза и подбородок с глазами.
    static func collapsed(notchHeight: CGFloat) -> NotchShape {
        NotchShape(topRadius: 6, bandRadius: 10, bandHeight: notchHeight, chinWidth: chin.width, chinRadius: chin.height - 4)
    }

    /// Раскрытая: подбородок во всю ширину.
    static func expanded(notchHeight: CGFloat) -> NotchShape {
        NotchShape(topRadius: 10, bandRadius: 10, bandHeight: notchHeight, chinWidth: DS.Size.expandedWidth, chinRadius: DS.Radius.panel)
    }

    /// Записка о тревоге: подбородок разрастается в небольшую плашку под вырезом.
    static func announcement(notchHeight: CGFloat) -> NotchShape {
        NotchShape(topRadius: 8, bandRadius: 10, bandHeight: notchHeight, chinWidth: DS.Size.announcementWidth, chinRadius: 18)
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let left = rect.minX + top
        let right = rect.maxX - top
        let bandBottom = min(rect.minY + bandHeight, rect.maxY)
        let chinW = min(max(chinWidth, 0), right - left)
        let chinH = rect.maxY - bandBottom
        // Уступ полосы по бокам подбородка. Подбородок во всю ширину — уступа нет,
        // и углы полосы со скруглениями стыка плавно сходят на нет.
        let step = (right - left - chinW) / 2
        let fillet = max(min(4, step / 2, chinH / 2), 0)
        let bandR = max(min(bandRadius, step - fillet, bandBottom - rect.minY - top), 0)
        let chinR = max(min(chinRadius, chinW / 2, chinH - fillet), 0)
        let chinLeft = rect.midX - chinW / 2
        let chinRight = rect.midX + chinW / 2

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Вогнутое плечо слева: от края экрана внутрь.
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + top), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: bandBottom - bandR))
        // Низ полосы слева и мягкий переход в подбородок.
        path.addQuadCurve(to: CGPoint(x: left + bandR, y: bandBottom), control: CGPoint(x: left, y: bandBottom))
        path.addLine(to: CGPoint(x: chinLeft - fillet, y: bandBottom))
        path.addQuadCurve(to: CGPoint(x: chinLeft, y: bandBottom + fillet), control: CGPoint(x: chinLeft, y: bandBottom))
        // Подбородок.
        path.addLine(to: CGPoint(x: chinLeft, y: rect.maxY - chinR))
        path.addQuadCurve(to: CGPoint(x: chinLeft + chinR, y: rect.maxY), control: CGPoint(x: chinLeft, y: rect.maxY))
        path.addLine(to: CGPoint(x: chinRight - chinR, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: chinRight, y: rect.maxY - chinR), control: CGPoint(x: chinRight, y: rect.maxY))
        path.addLine(to: CGPoint(x: chinRight, y: bandBottom + fillet))
        path.addQuadCurve(to: CGPoint(x: chinRight + fillet, y: bandBottom), control: CGPoint(x: chinRight, y: bandBottom))
        // Низ полосы справа.
        path.addLine(to: CGPoint(x: right - bandR, y: bandBottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bandBottom - bandR), control: CGPoint(x: right, y: bandBottom))
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        // Вогнутое плечо справа.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Раскрытая чёлка: баннер ошибки (если есть) и текущий экран из стека.
struct ExpandedView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let error = store.lastError {
                ErrorBanner(text: error) { store.lastError = nil }
            }
            if let error = tracker.lastError {
                ErrorBanner(text: error) { tracker.lastError = nil }
            }
            if let error = resources.lastError {
                ErrorBanner(text: error) { resources.lastError = nil }
            }
            screen
                // Новый экран — новое состояние формы, даже если тип тот же.
                .id(model.route)
                .transition(.opacity)
        }
        // Сверху отступ задаёт `NotchRootView`: он зависит от лица.
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.md)
    }

    @ViewBuilder
    private var screen: some View {
        switch model.route {
        case nil:
            SummaryView(model: model, store: store, settings: settings, review: review, resources: resources)
        case .project(let id):
            ProjectDetailView(projectId: id, model: model, store: store)
        case .payments:
            PaymentsView(model: model, store: store)
        case .settings:
            SettingsView(model: model, settings: settings, resources: resources)
        case .projectForm(let editing):
            ProjectFormView(editingId: editing, model: model, store: store)
        case .entryForm(let target):
            EntryFormView(target: target, model: model, store: store)
        case .observation:
            ObservationView(model: model, tracker: tracker, settings: settings)
        case .today:
            TodayView(model: model, tracker: tracker)
        case .tips:
            TipsView(model: model, review: review)
        case .claudeSettings:
            ClaudeSettingsView(model: model, review: review, settings: settings)
        case .reviewPrompt:
            ReviewPromptView(model: model, review: review)
        case .system(let focus):
            SystemView(model: model, resources: resources, settings: settings, focus: focus)
        }
    }
}

/// Ошибка записи в базу. Значок и текст: цвет один ничего не сообщает.
private struct ErrorBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.antenna(.yellow))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(DS.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Ink.secondary)
        }
        .padding(DS.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Surface.warning))
    }
}
