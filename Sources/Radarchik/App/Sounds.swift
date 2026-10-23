import AVFoundation
import Foundation

/// Короткие тихие звуки Радарчика — по серьёзности алерта: монетка (пришли деньги),
/// звоночек («Пора платить»), предупреждение (тревога ресурсов), сигнал («Защита»);
/// и шорох карандаша (записал). Синтезируются при старте в память — файлов в бандле нет.
/// Выключаются кнопкой в тулбаре (`AppSettings.soundEnabled`).
@MainActor
final class SoundPlayer {
    private var players: [SoundKind: AVAudioPlayer] = [:]

    init() {
        for kind in SoundKind.allCases {
            if let player = try? AVAudioPlayer(data: Self.wav(Self.samples(for: kind)), fileTypeHint: AVFileType.wav.rawValue) {
                player.volume = Self.volume(for: kind)
                player.prepareToPlay()
                players[kind] = player
            }
        }
    }

    func play(_ kind: SoundKind) {
        guard let player = players[kind] else { return }
        player.currentTime = 0
        player.play()
    }

    private static let rate = 44_100.0

    /// Громкость растёт с серьёзностью: сигнал «Защиты» слышно и из-за стола.
    private static func volume(for kind: SoundKind) -> Float {
        switch kind {
        case .coin, .chime, .pencil: 0.22
        case .warning: 0.28
        case .alarm: 0.36
        }
    }

    /// Сами звуки: монетка — два быстрых чистых тона вверх с затуханием; звоночек —
    /// две ноты вверх пониже и мягче; предупреждение — два тона вниз с паузой;
    /// сигнал — три коротких гудка с обертонами; карандаш — шорох из шума с быстрым спадом.
    private static func samples(for kind: SoundKind) -> [Float] {
        switch kind {
        case .coin:
            return tone(frequency: 1_975, duration: 0.09, attack: 0.002) + tone(frequency: 2_637, duration: 0.32, attack: 0.002)
        case .chime:
            return tone(frequency: 880, duration: 0.14, attack: 0.012) + tone(frequency: 1_175, duration: 0.45, attack: 0.012)
        case .warning:
            return tone(frequency: 659, duration: 0.16, attack: 0.004) + silence(0.05) + tone(frequency: 494, duration: 0.34, attack: 0.004)
        case .alarm:
            let beep = pulse(frequency: 1_047, duration: 0.085)
            let gap = silence(0.055)
            return beep + gap + beep + gap + pulse(frequency: 1_047, duration: 0.17)
        case .pencil:
            var seed: UInt32 = 0x9E37_79B9
            let count = Int(rate * 0.14)
            var previous: Float = 0
            return (0..<count).map { i in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 8) / Float(1 << 24) * 2 - 1
                // Лёгкий фильтр: шорох, а не шипение.
                previous = previous * 0.6 + noise * 0.4
                let t = Double(i) / rate
                let envelope = Float(sin(min(t / 0.14, 1) * .pi)) * Float(exp(-t * 14))
                return previous * envelope * 0.5
            }
        }
    }

    private static func tone(frequency: Double, duration: Double, attack: Double) -> [Float] {
        let count = Int(rate * duration)
        return (0..<count).map { i in
            let t = Double(i) / rate
            let envelope = min(t / attack, 1) * exp(-t * 9)
            let wave = sin(2 * .pi * frequency * t) + 0.3 * sin(4 * .pi * frequency * t)
            return Float(wave * envelope * 0.6)
        }
    }

    /// Гудок с колокольной огибающей (без щелчков на краях) и обертонами — резче тона.
    private static func pulse(frequency: Double, duration: Double) -> [Float] {
        let count = Int(rate * duration)
        return (0..<count).map { i in
            let t = Double(i) / rate
            let envelope = sin(min(t / duration, 1) * .pi)
            let wave = sin(2 * .pi * frequency * t) + 0.5 * sin(4 * .pi * frequency * t) + 0.25 * sin(6 * .pi * frequency * t)
            return Float(wave * envelope * 0.45)
        }
    }

    private static func silence(_ duration: Double) -> [Float] {
        [Float](repeating: 0, count: Int(rate * duration))
    }

    /// WAV 16 бит моно.
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        let pcm = samples.map { Int16(max(min($0, 1), -1) * 32_767) }
        let byteCount = UInt32(pcm.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        for sample in pcm { append(sample) }
        return data
    }
}
