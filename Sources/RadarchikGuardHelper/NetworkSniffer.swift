import CPcap
import Darwin
import Foundation
import RadarchikCore

/// Захват с pktap для «Сетевого надзора» (SPEC §3б, 2026-10-22). Открывает `pktap,all`
/// (нужен root — поэтому здесь, а не в Радарчике), читает пакеты и отдаёт их `FlowTable`:
/// та оставляет исходящие SYN и ответы DNS. Фильтр BPF для pktap libpcap не компилирует
/// («DLT_PKTAP link-layer type filtering not implemented»), поэтому отбор — в коде:
/// десяток сравнений на пакет, а на простое — ничего.
///
/// Живёт, пока Радарчик спрашивает: без вызовов две минуты — `HelperEngine` останавливает.
final class NetworkSniffer: @unchecked Sendable {
    private let lock = NSLock()
    private var table = FlowTable()
    private var handle: OpaquePointer?
    private var thread: Thread?
    private var failure: String?

    /// Размер захвата: заголовок pktap (156) + кадр + IPv6 + TCP с опциями, а у DNS — ответ целиком.
    private static let snapshotLength: Int32 = 1_600

    var isRunning: Bool { lock.withLock { handle != nil } }

    /// Запустить, если ещё не идёт. Не открылось — причина в `flows(since:)`, попробуем в следующий раз.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        var error = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let created = pcap_create("pktap,all", &error) else {
            failure = "pcap_create: " + error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            return
        }
        pcap_set_snaplen(created, Self.snapshotLength)
        pcap_set_timeout(created, 500)
        pcap_set_buffer_size(created, 4 * 1_024 * 1_024)
        // Заголовок pktap к каждому пакету — только если попросить до активации.
        pcap_set_want_pktap(created, 1)
        let activated = pcap_activate(created)
        guard activated >= 0 else {
            failure = "pcap_activate: " + String(cString: pcap_geterr(created))
            pcap_close(created)
            return
        }
        if pcap_datalink(created) != RADARCHIK_DLT_PKTAP, pcap_set_datalink(created, RADARCHIK_DLT_PKTAP) != 0 {
            failure = "pktap: " + String(cString: pcap_geterr(created)) + " (DLT \(pcap_datalink(created)))"
            pcap_close(created)
            return
        }
        failure = nil
        handle = created
        let pcap = PcapHandle(created)
        let worker = Thread { [weak self] in self?.loop(pcap.raw) }
        worker.name = "dev.kuzmenko.radarchik.guardd.sniff"
        worker.qualityOfService = .utility
        thread = worker
        worker.start()
    }

    func stop() {
        lock.lock()
        let current = handle
        handle = nil
        lock.unlock()
        guard let current else { return }
        pcap_breakloop(current)
        // Поток выйдет из pcap_next_ex по breakloop или по таймауту (0,5 с) и закроет handle сам.
    }

    /// Для `--sniff`: сколько ответов DNS разобрано и последние из них.
    func answers() -> (count: Int, recent: [DNSMessage.Answer]) {
        lock.withLock { (table.answersSeen, table.recentAnswers) }
    }

    /// Соединения после номера `since` (только пользователя `uid`, если задан), следующий
    /// номер и ошибка захвата, если он не идёт.
    func flows(since: UInt64, uid: UInt32? = nil) -> (flows: [NetworkFlow], next: UInt64, error: String?) {
        lock.withLock {
            let all = table.flows(since: since)
            return (uid.map { owner in all.filter { $0.uid == owner } } ?? all, table.nextSequence - 1, handle == nil ? failure : nil)
        }
    }

    private func loop(_ pcap: OpaquePointer) {
        defer { pcap_close(pcap) }
        var header: UnsafeMutablePointer<pcap_pkthdr>?
        var bytes: UnsafePointer<UInt8>?
        while true {
            let result = pcap_next_ex(pcap, &header, &bytes)
            if result == -2 { return }
            if result < 0 {
                lock.withLock {
                    failure = "pcap_next_ex: " + String(cString: pcap_geterr(pcap))
                    if handle == pcap { handle = nil }
                }
                return
            }
            let stillOurs = lock.withLock { handle == pcap }
            guard stillOurs else { return }
            guard result == 1, let header, let bytes else { continue }
            let packet = Data(bytes: bytes, count: Int(header.pointee.caplen))
            let now = Date(timeIntervalSince1970: Double(header.pointee.ts.tv_sec) + Double(header.pointee.ts.tv_usec) / 1_000_000)
            guard let connection = lock.withLock({ table.observe(packet: packet, now: now) }) else { continue }
            // Цепочку — сейчас, пока процесс жив: от root видно любой. Аргументы дальше памяти не уйдут.
            let chain = ProcessChain.read(pid: connection.pid)
            let uid = ProcessArguments.info(pid: connection.pid)?.uid ?? 0
            _ = lock.withLock { table.record(connection, chain: chain, uid: uid) }
        }
    }

    /// Указатель pcap для передачи в поток захвата: libpcap сам потокобезопасен ровно
    /// настолько, насколько мы им пользуемся — читает один поток, `pcap_breakloop` зовёт другой.
    private struct PcapHandle: @unchecked Sendable {
        let raw: OpaquePointer
        init(_ raw: OpaquePointer) { self.raw = raw }
    }

    /// `radarchik-guardd --sniff 10`: напечатать соединения за N секунд — проверить захват руками.
    static func demo(seconds: Int) -> Int32 {
        let sniffer = NetworkSniffer()
        sniffer.start()
        var since: UInt64 = 0
        var answersPrinted = 0
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for _ in 0..<max(seconds, 1) {
            sleep(1)
            let result = sniffer.flows(since: since)
            if let error = result.error {
                FileHandle.standardError.write(Data("захват не идёт: \(error)\n".utf8))
                return 1
            }
            since = result.next
            let answers = sniffer.answers()
            for answer in answers.recent.suffix(max(answers.count - answersPrinted, 0)) {
                print("\(formatter.string(from: Date())) DNS \(answer.name) → \(answer.address)")
            }
            answersPrinted = answers.count
            for flow in result.flows {
                let names = flow.names.isEmpty || flow.names == [flow.address] ? "" : " (" + flow.names.joined(separator: ", ") + ")"
                let via = flow.proxy.map { " via \($0)" } ?? ""
                print("\(formatter.string(from: flow.date)) uid \(flow.uid) \(flow.command)[\(flow.pid)] → \(flow.address):\(flow.port)\(names)\(via) \(flow.interface) · \(AgentWatchRules.chainText(flow.chain))")
            }
        }
        sniffer.stop()
        return 0
    }
}
