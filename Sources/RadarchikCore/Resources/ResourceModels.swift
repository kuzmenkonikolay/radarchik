import Foundation

// Модели этапа 6 «Ресурсы мака» (SPEC §3а). Сырые показания приходят из
// `SystemProbe` и `ProcessProbe`, всё остальное считает `ResourceEngine`.

/// Кто ест ресурсы: приложение (по bundle id) или процесс без бандла (node, postgres).
public struct AppIdentity: Hashable, Sendable {
    /// bundle id или «process:<имя>» — по нему копятся нормы.
    public let key: String
    /// Как показывать: «Google Chrome», «node».
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// Один процесс в момент замера. Счётчики накопительные — с запуска процесса.
public struct ProcessReading: Sendable, Equatable {
    public let pid: Int32
    /// Когда процесс запущен (mach-время): отличает новый процесс со старым pid.
    public let startTime: UInt64
    public let app: AppIdentity
    /// Время процессора, user + system, наносекунды.
    public let cpuTimeNs: UInt64
    /// «Память», как в Мониторинге системы (phys_footprint), байты.
    public let memoryBytes: UInt64
    /// Израсходованная энергия, наноджоули.
    public let energyNj: UInt64

    public init(pid: Int32, startTime: UInt64, app: AppIdentity, cpuTimeNs: UInt64, memoryBytes: UInt64, energyNj: UInt64) {
        self.pid = pid
        self.startTime = startTime
        self.app = app
        self.cpuTimeNs = cpuTimeNs
        self.memoryBytes = memoryBytes
        self.energyNj = energyNj
    }
}

/// Сколько ест приложение (все его процессы вместе) между двумя замерами.
public struct AppUsage: Sendable, Equatable {
    public let app: AppIdentity
    /// % одного ядра, как в Мониторинге системы: 200% — два ядра целиком.
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    /// Средняя мощность, Вт.
    public var powerWatts: Double
    public var processCount: Int

    public init(app: AppIdentity, cpuPercent: Double, memoryBytes: UInt64, powerWatts: Double, processCount: Int) {
        self.app = app
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.powerWatts = powerWatts
        self.processCount = processCount
    }
}

/// Счётчики одного ядра с загрузки мака, в тиках. 32-битные — могут переполниться.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Давление памяти, как его видит macOS: хватает, впритык, не хватает.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MemoryReading: Sendable, Equatable {
    /// «Использовано», как в Мониторинге системы.
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let pressure: MemoryPressure

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressure = pressure
    }
}

public struct BatteryReading: Sendable, Equatable {
    /// Заряд, 0–100.
    public var level: Double
    public var isCharging: Bool
    /// Подключено питание. Зарядки может и не быть: батарея полная или «оптимизированная зарядка».
    public var onAC: Bool
    /// Ток, мА: минус — разряжается. nil — батарея не сказала.
    public var amperage: Double?
    /// Ёмкость сейчас, мА·ч: чтобы пересчитать ток в проценты в час.
    public var capacityMah: Double?
    /// Сколько осталось по оценке macOS, минуты; nil — ещё считает.
    public var minutesLeft: Int?

    public init(level: Double, isCharging: Bool, onAC: Bool, amperage: Double?, capacityMah: Double?, minutesLeft: Int?) {
        self.level = level
        self.isCharging = isCharging
        self.onAC = onAC
        self.amperage = amperage
        self.capacityMah = capacityMah
        self.minutesLeft = minutesLeft
    }
}

/// `ProcessInfo.thermalState`: норма / тепло / горячо / критично.
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Мак целиком в один момент, как его отдали системные вызовы.
public struct SystemReading: Sendable, Equatable {
    /// По ядрам, накопительно: проценты считаются по разнице с прошлым замером.
    public var cpuTicks: [CPUTicks]
    public var memory: MemoryReading?
    /// nil — батареи нет (настольный мак).
    public var battery: BatteryReading?
    /// Температура чипа, °C; nil — датчики недоступны, остаётся `thermal`.
    public var temperature: Double?
    public var thermal: ThermalLevel

    public init(cpuTicks: [CPUTicks], memory: MemoryReading?, battery: BatteryReading?, temperature: Double?, thermal: ThermalLevel) {
        self.cpuTicks = cpuTicks
        self.memory = memory
        self.battery = battery
        self.temperature = temperature
        self.thermal = thermal
    }
}

/// Мак целиком сейчас — для строки при наведении и экрана «Система».
public struct SystemSnapshot: Sendable, Equatable {
    public let at: Date
    /// Весь процессор, 0–100.
    public let cpuPercent: Double
    public let memory: MemoryReading?
    public let battery: BatteryReading?
    /// Скорость разряда, % в час; nil — не на батарее.
    public let drainRate: Double?
    public let temperature: Double?
    public let thermal: ThermalLevel

    public init(at: Date, cpuPercent: Double, memory: MemoryReading?, battery: BatteryReading?, drainRate: Double?, temperature: Double?, thermal: ThermalLevel) {
        self.at = at
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.battery = battery
        self.drainRate = drainRate
        self.temperature = temperature
        self.thermal = thermal
    }
}

/// Сводка приложения за пятиминутку: из таких копится норма за неделю.
public struct AppUsageBucket: Sendable, Equatable {
    public let start: Date
    public let app: AppIdentity
    public let cpuAvg: Double
    public let cpuMax: Double
    public let memoryAvg: Double
    public let memoryMax: Double
    public let powerAvg: Double
    /// Сколько замеров попало в пятиминутку.
    public let samples: Int

    public init(start: Date, app: AppIdentity, cpuAvg: Double, cpuMax: Double, memoryAvg: Double, memoryMax: Double, powerAvg: Double, samples: Int) {
        self.start = start
        self.app = app
        self.cpuAvg = cpuAvg
        self.cpuMax = cpuMax
        self.memoryAvg = memoryAvg
        self.memoryMax = memoryMax
        self.powerAvg = powerAvg
        self.samples = samples
    }
}

/// Мак целиком за минуту: точка графика за час и материал для нормы разряда.
public struct SystemMinute: Sendable, Equatable {
    public let start: Date
    public let cpu: Double
    public let memoryUsed: Double?
    /// Худшее за минуту.
    public let pressure: MemoryPressure
    public let batteryLevel: Double?
    /// Всю минуту на батарее.
    public let onBattery: Bool
    public let drainRate: Double?
    public let temperature: Double?
    /// Худшее за минуту.
    public let thermal: ThermalLevel

    public init(start: Date, cpu: Double, memoryUsed: Double?, pressure: MemoryPressure, batteryLevel: Double?, onBattery: Bool, drainRate: Double?, temperature: Double?, thermal: ThermalLevel) {
        self.start = start
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.pressure = pressure
        self.batteryLevel = batteryLevel
        self.onBattery = onBattery
        self.drainRate = drainRate
        self.temperature = temperature
        self.thermal = thermal
    }
}

/// Медиана и p95 за неделю. Ненадёжная — данных ещё мало: тогда только абсолютные пороги.
public struct UsageNorm: Sendable, Equatable {
    public let median: Double
    public let p95: Double
    /// Сколько пятиминуток (или минут для батареи) легло в норму.
    public let samples: Int
    /// В скольки разных днях они были.
    public let days: Int
    public let isReliable: Bool

    public init(median: Double, p95: Double, samples: Int = 100, days: Int = 7, isReliable: Bool = true) {
        self.median = median
        self.p95 = p95
        self.samples = samples
        self.days = days
        self.isReliable = isReliable
    }

    /// nil — значений нет вовсе.
    public init?(values: [Double], days: Int, minimumSamples: Int, minimumDays: Int) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        self.init(
            median: Quantile.of(sorted, 0.5),
            p95: Quantile.of(sorted, 0.95),
            samples: sorted.count,
            days: days,
            isReliable: sorted.count >= minimumSamples && days >= minimumDays
        )
    }
}

/// Нормы одного приложения.
public struct AppNorms: Sendable, Equatable {
    public let cpu: UsageNorm
    public let memory: UsageNorm
    public let power: UsageNorm

    public init(cpu: UsageNorm, memory: UsageNorm, power: UsageNorm) {
        self.cpu = cpu
        self.memory = memory
        self.power = power
    }
}

/// Что именно больше обычного.
public enum ResourceKind: String, Sendable, CaseIterable {
    /// Приложение грузит процессор.
    case cpu
    /// Приложение держит много памяти.
    case memory
    /// Батарея садится быстрее обычного.
    case battery
    /// Памяти маку не хватает.
    case pressure
    /// Мак перегрелся.
    case thermal

    /// Про мак целиком, а не про одно приложение.
    public var isSystemWide: Bool { self == .battery || self == .pressure || self == .thermal }
}

public enum AlertStatus: String, Sendable {
    /// Висит в чёлке, пока не ответишь или пока не пройдёт.
    case active
    /// «Позже».
    case later
    /// «Это нормально» — норма поднята.
    case normal
    /// Прошло само.
    case resolved
}

/// Тревога «больше обычного»: что, у кого, сколько и что Радарчик об этом говорит.
public struct ResourceAlert: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let kind: ResourceKind
    /// nil — про мак целиком (батарея, давление, нагрев).
    public let app: AppIdentity?
    /// Сколько сейчас: % процессора, байты, % в час, уровень.
    public let value: Double
    /// Обычный уровень (медиана за неделю); nil — нормы ещё нет.
    public let usual: Double?
    /// С какого момента держится превышение.
    public let startedAt: Date
    public let createdAt: Date
    /// Фраза Радарчика: «Chrome ест 4,1 ГБ — в 3 раза больше обычного».
    public let title: String
    /// Второе предложение, если есть: «Больше всех ест Chrome».
    public let detail: String?
    public var status: AlertStatus
    public var statusChangedAt: Date?

    public init(id: Int64, kind: ResourceKind, app: AppIdentity?, value: Double, usual: Double?, startedAt: Date, createdAt: Date, title: String, detail: String?, status: AlertStatus, statusChangedAt: Date?) {
        self.id = id
        self.kind = kind
        self.app = app
        self.value = value
        self.usual = usual
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.title = title
        self.detail = detail
        self.status = status
        self.statusChangedAt = statusChangedAt
    }

    public var key: AlertKey { AlertKey(kind: kind, appKey: app?.key) }
}

/// По чему считается пауза после тревоги и «это нормально»: вид и приложение.
public struct AlertKey: Hashable, Sendable {
    public let kind: ResourceKind
    /// Пустая строка — мак целиком.
    public let appKey: String

    public init(kind: ResourceKind, appKey: String?) {
        self.kind = kind
        self.appKey = appKey ?? ""
    }
}

/// Строка экрана «Система»: сколько ест приложение и сколько обычно.
public struct AppUsageRow: Identifiable, Sendable, Equatable {
    public var id: String { usage.app.key }
    public let usage: AppUsage
    /// Обычный уровень (медиана за неделю), когда норма уже накопилась.
    public let usualCPU: Double?
    public let usualMemory: Double?
    public let usualPower: Double?

    public init(usage: AppUsage, usualCPU: Double?, usualMemory: Double?, usualPower: Double?) {
        self.usage = usage
        self.usualCPU = usualCPU
        self.usualMemory = usualMemory
        self.usualPower = usualPower
    }
}

/// Всё, что нужно интерфейсу после очередного замера.
public struct ResourceState: Sendable, Equatable {
    public var system: SystemSnapshot?
    /// Лидеры последнего замера (по 12 на процессор, память и энергию),
    /// больше всех по процессору — первыми.
    public var apps: [AppUsageRow]
    /// Поминутно за последний час, последняя точка — текущая минута.
    public var history: [SystemMinute]
    /// Активные тревоги, старые первыми: показываем по одной.
    public var alerts: [ResourceAlert]
    /// Появились в этом замере — о них чёлка скажет сама.
    public var newAlerts: [ResourceAlert]
    /// У скольких приложений норма уже накопилась.
    public var normsCount: Int
    public var lastError: String?

    public init(system: SystemSnapshot? = nil, apps: [AppUsageRow] = [], history: [SystemMinute] = [], alerts: [ResourceAlert] = [], newAlerts: [ResourceAlert] = [], normsCount: Int = 0, lastError: String? = nil) {
        self.system = system
        self.apps = apps
        self.history = history
        self.alerts = alerts
        self.newAlerts = newAlerts
        self.normsCount = normsCount
        self.lastError = lastError
    }
}
