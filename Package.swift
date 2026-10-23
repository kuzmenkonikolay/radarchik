// swift-tools-version: 6.0
import PackageDescription

// Радарчик собирается как обычный Swift Package: `swift build` / `swift test`.
// В Radarchik.app его упаковывает Makefile (`make app`), Xcode-проект не нужен.
let package = Package(
    name: "Radarchik",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Radarchik", targets: ["Radarchik"]),
        // Root-часть «Защиты» (SPEC §3б, этап 2): ставится один раз `make install-guard`.
        .executable(name: "radarchik-guardd", targets: ["RadarchikGuardHelper"]),
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
        // libpcap из системы — root-части для «Сетевого надзора» (захват с pktap).
        .systemLibrary(name: "CPcap", path: "Sources/CPcap"),
        // Root-часть «Защиты»: от root через launchd, умеет открыть и закрыть
        // ключи из списка, подтвердить Touch ID просьбу к ssh-agent и отдать
        // новые соединения с pktap. Открыть и подтвердить — после Touch ID, который
        // она проверяет сама. Логика (смена владельца без ссылок, таймеры, журнал,
        // разбор пакетов) — в RadarchikCore и покрыта тестами; здесь XPC, авторизация,
        // файлы и цикл захвата.
        .executableTarget(
            name: "RadarchikGuardHelper",
            dependencies: ["RadarchikCore", "CPcap"]
        ),
        .testTarget(
            name: "RadarchikCoreTests",
            dependencies: ["RadarchikCore"]
        ),
    ]
)
