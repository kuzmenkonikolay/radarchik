import Foundation
import RadarchikCore

/// Фоновая половина ресурсов мака: системные вызовы, подсчёт норм и база —
/// не на главном потоке, чтобы чёлка не подтормаживала. Наружу отдаёт
/// только готовое состояние (`ResourceState`), его показывает `ResourceMonitor`.
actor ResourceWorker {
    private let engine: ResourceEngine
    private let systemProbe = SystemProbe()
    private let processProbe = ProcessProbe()
    /// Та же база, что у движка, — для списка прошлых тревог на экране «Система».
    private let repository: ResourceRepository

    init(databasePath: String) throws {
        let repository = try ResourceRepository(database: Database(path: databasePath))
        self.repository = repository
        self.engine = ResourceEngine(repository: repository)
    }

    /// Замер мака целиком, а если `includeProcesses` — ещё и всех процессов.
    func sample(includeProcesses: Bool) -> ResourceState {
        let now = Date()
        var created = engine.ingest(system: systemProbe.read(now: now), at: now)
        if includeProcesses {
            created += engine.ingest(processes: processProbe.read(), at: now)
        }
        return engine.state(newAlerts: created)
    }

    func respond(to alertId: Int64, with status: AlertStatus) -> ResourceState {
        engine.respond(to: alertId, with: status, at: Date())
        return engine.state()
    }

    /// Тревоги за сутки, новые первыми — нижний блок экрана «Система».
    func recentAlerts() -> [ResourceAlert] {
        let alerts = (try? repository.alerts(since: Date().addingTimeInterval(-86_400))) ?? []
        return alerts.reversed()
    }
}
