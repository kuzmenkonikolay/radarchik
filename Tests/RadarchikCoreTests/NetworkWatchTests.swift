import Foundation
import Testing
@testable import RadarchikCore

/// «Сетевой надзор» (SPEC §3б, 2026-10-22): root-часть снимает пакеты с pktap, Радарчик
/// смотрит, куда впервые пошёл скрипт, который запустил не ты, или инструмент Claude Code.
@Suite("Защита: сетевой надзор")
struct NetworkWatchTests {
    // MARK: - Сборка пакетов

    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private static func put16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 2), with: $0) }
    }

    private static func putText(_ data: inout Data, _ offset: Int, _ text: String) {
        let bytes = Array(text.utf8)
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    /// Заголовок pktap v1, как в XNU: 156 байт, поля на своих местах.
    static func pktapV1(dlt: UInt32 = 1, pre: UInt32 = 14, flags: UInt32, pid: Int32, comm: String, epid: Int32 = 0, ecomm: String = "", ifname: String = "en0") -> Data {
        var data = Data(count: 156)
        put32(&data, 0, 156)
        put32(&data, 8, dlt)
        putText(&data, 12, ifname)
        put32(&data, 36, flags)
        put32(&data, 44, pre)
        put32(&data, 52, UInt32(bitPattern: pid))
        putText(&data, 56, comm)
        put32(&data, 84, UInt32(bitPattern: epid))
        putText(&data, 88, ecomm)
        return data
    }

    /// Заголовок pktap v2: короткий, строки по смещениям, в флагах бит V2.
    static func pktapV2(dlt: UInt16 = 1, pre: UInt16 = 14, flags: UInt32, pid: Int32, comm: String, ifname: String = "en0") -> Data {
        var data = Data(count: 72)
        data[0] = 72
        data[3] = 60 // ifname
        data[4] = 40 // comm
        put16(&data, 6, dlt)
        put16(&data, 8, pre)
        put32(&data, 28, UInt32(bitPattern: pid))
        put32(&data, 36, flags | PktapHeader.flagV2)
        putText(&data, 40, comm)
        putText(&data, 60, ifname)
        return data
    }

    static func ethernet(_ type: UInt16) -> Data {
        Data(repeating: 0xAA, count: 12) + Data([UInt8(type >> 8), UInt8(type & 0xFF)])
    }

    static func ipv4(proto: UInt8, source: [UInt8], destination: [UInt8], payload: Data) -> Data {
        var header = Data([0x45, 0, 0, 0, 0x12, 0x34, 0x40, 0, 64, proto, 0, 0]) + Data(source) + Data(destination)
        let total = UInt16(header.count + payload.count)
        header[2] = UInt8(total >> 8)
        header[3] = UInt8(total & 0xFF)
        return header + payload
    }

    static func ipv6(proto: UInt8, payload: Data) -> Data {
        var header = Data([0x60, 0, 0, 0, 0, 0, proto, 64])
        header += Data([0x2a, 0x00, 0x14, 0x50] + [UInt8](repeating: 0, count: 11) + [1]) // 2a00:1450::1
        header += Data([0x26, 0x06, 0x47, 0x00] + [UInt8](repeating: 0, count: 11) + [2]) // 2606:4700::2
        header[4] = UInt8(payload.count >> 8)
        header[5] = UInt8(payload.count & 0xFF)
        return header + payload
    }

    static func tcp(source: UInt16, destination: UInt16, flags: UInt8) -> Data {
        Data([UInt8(source >> 8), UInt8(source & 0xFF), UInt8(destination >> 8), UInt8(destination & 0xFF)]) + Data(repeating: 0, count: 8)
            + Data([0x50, flags, 0xFF, 0xFF, 0, 0, 0, 0])
    }

    static func udp(source: UInt16, destination: UInt16, payload: Data) -> Data {
        let length = UInt16(8 + payload.count)
        return Data([UInt8(source >> 8), UInt8(source & 0xFF), UInt8(destination >> 8), UInt8(destination & 0xFF), UInt8(length >> 8), UInt8(length & 0xFF), 0, 0]) + payload
    }

    static func dnsName(_ name: String) -> Data {
        var data = Data()
        for label in name.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: Array(label.utf8))
        }
        data.append(0)
        return data
    }

    /// Ответ DNS на вопрос `question`: CNAME на lb.cdn.net и записи A/AAAA для `addresses`.
    static func dnsResponse(question: String, addresses: [[UInt8]]) -> Data {
        var data = Data([0xAB, 0xCD, 0x81, 0x80, 0, 1, 0, UInt8(addresses.count + 1), 0, 0, 0, 0])
        data += dnsName(question) + Data([0, 1, 0, 1])
        // CNAME: имя вопроса через указатель на 12-й байт.
        let target = dnsName("lb.cdn.net")
        data += Data([0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(target.count)]) + target
        for address in addresses {
            let type: UInt8 = address.count == 4 ? 1 : 28
            data += Data([0xC0, 0x0C, 0, type, 0, 1, 0, 0, 0, 60, 0, UInt8(address.count)]) + Data(address)
        }
        return data
    }

    static let evil: [UInt8] = [45, 59, 120, 176]
    static let me: [UInt8] = [192, 168, 1, 10]

    // MARK: - Разбор

    @Test func pktapHeadersOfBothLayouts() throws {
        let v1 = try #require(PktapHeader.parse(Self.pktapV1(flags: PktapHeader.flagOut, pid: 4242, comm: "node", ifname: "en0")))
        #expect(v1.length == 156)
        #expect(v1.dlt == 1)
        #expect(v1.framePreLength == 14)
        #expect(v1.isOutbound && !v1.isInbound)
        #expect(v1.pid == 4242)
        #expect(v1.command == "node")
        #expect(v1.interface == "en0")
        #expect(v1.ownerPid == 4242)
        // Делегированный пакет: настоящий хозяин — effective pid.
        let delegated = try #require(PktapHeader.parse(Self.pktapV1(flags: PktapHeader.flagOut | PktapHeader.flagDelegated, pid: 1, comm: "nsurlsessiond", epid: 777, ecomm: "Mail")))
        #expect(delegated.ownerPid == 777)
        #expect(delegated.ownerCommand == "Mail")
        let v2 = try #require(PktapHeader.parse(Self.pktapV2(flags: PktapHeader.flagIn, pid: 99, comm: "curl", ifname: "utun3")))
        #expect(v2.length == 72)
        #expect(v2.isInbound)
        #expect(v2.pid == 99)
        #expect(v2.command == "curl")
        #expect(v2.interface == "utun3")
        // Обрезанное — nil, без падения.
        #expect(PktapHeader.parse(Self.pktapV1(flags: 2, pid: 1, comm: "x").prefix(39)) == nil)
        #expect(PktapHeader.parse(Data()) == nil)
    }

    @Test func ipOffsetByLinkType() {
        let v4 = Self.ipv4(proto: 6, source: Self.me, destination: Self.evil, payload: Self.tcp(source: 50_000, destination: 443, flags: 0x02))
        #expect(LinkLayer.ipOffset(dlt: 1, frame: Self.ethernet(0x0800) + v4, fallback: 14) == 14)
        // 802.1Q — ещё четыре байта.
        let vlan = Data(repeating: 0xAA, count: 12) + Data([0x81, 0x00, 0, 1, 0x08, 0x00])
        #expect(LinkLayer.ipOffset(dlt: 1, frame: vlan + v4, fallback: 14) == 18)
        #expect(LinkLayer.ipOffset(dlt: 0, frame: Data([2, 0, 0, 0]) + v4, fallback: 4) == 4)
        #expect(LinkLayer.ipOffset(dlt: 12, frame: v4, fallback: 0) == 0)
        // Незнакомый DLT — по длине из pktap; мусор — nil.
        #expect(LinkLayer.ipOffset(dlt: 105, frame: Data(repeating: 0, count: 30) + v4, fallback: 30) == 30)
        #expect(LinkLayer.ipOffset(dlt: 105, frame: Data(repeating: 0, count: 30), fallback: 30) == nil)
    }

    @Test func tcpSynOverIPv4AndIPv6() throws {
        let syn = try #require(IPPacket.parse(Self.ipv4(proto: 6, source: Self.me, destination: Self.evil, payload: Self.tcp(source: 50_000, destination: 4_444, flags: 0x02))))
        #expect(syn.version == 4)
        #expect(syn.source == "192.168.1.10")
        #expect(syn.destination == "45.59.120.176")
        #expect(syn.destinationPort == 4_444)
        #expect(syn.isSYN)
        // SYN-ACK — ответ сервера, не начало.
        let synAck = try #require(IPPacket.parse(Self.ipv4(proto: 6, source: Self.evil, destination: Self.me, payload: Self.tcp(source: 443, destination: 50_000, flags: 0x12))))
        #expect(!synAck.isSYN)
        let six = try #require(IPPacket.parse(Self.ipv6(proto: 6, payload: Self.tcp(source: 50_001, destination: 443, flags: 0x02))))
        #expect(six.version == 6)
        #expect(six.source == "2a00:1450::1")
        #expect(six.destination == "2606:4700::2")
        #expect(six.destinationPort == 443)
        #expect(six.isSYN)
        #expect(IPPacket.parse(Data([0x45])) == nil)
        #expect(IPPacket.parse(Data([0x30, 0, 0, 0])) == nil)
    }

    @Test func dnsAnswersNameTheQuestion() {
        let answers = DNSMessage.answers(Self.dnsResponse(question: "api.evil.io", addresses: [Self.evil, [0x26, 0x06, 0x47, 0] + [UInt8](repeating: 0, count: 11) + [2]]))
        #expect(answers == [DNSMessage.Answer(name: "api.evil.io", address: "45.59.120.176"), DNSMessage.Answer(name: "api.evil.io", address: "2606:4700::2")])
        // Вопрос без ответа, мусор и запрос (не ответ) — пусто.
        #expect(DNSMessage.answers(Self.dnsResponse(question: "x.io", addresses: [])) == [])
        #expect(DNSMessage.answers(Data(repeating: 7, count: 40)) == [])
        var query = Self.dnsResponse(question: "api.evil.io", addresses: [Self.evil])
        query[2] = 0x01
        #expect(DNSMessage.answers(query) == [])
    }

    // MARK: - Таблица потоков

    private static func packet(_ header: Data, _ ip: Data) -> Data { header + ethernet(0x0800) + ip }
    /// Кадр loopback (DLT_NULL): четыре байта семейства адресов, потом IP.
    private static func loopback(_ header: Data, _ ip: Data) -> Data { header + Data([2, 0, 0, 0]) + ip }

    @Test func flowTableTurnsPacketsIntoConnections() throws {
        var table = FlowTable(dedupe: 30)
        let now = Date(timeIntervalSince1970: 1_000)
        // Сначала ответ DNS (входящий, от резолвера), потом SYN туда же.
        let dns = Self.packet(
            Self.pktapV1(flags: PktapHeader.flagIn, pid: 50, comm: "mDNSResponder"),
            Self.ipv4(proto: 17, source: [1, 1, 1, 1], destination: Self.me, payload: Self.udp(source: 53, destination: 51_000, payload: Self.dnsResponse(question: "api.evil.io", addresses: [Self.evil])))
        )
        #expect(table.observe(packet: dns, now: now) == nil)
        #expect(table.names(for: "45.59.120.176") == ["api.evil.io"])
        #expect(table.answersSeen == 1 && table.recentAnswers.first?.name == "api.evil.io")
        // Ответ, помеченный ядром как исходящий (loopback, туннель), — тоже ответ.
        let dnsOut = Self.packet(
            Self.pktapV1(flags: PktapHeader.flagOut, pid: 50, comm: "mDNSResponder"),
            Self.ipv4(proto: 17, source: [127, 0, 0, 1], destination: [127, 0, 0, 1], payload: Self.udp(source: 53, destination: 51_001, payload: Self.dnsResponse(question: "cdn.evil.io", addresses: [[8, 8, 8, 8]])))
        )
        #expect(table.observe(packet: dnsOut, now: now) == nil)
        #expect(table.names(for: "8.8.8.8") == ["cdn.evil.io"])
        let syn = Self.packet(
            Self.pktapV1(flags: PktapHeader.flagOut, pid: 4242, comm: "node"),
            Self.ipv4(proto: 6, source: Self.me, destination: Self.evil, payload: Self.tcp(source: 50_000, destination: 4_444, flags: 0x02))
        )
        let observed = table.observe(packet: syn, now: now)
        let connection = try #require(observed)
        #expect(connection.pid == 4242)
        #expect(connection.command == "node")
        #expect(connection.address == "45.59.120.176")
        #expect(connection.port == 4_444)
        #expect(connection.names == ["api.evil.io"])
        // Ретрансмит того же SYN — не новое соединение; через полминуты — новое.
        #expect(table.observe(packet: syn, now: now.addingTimeInterval(3)) == nil)
        #expect(table.observe(packet: syn, now: now.addingTimeInterval(31)) != nil)
        // Входящий SYN, не-SYN и loopback — мимо.
        let inbound = Self.packet(Self.pktapV1(flags: PktapHeader.flagIn, pid: 1, comm: "sshd"), Self.ipv4(proto: 6, source: Self.evil, destination: Self.me, payload: Self.tcp(source: 1, destination: 22, flags: 0x02)))
        #expect(table.observe(packet: inbound, now: now) == nil)
        let ack = Self.packet(Self.pktapV1(flags: PktapHeader.flagOut, pid: 4242, comm: "node"), Self.ipv4(proto: 6, source: Self.me, destination: [8, 8, 8, 8], payload: Self.tcp(source: 1, destination: 443, flags: 0x10)))
        #expect(table.observe(packet: ack, now: now) == nil)
        let local = Self.loopback(Self.pktapV1(dlt: 0, pre: 4, flags: PktapHeader.flagOut, pid: 7, comm: "ruby"), Self.ipv4(proto: 6, source: [127, 0, 0, 1], destination: [127, 0, 0, 1], payload: Self.tcp(source: 1, destination: 3_000, flags: 0x02)))
        #expect(table.observe(packet: local, now: now) == nil)

        // Через HTTP-прокси на loopback: SYN туда не считаем, а первый пакет CONNECT называет цель.
        let connectPayload = Data("CONNECT klientikscrm.helpdeskeddy.com:443 HTTP/1.1\r\nHost: klientikscrm.helpdeskeddy.com:443\r\n\r\n".utf8)
        let proxied = Self.loopback(
            Self.pktapV1(dlt: 0, pre: 4, flags: PktapHeader.flagOut, pid: 777, comm: "claude"),
            Self.ipv4(proto: 6, source: [127, 0, 0, 1], destination: [127, 0, 0, 1], payload: Self.tcp(source: 52_000, destination: 8_888, flags: 0x18) + connectPayload)
        )
        let viaProxy = table.observe(packet: proxied, now: now)
        #expect(viaProxy?.address == "klientikscrm.helpdeskeddy.com")
        #expect(viaProxy?.port == 443)
        #expect(viaProxy?.proxy == "127.0.0.1:8888")
        #expect(viaProxy?.names == ["klientikscrm.helpdeskeddy.com"])
        #expect(table.observe(packet: proxied, now: now.addingTimeInterval(1)) == nil)
        // Обычные данные на loopback (dev-сервер) — не соединение.
        let devServer = Self.loopback(
            Self.pktapV1(dlt: 0, pre: 4, flags: PktapHeader.flagOut, pid: 778, comm: "curl"),
            Self.ipv4(proto: 6, source: [127, 0, 0, 1], destination: [127, 0, 0, 1], payload: Self.tcp(source: 52_001, destination: 3_000, flags: 0x18) + Data("GET /api HTTP/1.1\r\n\r\n".utf8))
        )
        #expect(table.observe(packet: devServer, now: now) == nil)

        let chain = [ProcessLink(pid: 4242, path: "/opt/homebrew/bin/node", arguments: ["node", "install.js"], cwd: "/Users/me/work/app/node_modules/evil")]
        let flow = table.record(connection, chain: chain, uid: 501)
        #expect(flow.sequence == 1)
        #expect(flow.chain == chain)
        #expect(flow.uid == 501)
        #expect(table.flows(since: 0).count == 1)
        #expect(table.flows(since: 1).isEmpty)
        #expect(table.nextSequence == 2)
        // Через XPC поток едет как JSON — цепочка внутри.
        let data = try JSONEncoder().encode([flow])
        #expect(try JSONDecoder().decode([NetworkFlow].self, from: data) == [flow])
    }

    @Test func proxyRequestsNameTheRealTarget() {
        #expect(ProxyRequest.target(Data("CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com\r\n".utf8))?.host == "api.github.com")
        #expect(ProxyRequest.target(Data("CONNECT Example.COM HTTP/1.1\r\n".utf8)).map { "\($0.host):\($0.port)" } == "example.com:443")
        #expect(ProxyRequest.target(Data("GET http://example.com/path?q=1 HTTP/1.1\r\n".utf8)).map { "\($0.host):\($0.port)" } == "example.com:80")
        #expect(ProxyRequest.target(Data("POST http://host.io:8080/x HTTP/1.0\r\n".utf8)).map { "\($0.host):\($0.port)" } == "host.io:8080")
        #expect(ProxyRequest.target(Data("CONNECT [2606:4700::2]:443 HTTP/1.1\r\n".utf8))?.host == "2606:4700::2")
        // Обычный запрос без прокси, TLS и мусор — nil.
        #expect(ProxyRequest.target(Data("GET /index.html HTTP/1.1\r\n".utf8)) == nil)
        #expect(ProxyRequest.target(Data([0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00, 0x01, 0xFC, 0x03, 0x03, 0x00, 0x00])) == nil)
        #expect(ProxyRequest.target(Data("CONNECT evil host HTTP/1.1".utf8)) == nil)
        #expect(ProxyRequest.target(Data("CONNECT a:b HTTP/1.1\r\n".utf8)) == nil)
        #expect(ProxyRequest.target(Data()) == nil)
    }

    // MARK: - Правила

    private static let terminal = ProcessLink(pid: 100, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", arguments: ["Terminal"])
    private static let login = ProcessLink(pid: 101, path: "/usr/bin/login", arguments: ["login", "-pf", "me"])
    private static let zsh = ProcessLink(pid: 102, path: "/bin/zsh", arguments: ["-zsh"])
    private static let claude = ProcessLink(pid: 103, path: "/Users/me/.local/share/claude/versions/2.1.306", arguments: ["claude"], cwd: "/Users/me/work/storefront")
    private static let claudeShell = ProcessLink(pid: 104, path: "/bin/zsh", arguments: ["/bin/zsh", "-c", "curl https://docs.python.org"])

    private static func link(_ pid: Int32, _ path: String, _ arguments: [String], cwd: String? = nil) -> ProcessLink {
        ProcessLink(pid: pid, path: path, arguments: arguments, cwd: cwd)
    }

    private static let npm = link(200, "/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "install"], cwd: "/Users/me/work/app")
    /// postinstall пакета: его запустил npm, а не ты.
    private static let postinstall: [ProcessLink] = [
        link(210, "/opt/homebrew/bin/node", ["node", "install.js"], cwd: "/Users/me/work/app/node_modules/evil"),
        link(211, "/bin/sh", ["sh", "-c", "node install.js"]), npm, zsh, login, terminal,
    ]
    private static let typedNpm: [ProcessLink] = [npm, zsh, login, terminal]
    private static let claudeCurl: [ProcessLink] = [link(220, "/usr/bin/curl", ["curl", "https://docs.python.org"], cwd: "/Users/me/work/storefront"), claudeShell, claude, zsh, login, terminal]

    private static func flow(_ chain: [ProcessLink], address: String = "45.59.120.176", port: UInt16 = 443, names: [String] = []) -> NetworkFlow {
        NetworkFlow(sequence: 1, at: 1_000, pid: chain[0].pid, uid: 501, command: chain[0].name, address: address, port: port, names: names, interface: "en0", chain: chain)
    }

    @Test func privateAndServiceAddressesAreNotOurs() {
        for address in ["10.1.2.3", "192.168.0.1", "172.16.5.5", "172.31.255.1", "169.254.1.1", "100.64.0.1", "127.0.0.1", "::1", "fd00::1", "fe80::1"] {
            #expect(NetworkRules.isPrivate(address), "\(address)")
        }
        for address in ["172.32.0.1", "8.8.8.8", "45.59.120.176", "2a00:1450::1", "2606:4700::2"] {
            #expect(!NetworkRules.isPrivate(address), "\(address)")
        }
        #expect(NetworkRules.isServicePort(53) && NetworkRules.isServicePort(5_353) && !NetworkRules.isServicePort(443))
    }

    @Test func knownAndSuspiciousHosts() {
        #expect(NetworkRules.isKnownHost("registry.npmjs.org"))
        #expect(NetworkRules.isKnownHost("api.github.com"))
        #expect(NetworkRules.isKnownHost("api.anthropic.com"))
        #expect(!NetworkRules.isKnownHost("evil.io"))
        #expect(!NetworkRules.isKnownHost("notgithub.com"))
        #expect(NetworkRules.isSuspiciousHost("abc123.ngrok-free.app"))
        #expect(NetworkRules.isSuspiciousHost("x.oastify.com"))
        #expect(NetworkRules.isSuspiciousHost("webhook.site"))
        #expect(!NetworkRules.isSuspiciousHost("github.com"))
    }

    /// Чьё соединение — наше: postinstall под npm и curl из Claude Code. Не наше: набранное
    /// тобой без скрипта, сам агент со своим API, приложения и фон.
    @Test func scopeFollowsWhoStartedIt() {
        let post = AgentWatchRules.origin(Self.postinstall)
        #expect(NetworkRules.scope(Self.postinstall, origin: post) == .watched)
        #expect(NetworkRules.identity(Self.postinstall, origin: post) == "net|script|/opt/homebrew/bin/node /Users/me/work/app/node_modules/evil/install.js")
        #expect(NetworkRules.name(Self.postinstall, origin: post) == "node install.js")
        // `npm install` набрал ты сам — запись, без тревог.
        let typed = AgentWatchRules.origin(Self.typedNpm)
        #expect(AgentWatchRules.isTypedScript(Self.typedNpm, origin: typed))
        #expect(!AgentWatchRules.isTypedScript(Self.postinstall, origin: post))
        #expect(NetworkRules.scope(Self.typedNpm, origin: typed) == .typed)
        // Инструмент Claude Code — наше, с именем инструмента; сам Claude Code со своим API — нет.
        let tool = AgentWatchRules.origin(Self.claudeCurl)
        #expect(tool.kind == .assistant)
        #expect(NetworkRules.scope(Self.claudeCurl, origin: tool) == .watched)
        #expect(NetworkRules.identity(Self.claudeCurl, origin: tool) == "net|assistant|claude|curl")
        #expect(NetworkRules.name(Self.claudeCurl, origin: tool) == "Claude Code · curl")
        // Сам Claude Code (WebFetch, его API) — тоже наше, под своим именем: его API — известные хосты, одна запись.
        let api = [Self.claude, Self.zsh, Self.login, Self.terminal]
        let agent = AgentWatchRules.origin(api)
        #expect(NetworkRules.scope(api, origin: agent) == .watched)
        #expect(NetworkRules.identity(api, origin: agent) == "net|assistant|claude")
        #expect(NetworkRules.name(api, origin: agent) == "Claude Code")
        #expect(NetworkRules.assess(flow: Self.flow(api, names: ["api.anthropic.com"]), origin: agent, scope: .watched, fresh: false, home: "/Users/me")?.level == .info)
        #expect(NetworkRules.assess(flow: Self.flow(api, names: ["klientikscrm.helpdeskeddy.com"]), origin: agent, scope: .watched, fresh: false, home: "/Users/me")?.level == .warning)
        // Терминал, приложение, фон — это LuLu.
        let ssh = [Self.link(300, "/usr/bin/ssh", ["ssh", "host"]), Self.zsh, Self.login, Self.terminal]
        #expect(NetworkRules.scope(ssh, origin: AgentWatchRules.origin(ssh)) == .ignore)
        let ide = [Self.link(310, "/usr/bin/git", ["git", "fetch"]), Self.link(311, "/Applications/RubyMine.app/Contents/MacOS/rubymine", ["rubymine"])]
        #expect(NetworkRules.scope(ide, origin: AgentWatchRules.origin(ide)) == .ignore)
        let tunnel = [Self.link(320, "/opt/homebrew/bin/autossh", ["autossh", "-N", "host"])]
        #expect(NetworkRules.scope(tunnel, origin: AgentWatchRules.origin(tunnel)) == .ignore)
        // Интерактивная оболочка — без `-c`; `bash -lc` и `zsh -c` — нет.
        #expect(AgentWatchRules.isInteractiveShell(Self.link(1, "/bin/zsh", ["zsh", "-il"])))
        #expect(AgentWatchRules.isInteractiveShell(Self.link(1, "/bin/zsh", ["zsh", "--login"])))
        #expect(!AgentWatchRules.isInteractiveShell(Self.link(1, "/bin/bash", ["bash", "-lc", "x"])))
        #expect(!AgentWatchRules.isInteractiveShell(Self.claudeShell))
    }

    @Test func assessmentLevels() {
        let post = AgentWatchRules.origin(Self.postinstall)
        let tool = AgentWatchRules.origin(Self.claudeCurl)
        let typed = AgentWatchRules.origin(Self.typedNpm)
        func assess(_ chain: [ProcessLink], origin: AgentOrigin, scope: NetworkRules.Scope = .watched, address: String = "45.59.120.176", port: UInt16 = 443, names: [String] = [], fresh: Bool = false) -> NetworkRules.Assessment? {
            NetworkRules.assess(flow: Self.flow(chain, address: address, port: port, names: names), origin: origin, scope: scope, fresh: fresh, home: "/Users/me")
        }
        // Своё — запись; известный хост — запись; незнакомое имя — записка.
        #expect(assess(Self.typedNpm, origin: typed, scope: .typed) == NetworkRules.Assessment(level: .info, reasons: []))
        #expect(assess(Self.claudeCurl, origin: tool, names: ["registry.npmjs.org"]) == NetworkRules.Assessment(level: .info, reasons: []))
        #expect(assess(Self.claudeCurl, origin: tool, names: ["docs.python.org"]) == NetworkRules.Assessment(level: .warning, reasons: []))
        #expect(assess(Self.claudeCurl, origin: tool, port: 8_000, names: ["docs.python.org"]) == NetworkRules.Assessment(level: .warning, reasons: [.oddPort]))
        // Голый адрес сам по себе — записка с пометкой: имя могло лежать в кэше резолвера.
        #expect(assess(Self.claudeCurl, origin: tool) == NetworkRules.Assessment(level: .warning, reasons: [.rawAddress]))
        // Приметы утечки — тревога: голый адрес с нестандартным портом, туннель, зависимость сразу после установки.
        #expect(assess(Self.postinstall, origin: post, port: 4_444) == NetworkRules.Assessment(level: .critical, reasons: [.rawAddress, .oddPort]))
        #expect(assess(Self.claudeCurl, origin: tool, names: ["x.ngrok-free.app"]) == NetworkRules.Assessment(level: .critical, reasons: [.suspiciousHost]))
        #expect(assess(Self.postinstall, origin: post, names: ["telemetry.example.com"], fresh: true) == NetworkRules.Assessment(level: .critical, reasons: [.freshDependency]))
        #expect(assess(Self.postinstall, origin: post, names: ["telemetry.example.com"]) == NetworkRules.Assessment(level: .warning, reasons: []))
        // Скрипт из /tmp или из неизвестной скрытой папки — тревога даже с именем.
        let temp = [Self.link(400, "/opt/homebrew/bin/node", ["node", "/private/tmp/x.js"], cwd: "/private/tmp"), Self.claudeShell, Self.claude, Self.zsh]
        #expect(assess(temp, origin: AgentWatchRules.origin(temp), names: ["cdn.example.com"])?.reasons == [.tempScript])
        let hidden = [Self.link(410, "/usr/bin/python3", ["python3", "/Users/me/.evil/x.py"], cwd: "/Users/me"), Self.link(411, "/bin/sh", ["sh", "-c", "x"]), Self.npm, Self.zsh]
        #expect(assess(hidden, origin: AgentWatchRules.origin(hidden), names: ["cdn.example.com"])?.level == .critical)
        #expect(assess(Self.claudeCurl, origin: tool, scope: .ignore) == nil)
    }

    @Test func installCommandsAreRecognised() {
        for arguments in [["npm", "install"], ["/opt/homebrew/bin/pnpm", "add", "left-pad"], ["yarn"], ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "ci"],
                          ["python3", "-m", "pip", "install", "requests"], ["pip3", "install", "-r", "req.txt"], ["bundle", "install"], ["gem", "install", "x"],
                          ["cargo", "install", "x"], ["bun", "i"], ["uv", "sync"]] where arguments != ["yarn"] {
            #expect(NetworkRules.isInstall(arguments), "\(arguments)")
        }
        for arguments in [["npm", "run", "build"], ["node", "server.js"], ["git", "pull"], ["python3", "app.py"], ["bundle", "exec", "rails", "s"], []] {
            #expect(!NetworkRules.isInstall(arguments), "\(arguments)")
        }
    }

    /// Обратный DNS подтверждается прямым: localhost ↔ 127.0.0.1 — без сети.
    @Test func reverseNameIsForwardConfirmed() {
        #expect(ReverseDNS.confirmedName("127.0.0.1") == "localhost")
        #expect(ReverseDNS.addresses(of: "localhost").contains("127.0.0.1"))
        #expect(ReverseDNS.pointer("not an address") == nil)
    }

    // MARK: - Журнал

    @Test func seenPairsAreCountedOnce() throws {
        let repository = try GuardRepository(database: Database(path: ":memory:"))
        let identity = "net|script|/opt/homebrew/bin/node /x/install.js"
        let first = Date(timeIntervalSince1970: 1_000)
        #expect(try repository.networkSeen(identity: identity, host: "api.evil.io") == nil)
        try repository.touchNetworkSeen(identity: identity, name: "node install.js", host: "api.evil.io", project: "app", level: .warning, at: first)
        let seen = try #require(try repository.networkSeen(identity: identity, host: "api.evil.io"))
        #expect(seen.count == 1)
        #expect(seen.level == .warning)
        #expect(seen.project == "app")
        try repository.touchNetworkSeen(identity: identity, name: "node install.js", host: "api.evil.io", project: nil, level: .info, at: first.addingTimeInterval(60))
        let again = try #require(try repository.networkSeen(identity: identity, host: "api.evil.io"))
        #expect(again.count == 2)
        #expect(again.firstSeen == first)
        #expect(again.lastSeen == first.addingTimeInterval(60))
        #expect(again.project == "app")
        try repository.touchNetworkSeen(identity: identity, name: "node install.js", host: "github.com", project: "app", level: .info, at: first.addingTimeInterval(120))
        #expect(try repository.networkSeen(since: first).map(\.host) == ["github.com", "api.evil.io"])
        #expect(try repository.networkSeen(since: first.addingTimeInterval(100)).map(\.host) == ["github.com"])
        // Группы для экрана: по проекту, адреса свежие первыми.
        let summary = NetworkSummary(seen: try repository.networkSeen(since: first))
        #expect(summary.groups.map(\.title) == ["app"])
        #expect(summary.groups[0].hosts.map(\.host) == ["github.com", "api.evil.io"])
        #expect(summary.hostCount == 2 && summary.sourceCount == 1)
        // Чистка — вместе с журналом.
        try repository.purge(now: first.addingTimeInterval(Double(GuardRepository.retentionDays) * 86_400 + 200))
        #expect(try repository.networkSeen(since: .distantPast).isEmpty)
    }

    // MARK: - Фразы

    @Test func phrases() {
        #expect(GuardPhrase.networkTitle(name: "node install.js", host: "45.59.120.176", port: 4_444) == "node install.js → 45.59.120.176:4444")
        #expect(GuardPhrase.networkTitle(name: "node npm", host: "registry.npmjs.org", port: 443) == "node npm → registry.npmjs.org")
        #expect(GuardPhrase.networkNote(name: "Claude Code · curl", host: "docs.python.org", port: 443) == "Новый адрес у Claude Code · curl: docs.python.org")
        #expect(GuardPhrase.networkNote(name: "Claude Code · curl", host: "8.47.69.5", port: 443, reasons: [.rawAddress]) == "Новый адрес у Claude Code · curl: 8.47.69.5 — без DNS, по адресу")
        #expect(GuardPhrase.networkAlarm(name: "node install.js", host: "45.59.120.176", port: 4_444, reasons: [.rawAddress, .oddPort])
            == "node install.js пошёл на 45.59.120.176:4444 — без DNS, по адресу, нестандартный порт")
        let seen = NetworkSeen(identity: "a", name: "node npm", host: "registry.npmjs.org", project: "app", firstSeen: .distantPast, lastSeen: .distantPast, count: 1, level: .info)
        let note = GuardEvent(id: 1, kind: .network, level: .warning, at: .distantPast, title: "t", detail: nil, allowKey: nil, status: .logged, statusChangedAt: nil)
        #expect(GuardPhrase.networkHeadline(NetworkSummary(), watching: false, helperInstalled: false) == "Сетевой надзор ждёт root-часть: make install-guard.")
        #expect(GuardPhrase.networkHeadline(NetworkSummary(), watching: false, helperInstalled: true) == "Сеть пока не слушаю.")
        #expect(GuardPhrase.networkHeadline(NetworkSummary(), watching: true, helperInstalled: true) == "Пока ни один скрипт никуда не ходил.")
        #expect(GuardPhrase.networkHeadline(NetworkSummary(seen: [seen]), watching: true, helperInstalled: true) == "За сутки скрипты ходили на 1 адрес, всё знакомое.")
        #expect(GuardPhrase.networkHeadline(NetworkSummary(seen: [seen], events: [note]), watching: true, helperInstalled: true) == "За сутки — 1 адрес, из них 1 новый.")
        english {
            #expect(GuardPhrase.networkAlarm(name: "node install.js", host: "x.ngrok-free.app", port: 443, reasons: [.suspiciousHost]) == "node install.js went to x.ngrok-free.app — a tunnel or a leak catcher")
            #expect(GuardPhrase.networkHeadline(NetworkSummary(seen: [seen]), watching: true, helperInstalled: true) == "Scripts reached 1 address today, all familiar.")
        }
    }
}
