import Foundation

/// Порог тревоги: значение и сколько секунд оно должно держаться.
public struct Threshold: Sendable, Equatable {
    public let value: Double
    public let duration: TimeInterval

    public init(value: Double, duration: TimeInterval) {
        self.value = value
        self.duration = duration
    }
}

/// Все пороги этапа 6 в одном месте (SPEC §3а). Подкручивать — здесь.
///
/// Задача — молчать в обычные дни и замечать настоящий перерасход:
/// - пока нормы нет (первые дни), только очень большая нагрузка;
/// - с нормой — заметно выше обычного и выше обычных пиков (p95);
/// - превышение должно **держаться**, а не мелькнуть.
public struct ResourceRules: Sendable {
    // MARK: Процессор (% одного ядра, как в Мониторинге системы)

    /// С нормой: в 3 раза выше медианы…
    public var cpuNormMultiplier = 3.0
    /// …и не ниже 30% — меньше никто не заметит.
    public var cpuFloor = 30.0
    public var cpuSustain: TimeInterval = 5 * 60
    /// Без нормы: одно ядро целиком 10 минут (зависшая вкладка, убежавший node)
    /// или четыре ядра 5 минут (сборка Docker-образа, тяжёлая страница).
    public var cpuAbsolute = [Threshold(value: 90, duration: 10 * 60), Threshold(value: 400, duration: 5 * 60)]

    // MARK: Память

    /// С нормой: вдвое выше обычных пиков (p95)…
    public var memoryP95Multiplier = 2.0
    /// …и не меньше 1,5 ГБ.
    public var memoryFloor = 1.5 * 1_073_741_824
    public var memorySustain: TimeInterval = 5 * 60
    /// Без нормы: 30% памяти мака, но не меньше 4 ГБ, 10 минут подряд.
    public var memoryAbsoluteShare = 0.3
    public var memoryAbsoluteFloor = 4 * 1_073_741_824.0
    public var memoryAbsoluteSustain: TimeInterval = 10 * 60

    // MARK: Батарея (% в час)

    /// С нормой: вдвое быстрее обычного и не меньше 15% в час.
    public var drainNormMultiplier = 2.0
    public var drainFloor = 15.0
    /// Без нормы: 25% в час — батареи хватит меньше чем на 4 часа.
    public var drainAbsolute = 25.0
    public var drainSustain: TimeInterval = 10 * 60

    // MARK: Мак целиком

    /// Давление памяти «не хватает» и нагрев «горячо» — 2 минуты подряд.
    public var pressureSustain: TimeInterval = 2 * 60
    public var thermalSustain: TimeInterval = 2 * 60

    // MARK: После тревоги

    /// Пауза: о том же приложении и том же виде не тревожим 3 часа.
    public var snooze: TimeInterval = 3 * 3_600
    /// «Это нормально» про давление или нагрев — молчим сутки (уровень не поднять).
    public var levelSnooze: TimeInterval = 24 * 3_600
    /// «Это нормально»: дальше тревожим, только если выше этого уровня на четверть.
    public var overrideMargin = 1.25
    /// Прошло само: ниже 80% порога 2 минуты.
    public var resolveFactor = 0.8
    public var resolveSustain: TimeInterval = 2 * 60

    // MARK: Нормы

    /// Норма приложения: 48 пятиминуток (4 часа работы) и хотя бы 2 разных дня.
    public var appNormMinimumSamples = 48
    public var appNormMinimumDays = 2
    /// Норма разряда: 2 часа на батарее и хотя бы 2 разных дня.
    public var drainNormMinimumSamples = 120
    public var drainNormMinimumDays = 2
    public var normWindow: TimeInterval = 7 * 86_400

    public init() {}

    /// Пороги процессора. Без нормы их два (долго на одном ядре или коротко на многих).
    public func cpu(norm: UsageNorm?, override: Double?) -> [Threshold] {
        let base: [Threshold]
        if let norm, norm.isReliable {
            base = [Threshold(value: max(cpuNormMultiplier * norm.median, norm.p95, cpuFloor), duration: cpuSustain)]
        } else {
            base = cpuAbsolute
        }
        return base.map { raised($0, by: override) }
    }

    public func memory(norm: UsageNorm?, totalBytes: Double, override: Double?) -> Threshold {
        let base: Threshold
        if let norm, norm.isReliable {
            base = Threshold(value: max(memoryP95Multiplier * norm.p95, memoryFloor), duration: memorySustain)
        } else {
            base = Threshold(value: max(memoryAbsoluteShare * totalBytes, memoryAbsoluteFloor), duration: memoryAbsoluteSustain)
        }
        return raised(base, by: override)
    }

    public func drain(norm: UsageNorm?, override: Double?) -> Threshold {
        let value: Double
        if let norm, norm.isReliable {
            value = max(drainNormMultiplier * norm.median, drainFloor)
        } else {
            value = drainAbsolute
        }
        return raised(Threshold(value: value, duration: drainSustain), by: override)
    }

    /// «Это нормально» на уровне `override` поднимает порог выше него.
    private func raised(_ threshold: Threshold, by override: Double?) -> Threshold {
        guard let override else { return threshold }
        return Threshold(value: max(threshold.value, override * overrideMargin), duration: threshold.duration)
    }
}
