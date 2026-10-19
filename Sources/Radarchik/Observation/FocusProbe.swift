import AppKit
import ApplicationServices
import ScriptingBridge
import RadarchikCore

/// Узнаёт заголовок окна (Accessibility) и адрес вкладки (Apple Events)
/// активного приложения.
///
/// Работает в своей очереди с короткими таймаутами (0,5 с). Если приложение
/// подвисло, отвечать будет долго, но чёлка от этого не замрёт.
/// Состояние (кэш SBApplication) трогается только из этой очереди.
final class FocusProbe: @unchecked Sendable {
    struct Result: Sendable {
        var title: String?
        var url: String?
        /// Окно инкогнито: ни адрес, ни заголовок не читаем и не пишем.
        var isIncognito = false
    }

    private let queue = DispatchQueue(label: "dev.kuzmenko.radarchik.probe", qos: .utility)
    private var browsers: [String: SBApplication] = [:]

    func probe(pid: pid_t, bundleId: String, browser: BrowserKind?, readTitle: Bool, readURL: Bool) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = Result()
                if let browser, readURL {
                    result = self.activeTab(bundleId: bundleId, kind: browser)
                }
                if readTitle && !result.isIncognito {
                    result.title = Self.windowTitle(pid: pid)
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Accessibility: заголовок окна

    private static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &window) == .success, let window else {
            return nil
        }
        var title: CFTypeRef?
        let element = unsafeDowncast(window, to: AXUIElement.self)
        guard AXUIElementCopyAttributeValue(element, "AXTitle" as CFString, &title) == .success else { return nil }
        return title as? String
    }

    // MARK: - Apple Events: адрес вкладки

    /// Только для уже запущенного браузера: обращение к незапущенному его бы запустило.
    private func activeTab(bundleId: String, kind: BrowserKind) -> Result {
        guard kind != .firefox, let app = application(bundleId), app.isRunning else { return Result() }
        guard let windows = Self.property(app, "windows") as? SBElementArray, windows.count > 0,
              let front = windows.object(at: 0) as? SBObject
        else { return Result() }

        switch kind {
        case .chromium:
            // В инкогнито даже адрес не читаем. Chrome отдаёт `mode`, у Arc может быть `incognito`.
            if (Self.property(front, "mode") as? String) == "incognito" || (Self.property(front, "incognito") as? Bool) == true {
                return Result(isIncognito: true)
            }
            let tab = Self.property(front, "activeTab") as? SBObject
            return Result(url: tab.flatMap { Self.property($0, "URL") } as? String)
        case .safari:
            let tab = Self.property(front, "currentTab") as? SBObject
            return Result(url: tab.flatMap { Self.property($0, "URL") } as? String)
        case .firefox:
            return Result()
        }
    }

    /// Свойство из словаря AppleScript приложения — только если оно там есть.
    /// Иначе KVC бросает NSUnknownKeyException, а его Swift не ловит, и Радарчик
    /// упал бы на браузере с урезанным словарём.
    private static func property(_ object: NSObject, _ name: String) -> Any? {
        object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
    }

    private func application(_ bundleId: String) -> SBApplication? {
        if let cached = browsers[bundleId] { return cached }
        guard let app = SBApplication(bundleIdentifier: bundleId) else { return nil }
        // Таймаут в «тиках» (1/60 с): 30 — полсекунды.
        app.timeout = 30
        browsers[bundleId] = app
        return app
    }
}

/// Разрешения macOS для наблюдения.
enum Permissions {
    /// Accessibility: нужен для заголовков окон.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос и открывает нужный раздел настроек.
    static func requestAccessibility() {
        // Строка — значение kAXTrustedCheckOptionPrompt (глобальная C-переменная, в Swift 6 её не трогаем).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @MainActor
    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    enum AutomationStatus: Equatable {
        case granted
        case notAsked
        case denied
        case notRunning
    }

    /// Можно ли слать Apple Events браузеру. При `ask` macOS покажет системный
    /// запрос и будет ждать ответа, поэтому вызывать только вне главного потока.
    nonisolated static func automationStatus(bundleId: String, ask: Bool) -> AutomationStatus {
        var target = AEAddressDesc()
        let created = bundleId.withCString { pointer in
            AECreateDesc(DescType(0x6275_6E64) /* 'bund' */, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return .notRunning }
        defer { AEDisposeDesc(&target) }
        let wildcard = AEEventClass(0x2A2A_2A2A) /* '****' */
        switch AEDeterminePermissionToAutomateTarget(&target, wildcard, wildcard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .notAsked
        }
    }

    @MainActor
    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
