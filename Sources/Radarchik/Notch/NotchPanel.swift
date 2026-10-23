import AppKit

/// Окно над строкой меню: без рамки, прозрачное, на всех рабочих столах
/// и поверх полноэкранных приложений.
///
/// `nonactivatingPanel` позволяет ей забирать клавиатуру для форм,
/// не активируя приложение: строка меню остаётся от того, в чём ты работал.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Выше строки меню и её значков, иначе она перекроет раскрытую чёлку и
        // заберёт клики по тулбару в верхних 39 pt. `isFloatingPanel` не трогаем:
        // он молча сбрасывает уровень на `.floating`.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        // Ключевой панель становится только при клике в поле ввода (или явно для форм).
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NotchPanel создаётся только кодом")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z / ⇧⌘Z в полях ввода.
    ///
    /// В обычных приложениях их обрабатывает меню «Правка», а у Радарчика меню
    /// нет (accessory-приложение), поэтому без этого не вставлялся ключ Claude
    /// (2026-10-18). Клавиши сравниваем по коду, а не по букве: на русской
    /// раскладке ⌘V приходит как «м».
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector? = switch (event.keyCode, flags) {
        case (7, .command): #selector(NSText.cut(_:))         // X
        case (8, .command): #selector(NSText.copy(_:))        // C
        case (9, .command): #selector(NSText.paste(_:))       // V
        case (0, .command): #selector(NSText.selectAll(_:))   // A
        case (6, .command): Selector(("undo:"))               // Z
        case (6, [.command, .shift]): Selector(("redo:"))     // ⇧Z
        default: nil
        }
        if event.type == .keyDown, let action, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// AppKit не пускает окна выше строки меню: при показе он сдвигает их вниз
    /// на её высоту. Так панель и уехала под строку меню (скриншот 2026-10-18).
    /// Чёлке нужно стоять у самого верхнего края, поэтому рамку не ограничиваем.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
