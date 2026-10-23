import Darwin
import Foundation

/// Разбор пакетов для «Сетевого надзора» (SPEC §3б, 2026-10-22). Root-часть снимает
/// трафик с pktap — псевдоинтерфейса macOS, который к каждому пакету приписывает
/// pid и имя процесса. Нам нужны только две вещи: первый пакет каждого исходящего
/// TCP-соединения (SYN) и ответы DNS, чтобы называть адреса именами. Фильтр BPF
/// для pktap libpcap не компилирует («filtering not implemented»), поэтому отбираем
/// сами, по смещениям: это десяток сравнений на пакет.
///
/// Заголовок pktap в SDK не объявлен (`net/pktap.h` нет), раскладка — из XNU
/// `bsd/net/pktap.h`. Их две: v1 (156 байт, поля на месте) и v2 (компактная, строки
/// по смещениям). `pth_flags` в обеих лежит на 36-м байте — по нему и различаем.
public struct PktapHeader: Equatable, Sendable {
    public let length: Int
    /// DLT кадра за заголовком: Ethernet (1), loopback (0), сырой IP (12)…
    public let dlt: UInt32
    /// Длина канального заголовка перед IP — запасной путь, если DLT незнаком.
    public let framePreLength: Int
    public let flags: UInt32
    public let pid: Int32
    public let effectivePid: Int32
    public let command: String
    public let effectiveCommand: String
    public let interface: String

    public static let flagIn: UInt32 = 0x0000_0001
    public static let flagOut: UInt32 = 0x0000_0002
    /// Пакет послан за другого (nsurlsessiond за приложение): настоящий владелец — effective.
    public static let flagDelegated: UInt32 = 0x0000_0004
    public static let flagV2: UInt32 = 0x0008_0000
    /// Размер заголовка v1 в XNU.
    public static let v1Length = 156

    public var isOutbound: Bool { flags & Self.flagOut != 0 }
    public var isInbound: Bool { flags & Self.flagIn != 0 }
    public var ownerPid: Int32 { flags & Self.flagDelegated != 0 && effectivePid > 0 ? effectivePid : pid }
    public var ownerCommand: String { flags & Self.flagDelegated != 0 && effectivePid > 0 && !effectiveCommand.isEmpty ? effectiveCommand : command }

    public init(length: Int, dlt: UInt32, framePreLength: Int, flags: UInt32, pid: Int32, effectivePid: Int32, command: String, effectiveCommand: String, interface: String) {
        self.length = length
        self.dlt = dlt
        self.framePreLength = framePreLength
        self.flags = flags
        self.pid = pid
        self.effectivePid = effectivePid
        self.command = command
        self.effectiveCommand = effectiveCommand
        self.interface = interface
    }

    public static func parse(_ data: Data) -> PktapHeader? {
        let bytes = ByteReader(data)
        guard data.count >= 40, let flags = bytes.uint32(36) else { return nil }
        if flags & flagV2 != 0 {
            guard let length = bytes.uint8(0), let dlt = bytes.uint16(6), let pre = bytes.uint16(8), let pid = bytes.int32(28), let epid = bytes.int32(32),
                  Int(length) <= data.count
            else { return nil }
            func text(_ at: UInt8?, max: Int) -> String { at.flatMap { $0 == 0 ? nil : bytes.cString(Int($0), max: max) } ?? "" }
            return PktapHeader(
                length: Int(length), dlt: UInt32(dlt), framePreLength: Int(pre), flags: flags, pid: pid, effectivePid: epid,
                command: text(bytes.uint8(4), max: 17), effectiveCommand: text(bytes.uint8(5), max: 17), interface: text(bytes.uint8(3), max: 24)
            )
        }
        guard let length = bytes.uint32(0), let dlt = bytes.uint32(8), let pre = bytes.uint32(44), let pid = bytes.int32(52), let epid = bytes.int32(84),
              length >= 108, Int(length) <= data.count
        else { return nil }
        return PktapHeader(
            length: Int(length), dlt: dlt, framePreLength: Int(pre), flags: flags, pid: pid, effectivePid: epid,
            command: bytes.cString(56, max: 17), effectiveCommand: bytes.cString(88, max: 17), interface: bytes.cString(12, max: 24)
        )
    }
}

/// Где в кадре начинается IP — по DLT; незнакомый DLT — по `framePreLength` из pktap.
/// Проверяется версия IP в первом байте: не 4 и не 6 — пробуем другой вариант.
public enum LinkLayer {
    public static func ipOffset(dlt: UInt32, frame: Data, fallback: Int) -> Int? {
        var candidates: [Int] = []
        switch dlt {
        case 0, 108: candidates = [4] // DLT_NULL, DLT_LOOP
        case 1: // DLT_EN10MB; 802.1Q — ещё 4 байта
            if let type = ByteReader(frame).uint16BE(12), type == 0x8100 || type == 0x88A8 { candidates = [18] } else { candidates = [14] }
        case 12: candidates = [0] // DLT_RAW
        default: break
        }
        candidates.append(fallback)
        for offset in candidates where offset >= 0 && offset < frame.count {
            let version = frame[frame.startIndex + offset] >> 4
            if version == 4 || version == 6 { return offset }
        }
        return nil
    }
}

/// IP-пакет: адреса, транспорт, порты и полезная нагрузка транспорта (для DNS).
public struct IPPacket: Equatable, Sendable {
    public enum Transport: Equatable, Sendable {
        case tcp(flags: UInt8)
        case udp
        case other(UInt8)
    }

    public let version: Int
    public let source: String
    public let destination: String
    public let transport: Transport
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let payload: Data

    /// Первый пакет соединения: SYN без ACK.
    public var isSYN: Bool {
        if case .tcp(let flags) = transport { return flags & 0x12 == 0x02 }
        return false
    }

    public static func parse(_ data: Data) -> IPPacket? {
        let bytes = ByteReader(data)
        guard let first = bytes.uint8(0) else { return nil }
        let version = Int(first >> 4)
        var proto: UInt8
        var offset: Int
        let source: String
        let destination: String
        switch version {
        case 4:
            let headerLength = Int(first & 0x0F) * 4
            guard headerLength >= 20, data.count >= headerLength, let p = bytes.uint8(9) else { return nil }
            proto = p
            offset = headerLength
            source = bytes.ipv4(12)
            destination = bytes.ipv4(16)
        case 6:
            guard data.count >= 40, let next = bytes.uint8(6) else { return nil }
            proto = next
            offset = 40
            source = bytes.ipv6(8)
            destination = bytes.ipv6(24)
            // Заголовки-расширения: hop-by-hop (0), routing (43), destination (60), fragment (44).
            var hops = 0
            while [0, 43, 60, 44].contains(proto), hops < 8, let nextHeader = bytes.uint8(offset) {
                let length = proto == 44 ? 8 : (Int(bytes.uint8(offset + 1) ?? 0) + 1) * 8
                proto = nextHeader
                offset += length
                hops += 1
            }
        default:
            return nil
        }
        guard offset <= data.count else { return nil }
        switch proto {
        case 6:
            guard let sourcePort = bytes.uint16BE(offset), let destinationPort = bytes.uint16BE(offset + 2), let lengthByte = bytes.uint8(offset + 12),
                  let flags = bytes.uint8(offset + 13)
            else { return nil }
            let payloadOffset = offset + Int(lengthByte >> 4) * 4
            return IPPacket(
                version: version, source: source, destination: destination, transport: .tcp(flags: flags), sourcePort: sourcePort,
                destinationPort: destinationPort, payload: bytes.slice(from: payloadOffset)
            )
        case 17:
            guard let sourcePort = bytes.uint16BE(offset), let destinationPort = bytes.uint16BE(offset + 2) else { return nil }
            return IPPacket(
                version: version, source: source, destination: destination, transport: .udp, sourcePort: sourcePort, destinationPort: destinationPort,
                payload: bytes.slice(from: offset + 8)
            )
        default:
            return IPPacket(version: version, source: source, destination: destination, transport: .other(proto), sourcePort: 0, destinationPort: 0, payload: Data())
        }
    }
}

/// Ответ DNS: что спрашивали и какие адреса пришли. Имя — одно, из вопроса: при цепочке
/// CNAME приложение знает именно его, а не конечный хост CDN.
public enum DNSMessage {
    public struct Answer: Equatable, Sendable {
        public let name: String
        public let address: String
    }

    public static func answers(_ payload: Data) -> [Answer] {
        let bytes = ByteReader(payload)
        guard payload.count > 12, let flags = bytes.uint16BE(2), flags & 0x8000 != 0, flags & 0x000F == 0,
              let questions = bytes.uint16BE(4), let answerCount = bytes.uint16BE(6), questions >= 1
        else { return [] }
        var offset = 12
        guard let (question, afterName) = name(in: bytes, at: offset) else { return [] }
        offset = afterName + 4
        for _ in 1..<questions {
            guard let (_, next) = name(in: bytes, at: offset) else { return [] }
            offset = next + 4
        }
        var result: [Answer] = []
        for _ in 0..<answerCount {
            guard let (_, afterOwner) = name(in: bytes, at: offset), let type = bytes.uint16BE(afterOwner), let length = bytes.uint16BE(afterOwner + 8) else { break }
            let data = afterOwner + 10
            if type == 1, length == 4, data + 4 <= payload.count {
                result.append(Answer(name: question, address: bytes.ipv4(data)))
            } else if type == 28, length == 16, data + 16 <= payload.count {
                result.append(Answer(name: question, address: bytes.ipv6(data)))
            }
            offset = data + Int(length)
        }
        return result
    }

    /// Имя с учётом сжатия (указатели 0xC0). Возвращает имя и смещение сразу за ним.
    private static func name(in bytes: ByteReader, at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        while let length = bytes.uint8(offset) {
            if length == 0 {
                offset += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard let low = bytes.uint8(offset + 1), jumps < 16 else { return nil }
                if end == nil { end = offset + 2 }
                offset = Int(length & 0x3F) << 8 | Int(low)
                jumps += 1
                continue
            }
            guard let label = bytes.text(offset + 1, count: Int(length)) else { return nil }
            labels.append(label.lowercased())
            offset += 1 + Int(length)
        }
        return (labels.joined(separator: "."), end ?? offset)
    }
}

/// Чтение чисел из `Data` по смещению, с проверкой границ. Числа pktap — в порядке
/// машины (little-endian), сетевые — big-endian.
struct ByteReader {
    private let data: Data
    private let base: Int

    init(_ data: Data) {
        self.data = data
        base = data.startIndex
    }

    func uint8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[base + offset]
    }

    func uint16(_ offset: Int) -> UInt16? { load(offset) }
    func uint32(_ offset: Int) -> UInt32? { load(offset) }
    func int32(_ offset: Int) -> Int32? { load(offset) }

    func uint16BE(_ offset: Int) -> UInt16? {
        guard let high = uint8(offset), let low = uint8(offset + 1) else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }

    func ipv4(_ offset: Int) -> String {
        (0..<4).map { String(uint8(offset + $0) ?? 0) }.joined(separator: ".")
    }

    func ipv6(_ offset: Int) -> String {
        var raw = in6_addr()
        withUnsafeMutableBytes(of: &raw) { target in
            for index in 0..<16 { target[index] = uint8(offset + index) ?? 0 }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Строка до нуля, не длиннее `max`.
    func cString(_ offset: Int, max: Int) -> String {
        var result: [UInt8] = []
        for index in 0..<max {
            guard let byte = uint8(offset + index), byte != 0 else { break }
            result.append(byte)
        }
        return String(decoding: result, as: UTF8.self)
    }

    func text(_ offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        return String(decoding: data[(base + offset)..<(base + offset + count)], as: UTF8.self)
    }

    func slice(from offset: Int) -> Data {
        guard offset >= 0, offset <= data.count else { return Data() }
        return Data(data[(base + offset)...])
    }

    private func load<T: FixedWidthInteger>(_ offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else { return nil }
        return data.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: base - data.startIndex + offset, as: T.self) }
    }
}

/// Запрос к HTTP-прокси: куда на самом деле идёт клиент. Через локальный туннель
/// (`HTTPS_PROXY=http://127.0.0.1:8888`) наружу выходит ssh, а не скрипт, и по SYN
/// ничего не понять. Зато первый пакет клиента к прокси — открытым текстом:
/// `CONNECT host:443 HTTP/1.1` для TLS или `GET http://host/… HTTP/1.1` для http.
public enum ProxyRequest {
    public static func target(_ payload: Data) -> (host: String, port: UInt16)? {
        guard payload.count >= 12, let first = payload.first, first >= 0x41, first <= 0x5A else { return nil }
        let head = payload.prefix(600)
        guard let text = String(data: head, encoding: .ascii) else { return nil }
        let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return nil }
        let method = parts[0]
        let target = String(parts[1])
        if method == "CONNECT" {
            return hostPort(target, defaultPort: 443)
        }
        guard ["GET", "POST", "PUT", "HEAD", "DELETE", "PATCH", "OPTIONS"].contains(method) else { return nil }
        if target.hasPrefix("http://") { return hostPort(authority(target.dropFirst(7)), defaultPort: 80) }
        if target.hasPrefix("https://") { return hostPort(authority(target.dropFirst(8)), defaultPort: 443) }
        return nil
    }

    private static func authority(_ rest: Substring) -> String {
        String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }

    /// «host:port», «host», «[v6]:port» — имя маленькими буквами, только буквы, цифры, точки и дефисы.
    private static func hostPort(_ text: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        var host = text
        var port = defaultPort
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let inside = String(host[host.index(after: host.startIndex)..<close])
            let tail = host[host.index(after: close)...]
            if tail.hasPrefix(":"), let value = UInt16(tail.dropFirst()) { port = value }
            host = inside
        } else if let colon = host.lastIndex(of: ":") {
            guard let value = UInt16(host[host.index(after: colon)...]) else { return nil }
            port = value
            host = String(host[..<colon])
        }
        host = host.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:"))
        guard !host.isEmpty, host.count <= 253, host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return (host, port)
    }
}

/// Одно исходящее соединение, как его отдаёт root-часть: кто, куда, под какими именами
/// и кем запущен. Цепочку читает root-часть в момент SYN: curl живёт сотню миллисекунд,
/// и к опросу Радарчика его уже нет. Аргументы цепочки дальше памяти не уходят —
/// в журнал пишутся только имена программ.
public struct NetworkFlow: Codable, Equatable, Sendable {
    public let sequence: UInt64
    /// Unix-время: без настроек кодировщика дат.
    public let at: Double
    public let pid: Int32
    public let uid: UInt32
    public let command: String
    public let address: String
    public let port: UInt16
    /// Имена, которые недавно разрешались в этот адрес, свежие первыми.
    public let names: [String]
    public let interface: String
    /// Процесс первым, дальше родители (`ProcessChain.read`).
    public let chain: [ProcessLink]
    /// Через HTTP-прокси («127.0.0.1:8888»): адрес и порт — настоящая цель из `CONNECT`.
    public let proxy: String?

    public init(
        sequence: UInt64, at: Double, pid: Int32, uid: UInt32, command: String, address: String, port: UInt16, names: [String], interface: String,
        chain: [ProcessLink], proxy: String? = nil
    ) {
        self.sequence = sequence
        self.at = at
        self.pid = pid
        self.uid = uid
        self.command = command
        self.address = address
        self.port = port
        self.names = names
        self.interface = interface
        self.chain = chain
        self.proxy = proxy
    }

    public var date: Date { Date(timeIntervalSince1970: at) }

    /// Тот же поток с именами, узнанными позже (обратный DNS).
    public func withNames(_ names: [String]) -> NetworkFlow {
        NetworkFlow(
            sequence: sequence, at: at, pid: pid, uid: uid, command: command, address: address, port: port, names: names, interface: interface, chain: chain,
            proxy: proxy
        )
    }
}

/// Новое соединение из пакета — до того, как к нему прочитали цепочку.
public struct NewConnection: Equatable, Sendable {
    public let at: Date
    public let pid: Int32
    public let command: String
    public let address: String
    public let port: UInt16
    public let names: [String]
    public let interface: String
    public var proxy: String? = nil
}

/// Таблица потоков root-части: из пакетов — соединения. Исходящий SYN — новое
/// соединение (повтор того же pid → адрес:порт за `dedupe` секунд — ретрансмит, не
/// считаем); входящий ответ DNS — в словарь «адрес → имена». На loopback не смотрим.
/// Хранит последние `capacity` потоков с номерами: Радарчик забирает «всё после N».
public struct FlowTable: Sendable {
    public private(set) var nextSequence: UInt64 = 1
    /// Сколько ответов DNS разобрали и последние из них — для `--sniff`.
    public private(set) var answersSeen = 0
    public private(set) var recentAnswers: [DNSMessage.Answer] = []
    private var flows: [NetworkFlow] = []
    private var lastSeen: [String: Double] = [:]
    private var names: [String: [String]] = [:]
    private var nameOrder: [String] = []
    private let capacity: Int
    private let dedupe: TimeInterval
    private let dnsCapacity: Int

    public init(capacity: Int = 2_000, dedupe: TimeInterval = 30, dnsCapacity: Int = 4_096) {
        self.capacity = capacity
        self.dedupe = dedupe
        self.dnsCapacity = dnsCapacity
    }

    /// Пакет целиком, с заголовком pktap. Возвращает новое соединение, если это оно:
    /// дальше читают цепочку и зовут `record`.
    public mutating func observe(packet: Data, now: Date) -> NewConnection? {
        guard let header = PktapHeader.parse(packet), header.length < packet.count else { return nil }
        let frame = Data(packet[(packet.startIndex + header.length)...])
        guard let offset = LinkLayer.ipOffset(dlt: header.dlt, frame: frame, fallback: header.framePreLength),
              let ip = IPPacket.parse(Data(frame[(frame.startIndex + offset)...]))
        else { return nil }
        // Ответ DNS — по порту источника и биту QR, а не по направлению: на loopback и
        // туннелях ядро помечает его по-разному.
        if ip.transport == .udp, ip.sourcePort == 53 {
            for answer in DNSMessage.answers(ip.payload) { remember(answer) }
            return nil
        }
        guard header.isOutbound, case .tcp = ip.transport else { return nil }
        let time = now.timeIntervalSince1970
        if ip.isSYN {
            guard !NetworkRules.isLoopback(ip.destination) else { return nil }
            guard fresh("\(header.ownerPid)|\(ip.destination)|\(ip.destinationPort)", at: time) else { return nil }
            return NewConnection(
                at: now, pid: header.ownerPid, command: header.ownerCommand, address: ip.destination, port: ip.destinationPort,
                names: names[ip.destination] ?? [], interface: header.interface
            )
        }
        // Первый пакет к HTTP-прокси (в том числе на loopback): настоящая цель — в нём.
        guard !ip.payload.isEmpty, let target = ProxyRequest.target(ip.payload) else { return nil }
        let proxy = ip.destination + ":" + String(ip.destinationPort)
        guard fresh("\(header.ownerPid)|\(target.host)|\(target.port)|\(proxy)", at: time) else { return nil }
        return NewConnection(
            at: now, pid: header.ownerPid, command: header.ownerCommand, address: target.host, port: target.port, names: [target.host],
            interface: header.interface, proxy: proxy
        )
    }

    /// Не повтор за `dedupe` секунд (ретрансмит SYN, повторный CONNECT).
    private mutating func fresh(_ key: String, at time: Double) -> Bool {
        if let last = lastSeen[key], time - last < dedupe { return false }
        lastSeen[key] = time
        if lastSeen.count > capacity * 2 { lastSeen = lastSeen.filter { time - $0.value < dedupe } }
        return true
    }

    /// Записать соединение с цепочкой и владельцем; возвращает его с номером.
    @discardableResult
    public mutating func record(_ connection: NewConnection, chain: [ProcessLink], uid: UInt32) -> NetworkFlow {
        let flow = NetworkFlow(
            sequence: nextSequence, at: connection.at.timeIntervalSince1970, pid: connection.pid, uid: uid, command: connection.command,
            address: connection.address, port: connection.port, names: connection.names, interface: connection.interface, chain: chain,
            proxy: connection.proxy
        )
        nextSequence += 1
        flows.append(flow)
        if flows.count > capacity { flows.removeFirst(flows.count - capacity) }
        return flow
    }

    /// Потоки с номером больше `sequence`, старые первыми.
    public func flows(since sequence: UInt64) -> [NetworkFlow] {
        flows.filter { $0.sequence > sequence }
    }

    public func names(for address: String) -> [String] { names[address] ?? [] }

    private mutating func remember(_ answer: DNSMessage.Answer) {
        guard !answer.name.isEmpty, !answer.address.isEmpty else { return }
        answersSeen += 1
        recentAnswers.append(answer)
        if recentAnswers.count > 50 { recentAnswers.removeFirst(recentAnswers.count - 50) }
        var list = names[answer.address] ?? []
        list.removeAll { $0 == answer.name }
        list.insert(answer.name, at: 0)
        if list.count > 3 { list.removeLast(list.count - 3) }
        if names[answer.address] == nil { nameOrder.append(answer.address) }
        names[answer.address] = list
        while nameOrder.count > dnsCapacity {
            names[nameOrder.removeFirst()] = nil
        }
    }
}
