import CoreGraphics

/// Где на экране вырез, или где рисовать виртуальную чёлку.
///
/// Чистая функция от параметров `NSScreen`, чтобы её можно было тестировать
/// без настоящего экрана. Координаты — как в AppKit: начало внизу слева.
public struct NotchGeometry: Equatable, Sendable {
    /// Прямоугольник выреза в координатах экрана.
    public let notchRect: CGRect
    /// true — настоящая чёлка; false — виртуальная (внешний монитор, мак без выреза).
    public let isHardware: Bool

    /// Ширина виртуальной чёлки — примерно как настоящая у MacBook Pro 14".
    public static let virtualWidth: CGFloat = 186

    public init(notchRect: CGRect, isHardware: Bool) {
        self.notchRect = notchRect
        self.isHardware = isHardware
    }

    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame`
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top` — высота выреза, 0 если его нет
    ///   - leftAreaWidth / rightAreaWidth: ширины `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
    ///   - menuBarHeight: высота строки меню — для виртуальной чёлки
    public static func compute(
        screenFrame: CGRect, safeAreaTop: CGFloat,
        leftAreaWidth: CGFloat?, rightAreaWidth: CGFloat?, menuBarHeight: CGFloat
    ) -> NotchGeometry {
        // Вырез — это всё, что между «ушами» строки меню слева и справа.
        if safeAreaTop > 0, let left = leftAreaWidth, let right = rightAreaWidth {
            let width = screenFrame.width - left - right
            if width > 0 {
                return NotchGeometry(
                    notchRect: CGRect(x: screenFrame.minX + left, y: screenFrame.maxY - safeAreaTop, width: width, height: safeAreaTop),
                    isHardware: true
                )
            }
        }
        // Выреза нет — рисуем свой по центру верхнего края, высотой со строку меню.
        let height = max(menuBarHeight, 24)
        return NotchGeometry(
            notchRect: CGRect(x: screenFrame.midX - virtualWidth / 2, y: screenFrame.maxY - height, width: virtualWidth, height: height),
            isHardware: false
        )
    }
}
