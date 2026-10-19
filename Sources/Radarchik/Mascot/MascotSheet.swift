import AppKit
import SwiftUI
import RadarchikCore

/// Лист со всеми обликами и состояниями в реальном размере чёлки — для выбора
/// персонажа и для моей проверки рисовки (я экран не вижу, а PNG — вижу).
///
/// Запуск: `.build/debug/Radarchik --render-mascots <папка>` — рисует и выходит,
/// панель не создаётся.
@MainActor
enum MascotSheetRenderer {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func render(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(MascotSheet(skins: MascotSkin.allCases), to: folder.appendingPathComponent("mascots.png"))
        for skin in MascotSkin.allCases {
            try write(MascotSheet(skins: [skin]), to: folder.appendingPathComponent("mascot-\(skin.rawValue).png"))
        }
        try write(SystemSheet(), to: folder.appendingPathComponent("system.png"))
    }

    private static func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(description: "не отрисовалось: \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}

struct MascotSheet: View {
    var skins: [MascotSkin]

    /// Размер выреза MacBook Pro 14" в pt.
    private let notch = CGSize(width: 185, height: 32)

    private let collapsedCases: [(MascotState, AntennaSignal, String)] = [
        (.idleScan, .green, "в плюсе, растём"),
        (.idleScan, .orange, "в минусе"),
        (.idleScan, .tipsReady, "готовы советы"),
        (.sleep, .blue, "спит"),
    ]

    private let expandedCases: [(MascotState, AntennaSignal, String)] = [
        (.peek, .blue, "выглянул"),
        (.happy, .green, "растём"),
        (.worried, .yellow, "проседаем"),
        (.nervous, .orange, "в минусе"),
        (.tipWave, .blue, "советы"),
        (.catchCoin, .green, "доход"),
        (.sleep, .dim, "спит"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(skins) { skin in
                if skin == .livingNotch {
                    LivingNotchSheet(notch: notch)
                } else {
                    classic(skin)
                }
            }
        }
        .padding(28)
        .background(Color(hex: "#1C1C1E"))
    }

    /// Запасные облики: подбородок и портрет по отдельности, как раньше.
    private func classic(_ skin: MascotSkin) -> some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text(skin.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Свёрнуто — как в чёлке, поверх строки меню и окна")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(Array(collapsedCases.enumerated()), id: \.offset) { _, item in
                            captioned(item.2) { collapsed(skin: skin, state: item.0, signal: item.1) }
                        }
                    }
                    Text("Раскрыто — в реальном размере")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(expandedCases.enumerated()), id: \.offset) { _, item in
                            captioned(item.2) {
                                MascotPortrait(skin: skin, state: item.0, signal: item.1, gaze: CGPoint(x: 0.4, y: 0.2))
                                    .frame(width: 72, height: 72)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 16).fill(.black))
                            }
                        }
                    }
                }
    }

    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 6) {
            content()
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
    }

    /// Кусочек экрана: строка меню, под ней окно, по центру — вырез и наша чёлка.
    private func collapsed(skin: MascotSkin, state: MascotState, signal: AntennaSignal) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex: "#3A3A3C")).frame(height: notch.height)
                Rectangle().fill(Color(hex: "#ECECEC")).frame(height: 34)
            }
            // Фигура — по размеру вида, как в панели.
            CollapsedMascot(skin: skin, state: state, signal: signal, notchSize: notch)
                .background(NotchShape.collapsed(skin: skin, notchHeight: notch.height).fill(.black))
        }
        .frame(width: 300, height: notch.height + 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Живая чёлка — так, как её собирает панель: фигура и лицо поверх.
private struct LivingNotchSheet: View {
    let notch: CGSize

    private let collapsedCases: [(MascotState, AntennaSignal, String)] = [
        (.idleScan, .green, "в плюсе, растём"),
        (.idleScan, .orange, "в минусе"),
        (.idleScan, .tipsReady, "готовы советы"),
        (.sleep, .blue, "спит"),
        (.onCall, .green, "звонок"),
    ]

    private let summaryCases: [(MascotState, AntennaSignal, String)] = [
        (.peek, .blue, "выглянула"),
        (.happy, .green, "растём"),
        (.worried, .yellow, "проседаем"),
        (.nervous, .orange, "в минусе"),
        (.tipWave, .blue, "советы"),
        (.catchCoin, .green, "доход"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MascotSkin.livingNotch.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            caption("Свёрнуто — как в чёлке, поверх строки меню и окна. Пунктир — граница выреза")
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(collapsedCases.enumerated()), id: \.offset) { _, item in
                    labeled(item.2) {
                        onScreen(width: 250, height: 80) {
                            LivingNotchMock(state: item.0, signal: item.1, progress: 0, notch: notch)
                        }
                    }
                }
            }

            caption("Свёрнуто с цифрами по бокам: слева деньги, справа система")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    labeled("деньги и система") {
                        onScreen(width: 560, height: 70) { WingsMock(leading: SheetData.money, trailing: SheetData.systemWings, notch: notch) }
                    }
                    labeled("только к оплате и система") {
                        onScreen(width: 560, height: 70) { WingsMock(leading: [SheetData.money[0]], trailing: SheetData.systemWings, notch: notch) }
                    }
                }
                HStack(alignment: .top, spacing: 20) {
                    labeled("проектов нет — система на оба крыла") {
                        onScreen(width: 560, height: 70) {
                            let wings = WingItem.arrange(money: [], system: SheetData.systemWings)
                            WingsMock(leading: wings.leading, trailing: wings.trailing, notch: notch)
                        }
                    }
                    labeled("слежение выключено — деньги как раньше") {
                        onScreen(width: 560, height: 70) {
                            let wings = WingItem.arrange(money: SheetData.money, system: [])
                            WingsMock(leading: wings.leading, trailing: wings.trailing, notch: notch)
                        }
                    }
                }
            }

            caption("Раскрытие — стоп-кадры одной анимации, вдвое меньше")
            HStack(alignment: .top, spacing: 12) {
                ForEach([0, 0.25, 0.5, 0.75, 1] as [CGFloat], id: \.self) { progress in
                    labeled("\(Int(progress * 100))%") {
                        halfSize {
                            onScreen(width: 520, height: 230) {
                                LivingNotchMock(state: progress < 0.5 ? .idleScan : .happy, signal: .green, progress: progress, notch: notch)
                            }
                        }
                    }
                }
            }

            caption("Сводка — верх панели в реальном размере")
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(summaryCases.enumerated()), id: \.offset) { _, item in
                    labeled(item.2) {
                        LivingNotchMock(state: item.0, signal: item.1, progress: 1, notch: notch, gaze: CGPoint(x: 0.4, y: 0.3))
                            .overlay(alignment: .top) { notchOutline }
                            .frame(width: 210, height: notch.height + FacePlacement.hero.contentTop + 34, alignment: .top)
                            .clipped()
                    }
                }
            }

            caption("Тревога (этап 6): записка под свёрнутой чёлкой и облачко с кнопками на сводке")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    onScreen(width: 420, height: 100) {
                        AnnouncementMock(alert: SheetData.memoryAlert, notch: notch)
                    }
                    onScreen(width: 420, height: 100) {
                        AnnouncementMock(alert: SheetData.batteryAlert, notch: notch)
                    }
                }
                LivingNotchMock(state: .worried, signal: .green, progress: 1, notch: notch, screen: .alert(SheetData.batteryAlert))
                    .overlay(alignment: .top) { notchOutline }
            }

            caption("Внутренний экран — глаза уходят в подбородок")
            HStack(alignment: .top, spacing: 20) {
                LivingNotchMock(state: .happy, signal: .green, progress: 1, notch: notch, screen: .form)
                    .overlay(alignment: .top) { notchOutline }
                LivingNotchMock(state: .happy, signal: .green, progress: 1, notch: notch)
                    .overlay(alignment: .top) { notchOutline }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.gray)
    }

    private func labeled(_ text: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 6) {
            content()
            Text(text).font(.system(size: 10)).foregroundStyle(.gray)
        }
    }

    /// Кусочек экрана: строка меню, под ней окно, по центру — чёлка.
    private func onScreen(width: CGFloat, height: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(Color(hex: "#3A3A3C")).frame(height: notch.height)
                Rectangle().fill(Color(hex: "#ECECEC"))
            }
            content()
            notchOutline
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func halfSize(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .scaleEffect(0.5, anchor: .topLeading)
            .frame(width: 260, height: 115, alignment: .topLeading)
    }

    /// Где кончается настоящий вырез: под ним пикселей нет.
    private var notchOutline: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
            .stroke(style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            .foregroundStyle(.white.opacity(0.35))
            .frame(width: notch.width, height: notch.height)
    }
}

/// Макет панели Живой чёлки без моделей: фигура, лицо и содержимое экрана.
/// `progress` 0 — свёрнута, 1 — раскрыта. Промежуточные значения — стоп-кадры
/// раскрытия: интерполируется всё то же, что пружина в `NotchRootView`
/// (размер фигуры, подбородок, размер и место лица, проявление содержимого).
struct LivingNotchMock: View {
    enum Screen {
        case summary
        case form
        /// Сводка с тревогой о ресурсах вместо фразы о деньгах.
        case alert(ResourceAlert)

        var isSummary: Bool {
            switch self {
            case .summary, .alert: true
            case .form: false
            }
        }
    }

    var state: MascotState
    var signal: AntennaSignal
    var progress: CGFloat
    var notch: CGSize
    var gaze: CGPoint = .zero
    var screen: Screen = .summary

    var body: some View {
        let p = progress
        let bump = MascotSkin.livingNotch.bump
        let start = FacePlacement.chin
        let target: FacePlacement = screen.isSummary ? .hero : .chin
        let contentHeight: CGFloat = switch screen {
        case .summary: 116
        case .form: 124
        case .alert: 150
        }
        let width = lerp(notch.width, DS.Size.expandedWidth, p)
        let height = lerp(notch.height + bump.height, notch.height + target.contentTop + contentHeight, p)
        let shape = interpolatedShape(p)
        ZStack(alignment: .top) {
            shape.fill(.black)
            content
                .frame(width: DS.Size.expandedWidth - 2 * DS.Spacing.md)
                .padding(.top, notch.height + target.contentTop)
                .opacity(p)
            PlacedLivingFace(
                state: state,
                signal: signal,
                gaze: gaze,
                scale: lerp(start.scale, target.scale, p),
                eyeCenterY: lerp(start.eyeCenterY(notchHeight: notch.height), target.eyeCenterY(notchHeight: notch.height), p)
            )
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(shape)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .summary:
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                SpeechBubble(text: "Сентябрь закрыли в плюсе: +48к ₽. Так держать!", footnote: "Октябрь пока: +12к ₽", pointsUp: true)
                HStack(spacing: 6) {
                    ForEach(["Проект А", "Проект Б", "Проект В"], id: \.self) { mockChip($0) }
                }
            }
        case .form:
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                PanelHeader(title: "Новая трата", onBack: {})
                FormRow("Сумма") { mockField("990 ₽") }
                FormRow("Проект") { mockField("Проект А") }
            }
        case .alert(let alert):
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                AlertBubble(alert: alert, more: 1, pointsUp: true, onShow: {}, onNormal: {}, onLater: {})
                HStack(spacing: 6) {
                    ForEach(["Проект А", "Проект Б", "Проект В"], id: \.self) { mockChip($0) }
                }
            }
        }
    }

    private func mockChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Surface.card))
    }

    /// Настоящий TextField в картинку не рисуется (он из AppKit) — подложка с текстом.
    private func mockField(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field).fill(DS.Surface.field))
    }

    /// Та же интерполяция, что делает SwiftUI: между двумя крайними формами.
    private func interpolatedShape(_ p: CGFloat) -> NotchShape {
        var shape = NotchShape.collapsed(skin: .livingNotch, notchHeight: notch.height)
        var delta = NotchShape.expanded(notchHeight: notch.height).animatableData - shape.animatableData
        delta.scale(by: Double(p))
        shape.animatableData += delta
        return shape
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

/// Свёрнутая чёлка с крыльями — так, как её собирает панель: фигура по размеру вида и лицо.
private struct WingsMock: View {
    let leading: [WingItem]
    let trailing: [WingItem]
    let notch: CGSize

    var body: some View {
        CollapsedMascot(skin: .livingNotch, state: .idleScan, signal: .green, notchSize: notch, leading: leading, trailing: trailing)
            .background(NotchShape.collapsed(skin: .livingNotch, notchHeight: notch.height).fill(.black))
            .overlay(alignment: .top) {
                PlacedLivingFace(state: .idleScan, signal: .green, scale: 1, eyeCenterY: FacePlacement.chin.eyeCenterY(notchHeight: notch.height))
            }
    }
}

/// Записка о тревоге — так, как её собирает панель: фигура, фраза и лицо в подбородке.
private struct AnnouncementMock: View {
    let alert: ResourceAlert
    let notch: CGSize

    var body: some View {
        let shape = NotchShape.announcement(notchHeight: notch.height)
        AnnouncementView(alert: alert, skin: .livingNotch, notchHeight: notch.height)
            .background(shape.fill(.black))
            .overlay(alignment: .top) {
                PlacedLivingFace(state: .worried, signal: .green, scale: 1, eyeCenterY: FacePlacement.chin.eyeCenterY(notchHeight: notch.height))
            }
            .clipShape(shape)
    }
}

/// Экран «Система» на выдуманных данных — проверить раскладку глазами.
/// Переключатель вкладок — из AppKit, в картинку он не рисуется (пустая полоса).
private struct SystemSheet: View {
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            panel(focus: nil)
            panel(focus: SystemFocus(metric: .memory, appKey: "com.google.Chrome"))
        }
        .padding(28)
        .background(Color(hex: "#1C1C1E"))
        .environment(\.colorScheme, .dark)
    }

    private func panel(focus: SystemFocus?) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            PanelHeader(title: "Система", onBack: {}) {
                PillButton("Мониторинг системы", systemImage: "arrow.up.right") {}
            }
            SystemScreen(
                system: SheetData.system, apps: SheetData.apps, history: SheetData.history,
                recent: SheetData.recent, normsCount: 0, focus: focus
            )
        }
        .padding(DS.Spacing.md)
        .frame(width: DS.Size.expandedWidth)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(.black))
    }
}

/// Выдуманные данные для листа: мак на 48 ГБ, Chrome разъелся, батарея садится.
private enum SheetData {
    static let gib = 1_073_741_824.0
    /// От «сейчас»: в облачке видно «держится 12 мин», как в жизни.
    static var now: Date { Date() }
    static let chrome = AppIdentity(key: "com.google.Chrome", name: "Google Chrome")

    /// Крылья свёрнутой чёлки: деньги и система.
    static let money = [
        WingItem(id: "due", icon: "creditcard", text: "4к\u{00A0}₽"),
        WingItem(id: "net", text: "+46,8к\u{00A0}₽", color: DS.Money.positiveText),
    ]
    static let systemWings = [
        WingItem(id: "cpu", icon: "cpu", text: "23%", widest: "88%"),
        WingItem(id: "temperature", icon: "thermometer.medium", text: "48°", widest: "88°"),
    ]

    static let memoryAlert = ResourceAlert(
        id: 1, kind: .memory, app: chrome, value: 4.1 * gib, usual: 1.4 * gib, startedAt: now - 420, createdAt: now,
        title: ResourcePhrase.memory(app: "Google Chrome", bytes: 4.1 * gib, usual: 1.4 * gib, totalBytes: 48 * gib),
        detail: nil, status: .active, statusChangedAt: nil
    )
    static let batteryAlert = ResourceAlert(
        id: 2, kind: .battery, app: nil, value: 24, usual: 9.6, startedAt: now - 720, createdAt: now,
        title: ResourcePhrase.battery(rate: 24, usual: 9.6), detail: "Больше всех ест Google Chrome",
        status: .active, statusChangedAt: nil
    )

    static let system = SystemSnapshot(
        at: now, cpuPercent: 23.4,
        memory: MemoryReading(usedBytes: UInt64(31 * gib), totalBytes: UInt64(48 * gib), pressure: .normal),
        battery: BatteryReading(level: 76, isCharging: false, onAC: false, amperage: -900, capacityMah: 8811, minutesLeft: 430),
        drainRate: 10.2, temperature: 48, thermal: .nominal
    )

    static let apps: [AppUsageRow] = [
        row("com.google.Chrome", "Google Chrome", cpu: 85, memory: 4.1, power: 2.1, usual: (5, 1.4, 0.8)),
        row("process:node", "node", cpu: 98, memory: 0.3, power: 1.5, usual: nil),
        row("com.docker.docker", "Docker", cpu: 40, memory: 6, power: 1.2, usual: (30, 3, 1)),
        row("com.apple.dt.Xcode", "Xcode", cpu: 12, memory: 2.5, power: 0.6, usual: nil),
        row("company.thebrowser.Browser", "Arc", cpu: 8, memory: 1.8, power: 0.4, usual: nil),
        row("dev.kuzmenko.radarchik", "Радарчик", cpu: 0.4, memory: 0.06, power: 0.02, usual: nil),
    ]

    /// Час процессора: спокойно, потом сборка.
    static let history: [SystemMinute] = (0..<60).map { minute in
        let start = now - Double(59 - minute) * 60
        let cpu = minute > 40 && minute < 50 ? 70 + Double(minute % 3) * 6 : 15 + 8 * sin(Double(minute) / 5)
        return SystemMinute(
            start: start, cpu: cpu, memoryUsed: (26 + Double(minute) / 12) * gib, pressure: .normal,
            batteryLevel: 86 - Double(minute) / 6, onBattery: true, drainRate: 10, temperature: 45, thermal: .nominal
        )
    }

    static let recent = [
        ResourceAlert(
            id: 3, kind: .cpu, app: AppIdentity(key: "process:node", name: "node"), value: 98, usual: nil,
            startedAt: now - 5_400, createdAt: now - 4_800, title: "node ест 98% процессора — целое ядро",
            detail: nil, status: .resolved, statusChangedAt: now - 4_000
        ),
        ResourceAlert(
            id: 4, kind: .memory, app: AppIdentity(key: "com.docker.docker", name: "Docker"), value: 13 * gib, usual: nil,
            startedAt: now - 9_000, createdAt: now - 8_400, title: ResourcePhrase.memory(app: "Docker", bytes: 13 * gib, usual: nil, totalBytes: 48 * gib),
            detail: nil, status: .normal, statusChangedAt: now - 8_300
        ),
    ]

    private static func row(_ key: String, _ name: String, cpu: Double, memory: Double, power: Double, usual: (Double, Double, Double)?) -> AppUsageRow {
        AppUsageRow(
            usage: AppUsage(app: AppIdentity(key: key, name: name), cpuPercent: cpu, memoryBytes: UInt64(memory * gib), powerWatts: power, processCount: 1),
            usualCPU: usual?.0, usualMemory: usual.map { $0.1 * gib }, usualPower: usual?.2
        )
    }
}
