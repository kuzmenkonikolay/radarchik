import Darwin
import Foundation

/// Процессы этого пользователя: процессор, память и энергия по каждому (SPEC §3а).
/// Один вызов `proc_pid_rusage` на процесс отдаёт всё сразу. Чужие системные
/// процессы (root, WindowServer) macOS не отдаёт — это нормально.
///
/// Чей процесс — решает `AppIdentityResolver` по пути (внешний `.app`);
/// службы XPC без своего приложения (WebKit, виртуализация) относим к тому,
/// кто их позвал, — через приватный `responsibility_get_pid_responsible_for_pid`
/// (ищем через dlsym; нет его — служба идёт под своим именем).
/// Не потокобезопасен: в приложении живёт внутри одного актора.
public final class ProcessProbe {
    private typealias ResponsibleFor = @convention(c) (Int32) -> Int32

    /// pid → кто это, с временем запуска: pid могут переиспользовать.
    private var identities: [Int32: (startTime: UInt64, app: AppIdentity)] = [:]
    /// Путь к .app → ключ и имя: бандл читаем один раз.
    private var bundles: [String: AppIdentity] = [:]
    /// Тики mach → наносекунды. На Apple Silicon тик ≈ 41,7 нс, на Intel — 1 нс.
    private let nanosecondsPerTick: Double

    private static let responsibleFor: ResponsibleFor? = {
        // RTLD_DEFAULT — искать во всех загруженных библиотеках.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFor.self)
    }()

    /// Нашлась ли функция «кто позвал службу» (для проверки на этом маке).
    public static var canFindResponsibleProcess: Bool { responsibleFor != nil }

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }

    public func read() -> [ProcessReading] {
        var readings: [ProcessReading] = []
        var seen = Set<Int32>()
        // pid 0 — ядро, его не отдают.
        for pid in Self.allPids() where pid > 0 {
            guard let usage = Self.rusage(pid) else { continue }
            seen.insert(pid)
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            readings.append(ProcessReading(
                pid: pid,
                startTime: usage.ri_proc_start_abstime,
                app: identity(pid: pid, startTime: usage.ri_proc_start_abstime),
                cpuTimeNs: UInt64(Double(ticks) * nanosecondsPerTick),
                memoryBytes: usage.ri_phys_footprint,
                // ri_energy_nj — своя энергия процесса (проверено 2026-10-18: ~1,8 Дж
                // на 0,4 с работы ядра). ri_billed_energy на порядки меньше — запасной.
                energyNj: usage.ri_energy_nj > 0 ? usage.ri_energy_nj : usage.ri_billed_energy
            ))
        }
        identities = identities.filter { seen.contains($0.key) }
        return readings
    }

    // MARK: - Чей процесс

    private func identity(pid: Int32, startTime: UInt64) -> AppIdentity {
        if let cached = identities[pid], cached.startTime == startTime { return cached.app }
        // Путь не отдали — хотя бы короткое имя процесса.
        let app = identity(pid: pid, followResponsible: true)
            ?? AppIdentityResolver.processIdentity(Self.name(of: pid) ?? "pid \(pid)")
        identities[pid] = (startTime, app)
        return app
    }

    /// По пути: внешний .app, иначе заказчик службы XPC, иначе имя файла.
    private func identity(pid: Int32, followResponsible: Bool) -> AppIdentity? {
        guard let path = Self.path(of: pid) else { return nil }
        if let appPath = AppIdentityResolver.outermostAppBundle(inExecutablePath: path) {
            return bundleIdentity(appPath)
        }
        // Служба XPC: её память и процессор — того, кто её позвал (Safari, Docker).
        if followResponsible, AppIdentityResolver.isXPCService(path),
           let responsible = Self.responsibleFor?(pid), responsible > 0, responsible != pid,
           let owner = identity(pid: responsible, followResponsible: false), !owner.key.hasPrefix("process:") {
            return owner
        }
        return AppIdentityResolver.processIdentity((path as NSString).lastPathComponent)
    }

    private func bundleIdentity(_ appPath: String) -> AppIdentity {
        if let cached = bundles[appPath] { return cached }
        let name = FileManager.default.displayName(atPath: appPath)
        let shortName = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        let key = Bundle(path: appPath)?.bundleIdentifier ?? "app:" + appPath
        let identity = AppIdentity(key: key, name: shortName)
        bundles[appPath] = identity
        return identity
    }

    // MARK: - Системные вызовы

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // С запасом: пока спрашивали, могли запуститься новые.
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled)))
    }

    /// Всё о процессе одним вызовом; nil — процесс чужой или уже завершился.
    static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func name(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
