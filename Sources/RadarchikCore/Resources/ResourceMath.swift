import Foundation

/// Загрузка процессора по счётчикам ядер (`host_processor_info`).
public enum CPULoad {
    /// Занятость всего процессора между двумя замерами, 0–100.
    /// Счётчики 32-битные: разницу берём с переполнением (`&-`), она всё равно верна.
    /// nil — замеры несравнимы (другое число ядер) или времени не прошло.
    public static func percent(from previous: [CPUTicks], to current: [CPUTicks]) -> Double? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for (before, after) in zip(previous, current) {
            let user = UInt64(after.user &- before.user)
            let system = UInt64(after.system &- before.system)
            let nice = UInt64(after.nice &- before.nice)
            let idle = UInt64(after.idle &- before.idle)
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

/// Память мака (`host_statistics64` и sysctl).
public enum MemoryMath {
    /// «Использовано», как в Мониторинге системы (и как считает Stats):
    /// active + inactive + speculative + wired + compressed − purgeable − external.
    /// Файловый кэш (external) и то, что можно выкинуть (purgeable), — не занято.
    public static func usedPages(active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64, compressed: UInt64, purgeable: UInt64, external: UInt64) -> UInt64 {
        let gross = active + inactive + speculative + wired + compressed
        let free = purgeable + external
        return gross > free ? gross - free : 0
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 — хватает, 2 — впритык, 4 — не хватает.
    public static func pressure(sysctlLevel: Int32) -> MemoryPressure {
        switch sysctlLevel {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}

/// Скорость разряда батареи, % в час.
public enum BatteryMath {
    /// По току: −1500 мА при ёмкости 5000 мА·ч — 30% в час. Ток плавный,
    /// поэтому так точнее, чем по процентам заряда, которые меняются ступеньками.
    /// Заряжается или данных нет — nil.
    public static func drainRate(amperage: Double?, capacityMah: Double?) -> Double? {
        guard let amperage, let capacityMah, capacityMah > 0, amperage < 0 else { return nil }
        return -amperage / capacityMah * 100
    }

    /// Запасной способ — по снижению заряда за окно. Меньше 10 минут — шум, а не скорость.
    public static func drainRate(levels: [(at: Date, level: Double)]) -> Double? {
        guard let first = levels.first, let last = levels.last else { return nil }
        let hours = last.at.timeIntervalSince(first.at) / 3_600
        guard hours >= 10.0 / 60, first.level > last.level else { return nil }
        return (first.level - last.level) / hours
    }
}

/// Какие датчики IOHID считать температурой чипа.
public enum TemperatureSensors {
    /// Среднее по датчикам кристалла: «PMU tdie…» (M2 и новее) и «…MTR Temp Sensor…»
    /// (кластеры ядер на M1). Если таких нет — по всем, кроме батареи и SSD.
    public static func chipTemperature(_ readings: [(name: String, celsius: Double)]) -> Double? {
        let valid = readings.filter { $0.celsius > 5 && $0.celsius < 130 }
        let pool = choose(valid) { $0.name }
        guard !pool.isEmpty else { return nil }
        return pool.map(\.celsius).reduce(0, +) / Double(pool.count)
    }

    /// Какие датчики вообще спрашивать — по тем же правилам, по именам.
    /// Каждый опрос — запрос к системе, а датчиков на маке десятки (77 на M-серии).
    public static func indicesToRead(_ names: [String]) -> [Int] {
        choose(Array(names.enumerated())) { $0.element }.map(\.offset)
    }

    /// Датчики кристалла, а если их нет — все, кроме батареи и SSD.
    private static func choose<T>(_ items: [T], name: (T) -> String) -> [T] {
        let die = items.filter {
            let lowered = name($0).lowercased()
            return lowered.contains("tdie") || lowered.contains("mtr temp")
        }
        guard die.isEmpty else { return die }
        return items.filter { item in
            let lowered = name(item).lowercased()
            return !["battery", "gas gauge", "nand"].contains { lowered.contains($0) }
        }
    }
}

/// Квантили для норм.
public enum Quantile {
    /// Квантиль `q` (0…1) отсортированного массива, с линейной интерполяцией между соседями.
    public static func of(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}
