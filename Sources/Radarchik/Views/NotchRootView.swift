import SwiftUI
import RadarchikCore

/// Корень панели (дизайн v2). Чёрная фигура растёт из выреза вниз: свёрнута —
/// полоска 300×34 с мини-лицом слева и бейджем советов справа, раскрыта —
/// тулбар в «ушах» выреза и карточки экрана. Ширина — по экрану, высота — по
/// содержимому; фигура, ширина и радиус перетекают одной пружиной.
///
/// Лицо одно на всю панель: экран ставит под него место (`faceSlot`), а здесь
/// оно рисуется поверх по якорю и перетекает из полоски в карточку.
struct NotchRootView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor
    @Environment(\.unrollsScrolling) private var isRendering

    var body: some View {
        let isOpen = model.stage == .expanded
        let shape = PanelShape(topRadius: isOpen ? 10 : 6, bottomRadius: isOpen ? DS.Radius.panel : DS.Radius.collapsed)
        let look = FaceDirector.look(model: model, store: store, review: review, tracker: tracker, resources: resources, protection: protection)
        let glow = PanelGlow.of(model.route, look: look, store: store, isOpen: isOpen)

        VStack(spacing: 0) {
            // Контейнер нарочно: модификаторы на `if` SwiftUI раздаёт каждой ветке,
            // и при смене ветки фигура не перетекала бы, а растворялась.
            ZStack(alignment: .top) {
                content
            }
            .padding(.horizontal, shape.topRadius)
            .background(PanelBackground(shape: shape, glow: glow))
            .clipShape(shape)
            // Тень — снаружи фигуры, под ней: иначе она бы перекрыла свечение.
            .background {
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 70, y: 30)
            }
            .overlayPreferenceValue(FaceSlotKey.self) { slot in
                GeometryReader { proxy in
                    if let slot {
                        let rect = proxy[slot.anchor]
                        FaceView(spec: slot.spec, look: model.gaze, jump: model.jump, isLive: !isRendering, breathes: model.isExpanded && !isRendering)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .animation(DS.spring, value: rect)
                            .onChange(of: rect, initial: true) { model.faceFrame = rect }
                            .allowsHitTesting(false)
                    }
                }
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                model.shapeSize = size
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(DS.spring, value: model.route)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, settings.language.locale)
        // Тексты берутся из `Language.current`: сменили язык — панель собирается заново.
        .id(settings.language)
        // Алерты раскрывают панель сами: новый доход, скорое списание, тревоги.
        .onChange(of: store.news?.id) { _, _ in
            if let news = store.news { model.present(.income(news)) }
        }
        .onChange(of: resources.announcement?.id) { _, _ in
            if let alert = resources.announcement { model.present(.resource(alert.id)) }
        }
        .onChange(of: protection.announcement?.id) { _, _ in
            if let event = protection.announcement { model.present(.guardEvent(event)) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isExpanded {
            ExpandedView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
                .frame(width: model.panelWidth)
                .opacity(model.contentShown ? 1 : 0)
                .allowsHitTesting(model.contentShown)
        } else {
            CollapsedBar(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
        }
    }
}

/// Форма панели: сверху вогнутые «плечики» в продолжение выреза, снизу
/// скруглённые углы. Радиусы анимируются вместе с размером.
struct PanelShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(min(topRadius, rect.width / 4, rect.height / 2), 0)
        let left = rect.minX + top
        let right = rect.maxX - top
        let bottom = max(min(bottomRadius, (right - left) / 2, rect.height - top), 0)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + top), control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - bottom), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Свечение снизу панели: цвет состояния и сила — по экрану.
struct PanelGlow: Equatable {
    var color: Color
    var alpha: Double

    static let none = PanelGlow(color: .clear, alpha: 0)

    @MainActor
    static func of(_ route: Route?, look: MascotLook, store: MoneyStore, isOpen: Bool) -> PanelGlow {
        guard isOpen else { return .none }
        switch route {
        case nil: return PanelGlow(color: look.tone, alpha: DS.Glow.home)
        case .project(let id):
            let glance = store.glances.first { $0.project.id == id }
            return PanelGlow(color: glance.map(FaceDirector.tone) ?? look.tone, alpha: DS.Glow.project)
        case .alert(let alert):
            switch alert {
            case .income: return PanelGlow(color: DS.Tone.plus, alpha: DS.Glow.income)
            case .pay: return PanelGlow(color: DS.Tone.minus, alpha: DS.Glow.pay)
            case .resource: return PanelGlow(color: DS.Tone.tips, alpha: DS.Glow.pay)
            case .guardEvent(let event): return PanelGlow(color: event.level == .critical ? DS.Tone.alarm : DS.Tone.tips, alpha: DS.Glow.pay)
            }
        case .review: return PanelGlow(color: DS.Tone.info, alpha: DS.Glow.review)
        case .tips: return PanelGlow(color: DS.Tone.tips, alpha: DS.Glow.tips)
        case .entryForm, .projectForm: return PanelGlow(color: DS.Ink.body, alpha: DS.Glow.add)
        default: return PanelGlow(color: look.tone, alpha: DS.Glow.side)
        }
    }
}

/// Фон панели: чёрный и радиальное свечение от нижнего центра — эллипс 70%
/// ширины × 190 pt, цвет состояния → прозрачный к 70%. Лежит под карточками
/// и просвечивает сквозь них.
struct PanelBackground: View {
    var shape: PanelShape
    var glow: PanelGlow

    var body: some View {
        ZStack(alignment: .bottom) {
            shape.fill(DS.Surface.panel)
            GeometryReader { proxy in
                let width = proxy.size.width * 0.9
                EllipticalGradient(
                    stops: [
                        .init(color: glow.color.opacity(glow.alpha), location: 0),
                        .init(color: glow.color.opacity(glow.alpha * 0.45), location: 0.3),
                        .init(color: glow.color.opacity(glow.alpha * 0.12), location: 0.6),
                        .init(color: .clear, location: 0.85),
                    ],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
                )
                .frame(width: width, height: 380)
                .position(x: proxy.size.width / 2, y: proxy.size.height)
            }
            .animation(.easeInOut(duration: 0.35), value: glow)
        }
    }
}

// MARK: - Свёрнуто

/// Полоска 300×34: мини-лицо 34 слева, справа бейдж с числом советов.
/// По настройке «Цифры по бокам чёлки» между ними цифры: слева деньги
/// (и замок открытого ключа), справа система. На звонке цифр нет.
struct CollapsedBar: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor

    var body: some View {
        let look = FaceDirector.look(model: model, store: store, review: review, tracker: tracker, resources: resources, protection: protection)
        let showWings = settings.showNumbersWhenCollapsed && !tracker.isInCall
        let notchWidth = model.geometry.notchRect.width
        // Две группы симметрично вокруг выреза (`NotchBarLayout`): иначе длинная
        // левая (лицо, крыло «Защиты», итог) сдвигала бы промежуток, и итог уезжал под сам вырез.
        NotchBarLayout(gap: notchWidth + 24, minWidth: DS.Size.collapsedWidth - 20) {
            HStack(spacing: 8) {
                FacePlaceholder(spec: look.spec, width: DS.Size.collapsedHeight, priority: model.isExpanded ? 0 : 1)
                if let wing = protection.wing {
                    let color = wing.isOverdue ? DS.Tone.minus : DS.Tone.tips
                    WingItemView(item: WingItem(id: "guard", icon: wing.isOverdue ? "exclamationmark.triangle.fill" : "lock.open.fill", text: wing.text, color: color, iconColor: color))
                }
                if showWings, !store.monthTotals.isEmpty {
                    let totals = store.monthTotals
                    WingItemView(item: WingItem(
                        id: "month", icon: nil, text: MoneyFormat.compactList(totals, signed: true),
                        color: totals.count == 1 ? DS.Money.text(for: totals[0].amount) : DS.Ink.secondary
                    ))
                }
            }
            HStack(spacing: 8) {
                if showWings, settings.resourcesEnabled, let system = resources.system {
                    WingItemView(item: WingItem(id: "cpu", icon: "cpu", text: ResourceFormat.percent(system.cpuPercent), color: DS.Ink.secondary, widest: "88%"))
                    if let temperature = system.temperature {
                        WingItemView(item: WingItem(id: "temperature", icon: "thermometer.medium", text: ResourceFormat.temperature(temperature), color: DS.Ink.secondary, widest: "88°"))
                    }
                }
                if review.newTipsCount > 0 {
                    CountBadge(count: review.newTipsCount)
                } else if protection.activeAlert != nil {
                    Circle().fill(DS.Tone.alarm).frame(width: 8, height: 8)
                } else if resources.activeAlert != nil {
                    Circle().fill(DS.Tone.tips).frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: max(model.geometry.notchRect.height + 2, DS.Size.collapsedHeight))
        // По содержимому, не на всё окно: ширину считает `NotchBarLayout`.
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}

/// Что стоит в крыле свёрнутой чёлки: значок, текст и его цвет.
struct WingItem: Identifiable, Equatable {
    let id: String
    var icon: String?
    let text: String
    var color: Color = DS.Ink.secondary
    var iconColor: Color?
    /// Самый широкий текст этого места («88%»): под него держим место, чтобы
    /// фигура не дёргалась, когда меняются цифры.
    var widest: String?
}

struct WingItemView: View {
    let item: WingItem

    var body: some View {
        HStack(spacing: 3) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(item.iconColor ?? DS.Ink.secondary)
            }
            ZStack(alignment: .leading) {
                if let widest = item.widest { Text(widest).hidden() }
                Text(item.text).foregroundStyle(item.color)
            }
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// Раскладка свёрнутой полоски: две группы по краям, между ними промежуток под
/// вырез. Обе стороны получают ширину большей, поэтому промежуток всегда по центру
/// полоски, а полоска — по центру выреза: ничего не прячется за самим вырезом.
struct NotchBarLayout: Layout {
    /// Ширина выреза с отступами.
    var gap: CGFloat
    /// Уже этого полоска не бывает (без внешних отступов).
    var minWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let side = max(sizes.map(\.width).max() ?? 0, (minWidth - gap) / 2)
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: side * 2 + gap, height: max(height, proposal.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let isLeft = index == 0
            subview.place(
                at: CGPoint(x: isLeft ? bounds.minX : bounds.maxX, y: bounds.midY),
                anchor: isLeft ? .leading : .trailing,
                proposal: ProposedViewSize(size)
            )
        }
    }
}

// MARK: - Раскрыто

/// Раскрытая панель: тулбар в «ушах» выреза (кроме алертов) и экран из карточек.
struct ExpandedView: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor

    var body: some View {
        let notchHeight = model.geometry.notchRect.height
        let isAlert = model.route?.isAlert ?? false
        VStack(spacing: 0) {
            if isAlert {
                Color.clear.frame(height: notchHeight + 6)
            } else {
                PanelToolbar(model: model, store: store, settings: settings, review: review, resources: resources, protection: protection)
                    .frame(height: max(notchHeight, DS.Size.toolbarHeight))
                Color.clear.frame(height: 8)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                errors
                ScreenHost(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
                    // Новый экран — новое состояние формы, даже если тип тот же.
                    .id(model.route)
                    .transition(.opacity)
            }
            .padding(.horizontal, DS.Spacing.panel)
            .padding(.bottom, DS.Spacing.panel)
        }
    }

    @ViewBuilder
    private var errors: some View {
        if let error = store.lastError {
            ErrorBanner(text: error) { store.lastError = nil }
        }
        if let error = tracker.lastError {
            ErrorBanner(text: error) { tracker.lastError = nil }
        }
        if let error = resources.lastError {
            ErrorBanner(text: error) { resources.lastError = nil }
        }
        if let error = protection.lastError {
            ErrorBanner(text: error) { protection.lastError = nil }
        }
    }
}

/// Тулбар в «ушах» выреза: слева дом, советы (с числом), плюс; справа система
/// и защита (когда включены), настройки, звук. Кнопки 38×30, радиус 10.
struct PanelToolbar: View {
    let model: NotchViewModel
    let store: MoneyStore
    @Bindable var settings: AppSettings
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor

    var body: some View {
        let route = model.route
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ToolbarButton(systemImage: "house", help: L("Главная", "Home"), isActive: route == nil) { model.home() }
                ToolbarButton(systemImage: "lightbulb", help: L("Советы дня", "Daily tips"), isActive: route == .tips || route == .review, badge: tipsBadge) {
                    model.toggle(review.isRunning ? .review : .tips)
                }
                ToolbarButton(systemImage: "plus", help: L("Новая запись", "New entry"), isActive: isAdding) { add() }
            }
            Spacer(minLength: model.geometry.notchRect.width)
            HStack(spacing: 4) {
                if settings.resourcesEnabled {
                    ToolbarButton(systemImage: "gauge.with.dots.needle.33percent", help: L("Система", "System"), isActive: route == .system,
                                  badge: resources.activeAlert != nil ? .dot(DS.Tone.tips) : nil) { model.toggle(.system) }
                }
                if settings.guardEnabled {
                    ToolbarButton(systemImage: "lock.shield", help: L("Защита", "Guard"), isActive: route == .protection, badge: guardBadge) { model.toggle(.protection) }
                    if settings.guardWatchNetwork {
                        ToolbarButton(systemImage: "network", help: L("Сеть", "Network"), isActive: route == .network, badge: networkBadge) { model.toggle(.network) }
                    }
                }
                ToolbarButton(systemImage: "gearshape", help: L("Настройки", "Settings"), isActive: isSettings) { model.toggle(.settings) }
                ToolbarButton(systemImage: settings.soundEnabled ? "speaker.wave.2" : "speaker.slash", help: settings.soundEnabled ? L("Звук включён", "Sound on") : L("Звук выключен", "Sound off")) {
                    settings.soundEnabled.toggle()
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private var tipsBadge: ToolbarBadge? {
        review.newTipsCount > 0 ? .count(review.newTipsCount, DS.Tone.tips) : nil
    }

    private var guardBadge: ToolbarBadge? {
        // Тревога сети светит на своей кнопке; здесь — ключи, процессы, код, агент.
        if protection.alerts.contains(where: { $0.kind != .network }) { return .dot(DS.Tone.alarm) }
        if let wing = protection.wing { return .dot(wing.isOverdue ? DS.Tone.minus : DS.Tone.tips) }
        return nil
    }

    /// Красная точка — тревога сети ждёт ответа; жёлтая — записка за последние 10 минут.
    private var networkBadge: ToolbarBadge? {
        if protection.alerts.contains(where: { $0.kind == .network }) { return .dot(DS.Tone.alarm) }
        if protection.network.events.contains(where: { $0.level == .warning && Date().timeIntervalSince($0.at) < 600 }) { return .dot(DS.Tone.tips) }
        return nil
    }

    private var isAdding: Bool {
        switch model.route {
        case .entryForm, .projectForm: true
        default: false
        }
    }

    private var isSettings: Bool {
        switch model.route {
        case .settings, .observation, .today, .claudeSettings, .reviewPrompt: true
        default: false
        }
    }

    /// «+»: на экране проекта — трата этого проекта; без проектов — сначала проект.
    private func add() {
        if store.projects.isEmpty {
            model.show(.projectForm(editing: nil))
        } else if case .project(let id) = model.route {
            model.push(.entryForm(.new(.recurring, projectId: id)))
        } else {
            model.show(.entryForm(.new(.recurring, projectId: nil)))
        }
    }
}

/// Какой экран показать по маршруту.
struct ScreenHost: View {
    let model: NotchViewModel
    let store: MoneyStore
    let settings: AppSettings
    let tracker: ActivityTracker
    let review: ReviewService
    let resources: ResourceMonitor
    let protection: GuardMonitor

    var body: some View {
        switch model.route {
        case nil:
            HomeView(model: model, store: store, settings: settings, tracker: tracker, review: review, resources: resources, protection: protection)
        case .project(let id):
            ProjectScreen(projectId: id, model: model, store: store)
        case .projectForm(let editing):
            ProjectFormView(editingId: editing, model: model, store: store)
        case .entryForm(let target):
            EntryFormView(target: target, model: model, store: store)
        case .tips:
            TipsScreen(model: model, review: review, settings: settings)
        case .review:
            ReviewScreen(model: model, review: review)
        case .payments:
            PaymentsScreen(model: model, store: store, look: look)
        case .system:
            SideScreen(face: look.spec, phrase: SidePhrases.system(resources)) {
                SystemTab(model: model, resources: resources, settings: settings, focus: model.systemFocus)
            }
        case .protection:
            SideScreen(face: look.spec, phrase: GuardPhrase.keys(protection.keys.categories, now: protection.now, unlocksToday: protection.keys.unlocksToday)) {
                ProtectionTab(protection: protection, settings: settings)
            }
        case .network:
            SideScreen(
                face: look.spec,
                phrase: GuardPhrase.networkHeadline(protection.network, watching: protection.networkWatching, helperInstalled: protection.helper == .ready)
            ) {
                NetworkTab(model: model, protection: protection, settings: settings)
            }
        case .settings:
            SideScreen(face: look.spec, phrase: SidePhrases.notch(model)) {
                SettingsTab(model: model, settings: settings, resources: resources, protection: protection)
            }
        case .observation:
            SideScreen(face: look.spec, phrase: SidePhrases.observation(settings)) {
                ObservationTab(model: model, tracker: tracker, settings: settings)
            }
        case .today:
            SideScreen(face: look.spec, phrase: SidePhrases.today(tracker)) {
                TodayTab(tracker: tracker)
            }
        case .claudeSettings:
            SideScreen(face: .main(.squint, tone: DS.Tone.info, glasses: true), phrase: SidePhrases.claude(review)) {
                ClaudeSettingsView(model: model, review: review, settings: settings)
            }
        case .reviewPrompt:
            SideScreen(face: .main(.squint, tone: DS.Tone.info, glasses: true), phrase: L("Вот ровно то, что уходит в Claude. Сырого лога там нет.", "This is exactly what goes to Claude. No raw log.")) {
                ReviewPromptView(model: model, review: review)
            }
        case .alert(let alert):
            AlertScreen(alert: alert, model: model, store: store, resources: resources, protection: protection, settings: settings, review: review)
        }
    }

    private var look: MascotLook {
        FaceDirector.look(model: model, store: store, review: review, tracker: tracker, resources: resources, protection: protection)
    }
}

/// Ошибка записи в базу. Значок и текст: цвет один ничего не сообщает.
private struct ErrorBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Tone.tips)
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
