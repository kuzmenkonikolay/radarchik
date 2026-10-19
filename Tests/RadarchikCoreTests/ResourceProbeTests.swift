import Darwin
import Foundation
import Testing
@testable import RadarchikCore

/// Настоящие замеры этого мака: системные вызовы отвечают и единицы верные.
/// Печатают только числа и счётчики, без имён приложений и путей.
@Suite("Ресурсы: замеры этого мака")
struct ResourceProbeTests {
    @Test func systemProbeReadsCPUMemoryAndSensors() async throws {
        let probe = SystemProbe()
        let first = probe.read()
        #expect(!first.cpuTicks.isEmpty)
        let memory = try #require(first.memory)
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.usedBytes > 0 && memory.usedBytes <= memory.totalBytes)
        try await Task.sleep(for: .milliseconds(400))
        let second = probe.read()
        let cpu = try #require(CPULoad.percent(from: first.cpuTicks, to: second.cpuTicks))
        #expect((0...100).contains(cpu))
        if let temperature = second.temperature {
            #expect((10...120).contains(temperature))
        }
        if let battery = second.battery {
            #expect((0...100).contains(battery.level))
        }
        print("[probe] ядер: \(second.cpuTicks.count), CPU \(Int(cpu))%, память \(ResourceFormat.memoryUsage(used: Double(memory.usedBytes), total: Double(memory.totalBytes))), давление \(memory.pressure)")
        print("[probe] датчиков температуры: \(probe.temperatureSensorCount), чип: \(second.temperature.map { ResourceFormat.temperature($0) } ?? "нет"), нагрев: \(second.thermal)")
        print("[probe] батарея: \(second.battery.map { "\(Int($0.level))%, ток \($0.amperage.map { "\(Int($0)) мА" } ?? "нет"), ёмкость \($0.capacityMah.map { "\(Int($0)) мА·ч" } ?? "нет"), от сети: \($0.onAC)" } ?? "нет")")
    }

    /// Сколько стоят замеры: Радарчик живёт в строке меню и не должен есть процессор.
    /// На виртуалках CI время скачет — там тест не гоняем (GitHub Actions ставит CI=true).
    @Test(.disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "время на виртуалках CI скачет"))
    func samplingIsCheap() throws {
        let system = SystemProbe()
        let processes = ProcessProbe()
        _ = system.read()
        _ = processes.read()
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<5 { body() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 5 / 1e6
        }
        // Температура кэшируется на 15 с — меряем её отдельно, честным новым замером.
        let thermometer = HIDThermometer()
        let systemMs = milliseconds { _ = system.read(now: Date.distantFuture) }
        let temperatureMs = milliseconds { _ = thermometer.read() }
        let processMs = milliseconds { _ = processes.read() }
        print("[perf] мак: \(String(format: "%.1f", systemMs)) мс, температура: \(String(format: "%.1f", temperatureMs)) мс, процессы: \(String(format: "%.1f", processMs)) мс")
        // Раз в 5 с мак, раз в 15 с процессы и температура: в среднем меньше 1% одного ядра.
        #expect(systemMs < 50 && processMs < 150 && temperatureMs < 150)
    }

    @Test func processProbeSeesItselfWithRealUnits() throws {
        let probe = ProcessProbe()
        // Немного поработать, чтобы время процессора было заметным.
        var sink = 0.0
        for index in 0..<3_000_000 { sink += sqrt(Double(index)) }
        #expect(sink > 0)

        let readings = probe.read()
        let me = try #require(readings.first { $0.pid == getpid() })
        #expect(me.memoryBytes > 1_000_000)

        // Время процессора совпадает с getrusage — значит, перевод из тиков Apple Silicon верный.
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let ratio = Double(me.cpuTimeNs) / 1e9 / max(seconds, 0.001)
        #expect((0.5...2).contains(ratio))

        let raw = try #require(ProcessProbe.rusage(getpid()))
        let apps = Set(readings.map(\.app.key))
        print("[probe] процессов: \(readings.count), приложений и групп: \(apps.count), из бандлов: \(apps.filter { !$0.hasPrefix("process:") }.count)")
        print("[probe] сам: CPU \(String(format: "%.2f", Double(me.cpuTimeNs) / 1e9)) с / getrusage \(String(format: "%.2f", seconds)) с, billed_energy \(raw.ri_billed_energy), energy_nj \(raw.ri_energy_nj)")
        print("[probe] ответственный процесс: \(ProcessProbe.canFindResponsibleProcess ? "есть" : "нет")")
    }
}
