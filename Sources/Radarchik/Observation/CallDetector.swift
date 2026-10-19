import CoreAudio
import CoreMediaIO
import Foundation

/// Звонок ли сейчас: занят ли микрофон (тот же сигнал, что оранжевая точка
/// в строке меню) и камера. Звук не читается, доступ к микрофону не нужен,
/// только свойства устройств «кем-то используется».
///
/// Опрашивается раз в 2 секунды из трекера: чтение свойства дешёвое,
/// а без подписок на изменения код проще.
struct CallDetector {
    struct Sample: Equatable {
        var microphoneInUse: Bool
        var cameraInUse: Bool
    }

    func sample() -> Sample {
        Sample(microphoneInUse: Self.microphoneInUse(), cameraInUse: Self.cameraInUse())
    }

    /// Bundle id приложений, которые сейчас пишут звук с микрофона (macOS 14.2+).
    func microphoneHolders() -> [String] {
        Self.objects(of: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard Self.uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            return Self.string(process, kAudioProcessPropertyBundleID)
        }
    }

    // MARK: - Микрофон

    private static func microphoneInUse() -> Bool {
        var device = AudioObjectID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &device), device != 0 else {
            return false
        }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Свойство-число (UInt32). `AudioObjectID` — тоже UInt32, поэтому подходит и для id устройства.
    private static func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout UInt32) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var value: UInt32 = 0
        return read(object, selector, into: &value) ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func objects(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    // MARK: - Камера (CoreMediaIO)

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }

        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            var value: UInt32 = 0
            var valueSize: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueSize, &value)
            return status == noErr && value != 0
        }
    }
}
