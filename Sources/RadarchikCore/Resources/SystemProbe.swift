import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Показания мака целиком (SPEC §3а): процессор, память, батарея, температура.
/// Только вызовы без root и без разрешений:
/// - процессор — `host_processor_info`, проценты по разнице тиков;
/// - память — `host_statistics64`, давление — sysctl `kern.memorystatus_vm_pressure_level`;
/// - батарея — `IOPSCopyPowerSourcesInfo` и ток из `AppleSmartBattery`;
/// - температура — приватный IOHID (как Stats и macmon), запасной вариант — `thermalState`.
/// Не потокобезопасен: в приложении живёт внутри одного актора.
public final class SystemProbe {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let battery = SmartBattery()
    private let thermometer = HIDThermometer()
    /// Температуру спрашиваем не чаще раза в 30 секунд: она меняется медленно.
    private var temperatureReadAt: Date?
    private var lastTemperature: Double?

    public init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = size > 0 ? UInt64(size) : 16_384
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// Сколько датчиков температуры нашлось (0 — только `thermalState`).
    public var temperatureSensorCount: Int { thermometer.sensorCount }

    public func read(now: Date = Date()) -> SystemReading {
        SystemReading(cpuTicks: cpuTicks(), memory: memory(), battery: batteryReading(), temperature: temperature(now: now), thermal: thermal())
    }

    // MARK: - Процессор

    private func cpuTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        // Массив выделило ядро — вернуть ему.
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    // MARK: - Память

    private func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = MemoryMath.usedPages(
            active: UInt64(stats.active_count), inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count), wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count), purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count)
        )
        let total = ProcessInfo.processInfo.physicalMemory
        return MemoryReading(usedBytes: min(pages * pageSize, total), totalBytes: total, pressure: pressure())
    }

    private func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryMath.pressure(sysctlLevel: level)
    }

    // MARK: - Батарея

    private func batteryReading() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
        else { return nil }
        for source in list as [AnyObject] {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            let smart = battery.read()
            return BatteryReading(
                level: Double(current) * 100 / Double(maximum),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                amperage: smart.amperage,
                capacityMah: smart.capacity,
                minutesLeft: minutes.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return nil
    }

    // MARK: - Температура

    private func temperature(now: Date) -> Double? {
        if let temperatureReadAt, now.timeIntervalSince(temperatureReadAt) < 30 { return lastTemperature }
        temperatureReadAt = now
        lastTemperature = thermometer.read()
        return lastTemperature
    }

    private func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }
}

/// Ток и ёмкость из `AppleSmartBattery` — обычный сервис IOKit, разрешения не нужны.
/// Ток плавный (усреднён контроллером батареи), поэтому разряд по нему точнее,
/// чем по процентам заряда.
private final class SmartBattery {
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// Ёмкость полного заряда в мА·ч: от неё считаются проценты заряда. На macOS 27
    /// она лежит во вложенном `BatteryData` (проверено 2026-10-18), а
    /// `CurrentCapacity`/`MaxCapacity` сверху — это проценты (100).
    func read() -> (amperage: Double?, capacity: Double?) {
        guard service != 0 else { return (nil, nil) }
        let data = property("BatteryData") as? [String: Any]
        let capacity = number(property("AppleRawMaxCapacity"))
            ?? number(data?["FullChargeCapacity"])
            ?? number(data?["NominalChargeCapacity"])
            ?? number(property("NominalChargeCapacity"))
            ?? number(data?["DesignCapacity"])
        return (number(property("Amperage")) ?? number(property("InstantAmperage")), capacity)
    }

    private func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Отрицательный ток иногда лежит как большое беззнаковое — int64Value вернёт минус.
    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber).map { Double($0.int64Value) }
    }
}

/// Температура чипа через приватный IOHID — так делают Stats и macmon.
/// Работает без root, но после обновления macOS может пропасть: функции ищем
/// через dlsym, и если их нет, Радарчик просто не знает градусов
/// (остаётся `thermalState`: норма / тепло / горячо / критично).
final class HIDThermometer {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyProperty = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias FloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    /// kIOHIDEventTypeTemperature и его поле (`IOHIDEventFieldBase(type)` = type << 16).
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private var client: UnsafeMutableRawPointer?
    private var services: CFArray?
    private var names: [String] = []
    /// Какие из датчиков спрашивать: только кристалл (`TemperatureSensors.indicesToRead`).
    private var indices: [Int] = []
    private var copyEvent: CopyEvent?
    private var floatValue: FloatValue?

    init() {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let createSymbol = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let matchingSymbol = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let propertySymbol = dlsym(iokit, "IOHIDServiceClientCopyProperty"),
              let eventSymbol = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let valueSymbol = dlsym(iokit, "IOHIDEventGetFloatValue")
        else { return }
        let create = unsafeBitCast(createSymbol, to: CreateClient.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: SetMatching.self)
        let copyServices = unsafeBitCast(servicesSymbol, to: CopyServices.self)
        let copyProperty = unsafeBitCast(propertySymbol, to: CopyProperty.self)

        guard let client = create(kCFAllocatorDefault) else { return }
        self.client = client
        // Датчики температуры Apple: страница 0xff00, назначение 5.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)
        guard let raw = copyServices(client) else { return }
        let services = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        self.services = services
        for index in 0..<CFArrayGetCount(services) {
            var name = ""
            if let service = CFArrayGetValueAtIndex(services, index),
               let property = copyProperty(service, "Product" as CFString) {
                name = (Unmanaged<AnyObject>.fromOpaque(property).takeRetainedValue() as? String) ?? ""
            }
            names.append(name)
        }
        indices = TemperatureSensors.indicesToRead(names)
        copyEvent = unsafeBitCast(eventSymbol, to: CopyEvent.self)
        floatValue = unsafeBitCast(valueSymbol, to: FloatValue.self)
    }

    deinit {
        if let client { Unmanaged<AnyObject>.fromOpaque(client).release() }
    }

    var sensorCount: Int { names.count }

    /// Средняя температура кристалла, °C; nil — датчиков нет.
    func read() -> Double? {
        guard let services, let copyEvent, let floatValue else { return nil }
        var readings: [(name: String, celsius: Double)] = []
        for index in indices where index < CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let event = copyEvent(service, Self.temperatureEvent, 0, 0)
            else { continue }
            let value = floatValue(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            readings.append((names[index], value))
        }
        return TemperatureSensors.chipTemperature(readings)
    }
}
