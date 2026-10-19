import CoreGraphics
import Foundation

// Время и плавность для ролика. ImageRenderer рисует только конечное
// состояние вида, поэтому все промежуточные кадры считаем сами — от секунды
// кадра, без анимаций SwiftUI. Пружины — те же, что у панели в приложении.

enum Ease {
    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// 0 до `start`, 1 после `end`, между — линейно.
    static func progress(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return clamp01((t - start) / (end - start))
    }

    static func smooth(_ x: Double) -> Double {
        let x = clamp01(x)
        return x * x * (3 - 2 * x)
    }

    static func inOut(_ x: Double) -> Double {
        let x = clamp01(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    static func out(_ x: Double) -> Double {
        let x = clamp01(x)
        return 1 - pow(1 - x, 3)
    }

    /// Пружина как `.spring(response:dampingFraction:)` в SwiftUI: от 0 к 1
    /// с лёгким перелётом. `elapsed` — секунды от начала движения.
    static func spring(_ elapsed: Double, response: Double, damping: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        let omega = 2 * .pi / response
        let zeta = min(damping, 0.999)
        let omegaD = omega * sqrt(1 - zeta * zeta)
        let decay = exp(-zeta * omega * elapsed)
        return 1 - decay * (cos(omegaD * elapsed) + (zeta * omega / omegaD) * sin(omegaD * elapsed))
    }

    /// Туда пружиной в `start`, обратно пружиной в `end` (раскрыть и свернуть).
    static func there(andBack t: Double, start: Double, end: Double, response: Double, damping: Double, backDamping: Double = 0.9) -> Double {
        if t < end { return spring(t - start, response: response, damping: damping) }
        let from = spring(end - start, response: response, damping: damping)
        return from * (1 - spring(t - end, response: response, damping: backDamping))
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: CGSize, _ b: CGSize, _ t: Double) -> CGSize { CGSize(width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t)) }
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }

extension NotchShape {
    /// Фигура между двумя состояниями — как её рисует пружина в приложении.
    static func lerp(_ a: NotchShape, _ b: NotchShape, _ t: Double) -> NotchShape {
        NotchShape(
            topRadius: Radarchik.lerp(a.topRadius, b.topRadius, t),
            bandRadius: Radarchik.lerp(a.bandRadius, b.bandRadius, t),
            bandHeight: Radarchik.lerp(a.bandHeight, b.bandHeight, t),
            chinWidth: Radarchik.lerp(a.chinWidth, b.chinWidth, t),
            chinRadius: Radarchik.lerp(a.chinRadius, b.chinRadius, t)
        )
    }
}

/// Путь по точкам во времени: между ключами — плавно (`Ease.inOut`).
struct Keyframes<Value> {
    let keys: [(time: Double, value: Value)]
    let mix: (Value, Value, Double) -> Value

    func value(at t: Double) -> Value {
        guard let first = keys.first else { fatalError("Keyframes: пустой путь") }
        if t <= first.time { return first.value }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.time {
            return mix(a.value, b.value, Ease.inOut(Ease.progress(t, a.time, b.time)))
        }
        return keys[keys.count - 1].value
    }
}
