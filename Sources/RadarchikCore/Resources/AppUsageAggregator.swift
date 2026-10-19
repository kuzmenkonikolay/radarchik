import Foundation

/// Чьё это: путь процесса → приложение. Сами системные вызовы — в `ProcessProbe`,
/// здесь только правила, чтобы их можно было проверить тестами.
///
/// Главное правило — внешний `.app` в пути: помощники Chrome лежат внутри
/// Google Chrome.app, значит, их память и процессор — это Chrome. Процессы
/// без бандла (node, postgres) идут под своим именем.
public enum AppIdentityResolver {
    /// Внешняя папка `.app` в пути исполняемого файла; nil — процесс не из приложения.
    public static func outermostAppBundle(inExecutablePath path: String) -> String? {
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    /// Служба XPC без своего приложения (WebKit, виртуализация): её «ест» тот,
    /// кто её позвал, — Safari, Docker. Его ищет `ProcessProbe`.
    public static func isXPCService(_ path: String) -> Bool {
        path.contains(".xpc/")
    }

    /// Процесс без бандла — группа по имени исполняемого файла.
    public static func processIdentity(_ executable: String) -> AppIdentity {
        AppIdentity(key: "process:" + executable, name: friendlyNames[executable] ?? executable)
    }

    /// Понятные имена системных служб, если не нашлось, чьи они.
    private static var friendlyNames: [String: String] {
        [
            "com.apple.Virtualization.VirtualMachine": L("Виртуальная машина", "Virtual machine"),
            "com.apple.WebKit.WebContent": L("Веб-страницы (WebKit)", "Web pages (WebKit)"),
            "com.apple.WebKit.GPU": L("Графика веб-страниц (WebKit)", "Web page graphics (WebKit)"),
            "com.apple.WebKit.Networking": L("Сеть веб-страниц (WebKit)", "Web page networking (WebKit)"),
        ]
    }
}

/// Складывает процессы по приложениям.
public enum AppUsageAggregator {
    /// Процессор и энергия — по разнице с прошлым замером того же процесса
    /// (тот же pid и то же время запуска), память — как есть сейчас.
    /// У нового процесса процессор начнёт считаться со следующего замера.
    public static func usage(previous: [ProcessReading], current: [ProcessReading], seconds: TimeInterval) -> [AppUsage] {
        guard seconds > 0 else { return [] }
        var before: [Int32: ProcessReading] = [:]
        for reading in previous { before[reading.pid] = reading }

        var apps: [String: AppUsage] = [:]
        for reading in current {
            var usage = apps[reading.app.key] ?? AppUsage(app: reading.app, cpuPercent: 0, memoryBytes: 0, powerWatts: 0, processCount: 0)
            usage.memoryBytes += reading.memoryBytes
            usage.processCount += 1
            if let old = before[reading.pid], old.startTime == reading.startTime {
                // Счётчики только растут; если нет — считаем, что процесс не работал.
                let cpu = reading.cpuTimeNs > old.cpuTimeNs ? reading.cpuTimeNs - old.cpuTimeNs : 0
                let energy = reading.energyNj > old.energyNj ? reading.energyNj - old.energyNj : 0
                usage.cpuPercent += Double(cpu) / (seconds * 1e9) * 100
                usage.powerWatts += Double(energy) / 1e9 / seconds
            }
            apps[reading.app.key] = usage
        }
        return apps.values.sorted { $0.app.key < $1.app.key }
    }
}
