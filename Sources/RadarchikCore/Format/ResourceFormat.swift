import Foundation

/// Как показываем нагрузку. Руками, а не через форматтеры: не зависит от
/// локали и совпадает с ТЗ — «CPU 23% · RAM 14/24 ГБ · 52°».
/// Гигабайты — двоичные (как в Мониторинге системы): 24 ГБ у мака на 24 ГиБ.
public enum ResourceFormat {
    static let gib = 1_073_741_824.0
    static let mib = 1_048_576.0

    /// «870 МБ», «4,1 ГБ», «12 ГБ».
    public static func bytes(_ value: Double) -> String {
        if value >= 1_000 * mib {
            let gigabytes = value / gib
            return (gigabytes >= 10 ? "\(Int(gigabytes.rounded()))" : decimal(gigabytes)) + nbsp + L("ГБ", "GB")
        }
        return "\(max(Int((value / mib).rounded()), 0))" + nbsp + L("МБ", "MB")
    }

    /// «23%», «<1%». Для процессора одного приложения 100% — одно ядро.
    public static func percent(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    public static func temperature(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }

    /// «2,1 Вт», «13 Вт», «<0,1 Вт».
    public static func watts(_ value: Double) -> String {
        let unit = nbsp + L("Вт", "W")
        if value < 0.1 { return "<0" + L(",", ".") + "1" + unit }
        return (value >= 10 ? "\(Int(value.rounded()))" : decimal(value)) + unit
    }

    /// «9%/ч» — скорость разряда.
    public static func drainPerHour(_ rate: Double) -> String {
        "\(Int(rate.rounded()))%/" + L("ч", "h")
    }

    /// «14/24 ГБ»: занято до десяти гигабайт — с десятыми.
    public static func memoryUsage(used: Double, total: Double) -> String {
        let usedGB = used / gib
        let usedText = usedGB >= 10 ? "\(Int(usedGB.rounded()))" : decimal(usedGB)
        return "\(usedText)/\(Int((total / gib).rounded()))" + nbsp + L("ГБ", "GB")
    }

    public static func thermal(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: L("норма", "normal")
        case .fair: L("тепло", "warm")
        case .serious: L("горячо", "hot")
        case .critical: L("критично", "critical")
        }
    }

    public static func pressure(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: L("хватает", "fine")
        case .warning: L("впритык", "tight")
        case .critical: L("не хватает", "running out")
        }
    }

    /// Строка при наведении: «CPU 23% · RAM 14/24 ГБ · 52°». Градусов нет —
    /// словами из `thermalState`, и только если не норма.
    public static func hoverLine(_ snapshot: SystemSnapshot) -> String {
        var parts = ["CPU " + percent(snapshot.cpuPercent)]
        if let memory = snapshot.memory {
            parts.append("RAM " + memoryUsage(used: Double(memory.usedBytes), total: Double(memory.totalBytes)))
        }
        if let temperature = snapshot.temperature {
            parts.append(Self.temperature(temperature))
        } else if snapshot.thermal != .nominal {
            parts.append(thermal(snapshot.thermal))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Внутреннее

    static let nbsp = "\u{00A0}"

    /// Одна цифра после запятой (по-английски — после точки), «,0» отбрасывается: 4,1 · 3 · 2,5.
    static func decimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10)" + L(",", ".") + "\(abs(tenths % 10))"
    }
}
