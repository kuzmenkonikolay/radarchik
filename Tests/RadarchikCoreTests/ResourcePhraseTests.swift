import Foundation
import Testing
@testable import RadarchikCore

private let nb = "\u{00A0}"

@Suite("Ресурсы: как Радарчик говорит о нагрузке")
struct ResourcePhraseTests {
    @Test func formatsSizesPercentsAndPower() {
        #expect(ResourceFormat.bytes(870 * MiB) == "870\(nb)МБ")
        #expect(ResourceFormat.bytes(4.1 * GiB) == "4,1\(nb)ГБ")
        #expect(ResourceFormat.bytes(3 * GiB) == "3\(nb)ГБ")
        #expect(ResourceFormat.bytes(12.4 * GiB) == "12\(nb)ГБ")
        #expect(ResourceFormat.bytes(999 * MiB) == "999\(nb)МБ")
        #expect(ResourceFormat.bytes(1000 * MiB) == "1\(nb)ГБ")
        #expect(ResourceFormat.percent(23.4) == "23%")
        #expect(ResourceFormat.percent(0.3) == "<1%")
        #expect(ResourceFormat.percent(0) == "0%")
        #expect(ResourceFormat.watts(2.14) == "2,1\(nb)Вт")
        #expect(ResourceFormat.watts(3) == "3\(nb)Вт")
        #expect(ResourceFormat.watts(12.6) == "13\(nb)Вт")
        #expect(ResourceFormat.watts(0.04) == "<0,1\(nb)Вт")
        #expect(ResourceFormat.memoryUsage(used: 14.2 * GiB, total: 24 * GiB) == "14/24\(nb)ГБ")
        #expect(ResourceFormat.memoryUsage(used: 9.64 * GiB, total: 24 * GiB) == "9,6/24\(nb)ГБ")
        #expect(ResourceFormat.temperature(52.4) == "52°")
        #expect(ResourceFormat.drainPerHour(9.4) == "9%/ч")
    }

    @Test func memoryAndCPUPhrases() {
        #expect(ResourcePhrase.memory(app: "Google Chrome", bytes: 4.1 * GiB, usual: 1.37 * GiB, totalBytes: 24 * GiB)
            == "Google Chrome ест 4,1\(nb)ГБ — в 3 раза больше обычного")
        #expect(ResourcePhrase.memory(app: "Docker", bytes: 7.5 * GiB, usual: nil, totalBytes: 24 * GiB) == "Docker держит 7,5\(nb)ГБ — треть всей памяти")
        #expect(ResourcePhrase.memory(app: "Docker", bytes: 13 * GiB, usual: nil, totalBytes: 24 * GiB) == "Docker держит 13\(nb)ГБ — половину всей памяти")
        #expect(ResourcePhrase.memory(app: "Docker", bytes: 7.5 * GiB, usual: nil, totalBytes: nil) == "Docker держит 7,5\(nb)ГБ памяти")
        #expect(ResourcePhrase.cpu(app: "Google Chrome", percent: 85, usual: 5) == "Google Chrome ест 85% процессора — в 17 раз больше обычного")
        #expect(ResourcePhrase.cpu(app: "Slack", percent: 60, usual: 0.4) == "Slack ест 60% процессора — обычно почти ноль")
        // Без нормы объясняем, сколько это: 100% — одно ядро целиком.
        #expect(ResourcePhrase.cpu(app: "node", percent: 98, usual: nil) == "node ест 98% процессора — целое ядро")
        #expect(ResourcePhrase.cpu(app: "Docker", percent: 450, usual: nil) == "Docker ест 450% процессора — 4,5 ядра")
        #expect(ResourcePhrase.cpu(app: "Docker", percent: 500, usual: nil) == "Docker ест 500% процессора — 5 ядер")
        #expect(ResourcePhrase.cpu(app: "Docker", percent: 300, usual: nil) == "Docker ест 300% процессора — 3 ядра")
    }

    @Test func batteryHeatAndCulprits() {
        #expect(ResourcePhrase.battery(rate: 24, usual: 9.6) == "Батарея садится в 2,5 раза быстрее обычного — 24% в час")
        #expect(ResourcePhrase.battery(rate: 28.4, usual: nil) == "Батарея садится быстро — 28% в час")
        #expect(ResourcePhrase.thermal(temperature: 95.2) == "Мак перегрелся — 95°")
        #expect(ResourcePhrase.thermal(temperature: nil) == "Мак перегрелся")
        #expect(ResourcePhrase.pressure() == "Памяти не хватает")
        let chrome = AppUsage(
            app: AppIdentity(key: "com.google.Chrome", name: "Google Chrome"),
            cpuPercent: 340, memoryBytes: UInt64(6.2 * GiB), powerWatts: 4, processCount: 9
        )
        #expect(ResourcePhrase.culprit(for: .battery, app: chrome) == "Больше всех ест Google Chrome")
        #expect(ResourcePhrase.culprit(for: .pressure, app: chrome) == "Больше всех держит Google Chrome — 6,2\(nb)ГБ")
        #expect(ResourcePhrase.culprit(for: .thermal, app: chrome) == "Больше всех грузит Google Chrome — 340% процессора")
        #expect(ResourcePhrase.culprit(for: .battery, app: nil) == nil)
    }

    @Test func timesAgreeWithNumbers() {
        #expect(ResourcePhrase.times(3) == "в 3 раза")
        #expect(ResourcePhrase.times(2.5) == "в 2,5 раза")
        #expect(ResourcePhrase.times(2.96) == "в 3 раза")
        #expect(ResourcePhrase.times(17.3) == "в 17 раз")
        #expect(ResourcePhrase.times(21) == "в 21 раз")
        #expect(ResourcePhrase.times(22) == "в 22 раза")
        #expect(ResourcePhrase.times(11) == "в 11 раз")
    }

    // MARK: - По-английски (2026-10-19)

    @Test func englishFormats() {
        english {
            #expect(ResourceFormat.bytes(870 * MiB) == "870\(nb)MB")
            #expect(ResourceFormat.bytes(4.1 * GiB) == "4.1\(nb)GB")
            #expect(ResourceFormat.watts(2.14) == "2.1\(nb)W")
            #expect(ResourceFormat.watts(0.04) == "<0.1\(nb)W")
            #expect(ResourceFormat.memoryUsage(used: 9.64 * GiB, total: 24 * GiB) == "9.6/24\(nb)GB")
            #expect(ResourceFormat.drainPerHour(9.4) == "9%/h")
            #expect(ResourceFormat.thermal(.fair) == "warm")
            #expect(ResourceFormat.pressure(.warning) == "tight")
        }
    }

    @Test func englishPhrases() {
        english {
            #expect(ResourcePhrase.memory(app: "Google Chrome", bytes: 4.1 * GiB, usual: 1.37 * GiB, totalBytes: 24 * GiB)
                == "Google Chrome is using 4.1\(nb)GB — 3× its usual")
            #expect(ResourcePhrase.memory(app: "Docker", bytes: 7.5 * GiB, usual: nil, totalBytes: 24 * GiB) == "Docker holds 7.5\(nb)GB — a third of all memory")
            #expect(ResourcePhrase.memory(app: "Docker", bytes: 7.5 * GiB, usual: nil, totalBytes: nil) == "Docker holds 7.5\(nb)GB of memory")
            #expect(ResourcePhrase.cpu(app: "Google Chrome", percent: 85, usual: 5) == "Google Chrome is using 85% CPU — 17× its usual")
            #expect(ResourcePhrase.cpu(app: "Slack", percent: 60, usual: 0.4) == "Slack is using 60% CPU — usually close to zero")
            #expect(ResourcePhrase.cpu(app: "node", percent: 98, usual: nil) == "node is using 98% CPU — a whole core")
            #expect(ResourcePhrase.cpu(app: "Docker", percent: 450, usual: nil) == "Docker is using 450% CPU — 4.5 cores")
            #expect(ResourcePhrase.battery(rate: 24, usual: 9.6) == "Battery is draining 2.5× faster than usual — 24% an hour")
            #expect(ResourcePhrase.battery(rate: 28.4, usual: nil) == "Battery is draining fast — 28% an hour")
            #expect(ResourcePhrase.thermal(temperature: 95.2) == "Mac is overheating — 95°")
            #expect(ResourcePhrase.pressure() == "Memory is running out")
            let chrome = AppUsage(
                app: AppIdentity(key: "com.google.Chrome", name: "Google Chrome"),
                cpuPercent: 340, memoryBytes: UInt64(6.2 * GiB), powerWatts: 4, processCount: 9
            )
            #expect(ResourcePhrase.culprit(for: .battery, app: chrome) == "Google Chrome uses the most")
            #expect(ResourcePhrase.culprit(for: .pressure, app: chrome) == "Google Chrome holds the most — 6.2\(nb)GB")
            #expect(ResourcePhrase.culprit(for: .thermal, app: chrome) == "Google Chrome loads it the most — 340% CPU")
            #expect(ResourcePhrase.times(2.96) == "3×")
            #expect(ResourcePhrase.times(17.3) == "17×")
        }
    }

    @Test func hoverLine() {
        let memory = MemoryReading(usedBytes: UInt64(14.2 * GiB), totalBytes: UInt64(24 * GiB), pressure: .normal)
        func snapshot(temperature: Double?, thermal: ThermalLevel) -> SystemSnapshot {
            SystemSnapshot(at: t0, cpuPercent: 23.4, memory: memory, battery: nil, drainRate: nil, temperature: temperature, thermal: thermal)
        }
        #expect(ResourceFormat.hoverLine(snapshot(temperature: 52.4, thermal: .nominal)) == "CPU 23% · RAM 14/24\(nb)ГБ · 52°")
        // Градусы не узнать — говорим словами, и только если не норма.
        #expect(ResourceFormat.hoverLine(snapshot(temperature: nil, thermal: .fair)) == "CPU 23% · RAM 14/24\(nb)ГБ · тепло")
        #expect(ResourceFormat.hoverLine(snapshot(temperature: nil, thermal: .nominal)) == "CPU 23% · RAM 14/24\(nb)ГБ")
    }
}
