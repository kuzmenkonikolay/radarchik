// swift-tools-version: 6.0
import PackageDescription

// Радарчик собирается как обычный Swift Package: `swift build` / `swift test`.
// В Radarchik.app его упаковывает Makefile (`make app`), Xcode-проект не нужен.
let package = Package(
    name: "Radarchik",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Radarchik", targets: ["Radarchik"]),
    ],
    targets: [
        // Логика без UI: деньги, форматирование, фраза Радарчика, хранение
        // в SQLite, геометрия чёлки, выбор состояния маскота, ресурсы мака.
        // Вся покрыта тестами. IOKit — батарея и датчики температуры (этап 6).
        .target(
            name: "RadarchikCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOKit")]
        ),
        // Само приложение: панель над чёлкой, SwiftUI-экраны, маскот.
        .executableTarget(
            name: "Radarchik",
            dependencies: ["RadarchikCore"]
        ),
        .testTarget(
            name: "RadarchikCoreTests",
            dependencies: ["RadarchikCore"]
        ),
    ]
)
