import Foundation

/// Что Радарчик говорит, когда кто-то ест больше обычного (SPEC §3а).
/// Одна короткая фраза в облачко и в «записку» под чёлкой:
/// «Chrome ест 4,1 ГБ — в 3 раза больше обычного» /
/// «Chrome is using 4.1 GB — 3× its usual».
public enum ResourcePhrase {
    /// Процессор приложения. Без нормы объясняем масштаб: 100% — одно ядро.
    public static func cpu(app: String, percent: Double, usual: Double?) -> String {
        let head = L("\(app) ест \(ResourceFormat.percent(percent)) процессора", "\(app) is using \(ResourceFormat.percent(percent)) CPU")
        if let usual {
            // Обычно меньше процента — «в 300 раз» звучит глупо, говорим проще.
            guard usual >= 1 else { return head + L(" — обычно почти ноль", " — usually close to zero") }
            return head + " — " + aboveUsual(percent / usual)
        }
        return head + " — " + (percent < 150 ? L("целое ядро", "a whole core") : cores(percent))
    }

    /// Память приложения: с нормой — во сколько раз больше, без нормы — какая это доля мака.
    public static func memory(app: String, bytes: Double, usual: Double?, totalBytes: Double?) -> String {
        let size = ResourceFormat.bytes(bytes)
        if let usual, usual > 0 {
            return L("\(app) ест \(size)", "\(app) is using \(size)") + " — " + aboveUsual(bytes / usual)
        }
        if let totalBytes, totalBytes > 0, let share = share(bytes / totalBytes) {
            return L("\(app) держит \(size) — \(share) всей памяти", "\(app) holds \(size) — \(share) of all memory")
        }
        return L("\(app) держит \(size) памяти", "\(app) holds \(size) of memory")
    }

    public static func battery(rate: Double, usual: Double?) -> String {
        let speed = L("\(Int(rate.rounded()))% в час", "\(Int(rate.rounded()))% an hour")
        if let usual, usual > 0 {
            let ratio = times(rate / usual)
            return L("Батарея садится \(ratio) быстрее обычного — \(speed)", "Battery is draining \(ratio) faster than usual — \(speed)")
        }
        return L("Батарея садится быстро — \(speed)", "Battery is draining fast — \(speed)")
    }

    public static func pressure() -> String {
        L("Памяти не хватает", "Memory is running out")
    }

    public static func thermal(temperature: Double?) -> String {
        let head = L("Мак перегрелся", "Mac is overheating")
        return temperature.map { head + " — " + ResourceFormat.temperature($0) } ?? head
    }

    /// Второе предложение для тревог про мак целиком: кто больше всех виноват.
    public static func culprit(for kind: ResourceKind, app: AppUsage?) -> String? {
        guard let app else { return nil }
        let name = app.app.name
        switch kind {
        case .battery:
            return L("Больше всех ест \(name)", "\(name) uses the most")
        case .pressure:
            let size = ResourceFormat.bytes(Double(app.memoryBytes))
            return L("Больше всех держит \(name) — \(size)", "\(name) holds the most — \(size)")
        case .thermal:
            let cpu = ResourceFormat.percent(app.cpuPercent)
            return L("Больше всех грузит \(name) — \(cpu) процессора", "\(name) loads it the most — \(cpu) CPU")
        case .cpu, .memory:
            return nil
        }
    }

    /// «в 3 раза», «в 2,5 раза», «в 17 раз». До десяти — с десятыми.
    /// По-английски — «3×», «2.5×», «17×».
    public static func times(_ ratio: Double) -> String {
        if ratio < 10 {
            let tenths = Int((ratio * 10).rounded())
            if tenths % 10 != 0 {
                // Дробное число — всегда «раза»: «в 2,5 раза».
                return L("в \(ResourceFormat.decimal(ratio)) раза", "\(ResourceFormat.decimal(ratio))×")
            }
            return whole(tenths / 10)
        }
        return whole(Int(ratio.rounded()))
    }

    /// «в 3 раза больше обычного» / «3× its usual».
    private static func aboveUsual(_ ratio: Double) -> String {
        L("\(times(ratio)) больше обычного", "\(times(ratio)) its usual")
    }

    private static func whole(_ number: Int) -> String {
        L("в \(number) \(RussianWords.plural(number, "раз", "раза", "раз"))", "\(number)×")
    }

    /// «4,5 ядра», «3 ядра», «5 ядер».
    static func cores(_ percent: Double) -> String {
        let count = percent / 100
        let tenths = Int((count * 10).rounded())
        if tenths % 10 != 0 { return ResourceFormat.decimal(count) + L(" ядра", " cores") }
        let whole = tenths / 10
        return "\(whole) " + Words.plural(whole, ru: ("ядро", "ядра", "ядер"), en: ("core", "cores"))
    }

    /// Доля памяти словами; меньше пятой части — не говорим.
    private static func share(_ fraction: Double) -> String? {
        switch fraction {
        case 0.6...: L("больше половины", "more than half")
        case 0.45...: L("половину", "half")
        case 0.3...: L("треть", "a third")
        case 0.2...: L("четверть", "a quarter")
        default: nil
        }
    }
}
