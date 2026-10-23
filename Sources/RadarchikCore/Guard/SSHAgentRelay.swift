import Darwin
import Foundation

/// Посредник перед ssh-agent (SPEC §3б, слежка за ключом). У него свой сокет,
/// и zsh-хук направляет туда терминал (`SSH_AUTH_SOCK`). Каждое подключение
/// посредник соединяет с настоящим агентом и передаёт сообщения как есть, а о
/// просьбах «подпиши» говорит `onSign`: кто попросил и подписал ли агент.
///
/// Перед тем как передать «подпиши», посредник спрашивает `decide` (2026-10-21):
/// пока оно думает — например, ждёт Touch ID, — клиент ждёт ответа. `.refuse` —
/// клиент получает отказ, как от агента без такого ключа; агент просьбу не видит.
///
/// Цепочку процессов снимаем, пока клиент ждёт ответа: ssh-keygen живёт доли
/// секунды. Поэтому она читается до того, как просьба уйдёт агенту, а `onSign`
/// зовётся до того, как подпись вернётся клиенту.
///
/// Каждое подключение — свой поток с блокирующим чтением: подключений мало
/// (вход, подпись коммита), а клиент может держать соединение, пока ты
/// отвечаешь ssh «yes» на новый сервер.
public final class SSHAgentRelay: @unchecked Sendable {
    public struct Signing: Sendable {
        public let pid: Int32
        /// Клиент первым, дальше его родители.
        public let chain: [ProcessLink]
        public let request: SSHAgentProtocol.SignRequest
        /// Агент подписал; false — отказал (ключа нет или агент заперт).
        public let signed: Bool
        /// Ключ сервера из `session-bind@openssh.com`, если ssh его прислал.
        public let hostKey: Data?
    }

    /// Просьба «подпиши» до того, как она ушла агенту.
    public struct Request: Sendable {
        public let pid: Int32
        public let chain: [ProcessLink]
        public let request: SSHAgentProtocol.SignRequest
        public let hostKey: Data?
    }

    public enum Decision: Equatable, Sendable {
        case forward
        case refuse
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public let path: String
    /// Сокет настоящего агента.
    public let upstream: String
    private let decide: @Sendable (Request) -> Decision
    private let onSign: @Sendable (Signing) -> Void
    private let queue = DispatchQueue(label: "dev.kuzmenko.radarchik.agent-relay", qos: .userInitiated)
    // Ниже — только из `queue`.
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(
        path: String, upstream: String, decide: @escaping @Sendable (Request) -> Decision = { _ in .forward },
        onSign: @escaping @Sendable (Signing) -> Void
    ) {
        self.path = path
        self.upstream = upstream
        self.decide = decide
        self.onSign = onSign
    }

    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    /// Новые подключения больше не принимаем; начатые доработают сами.
    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            listenFD = -1
        }
    }

    private func startOnQueue() throws {
        guard source == nil else { return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        guard var address = Self.address(path) else {
            close(fd)
            throw Failure(description: "socket path is too long: \(path)")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "bind: \(message)")
        }
        // Подключаться может только сам пользователь.
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw Failure(description: "listen: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let socketPath = path
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler {
            close(fd)
            unlink(socketPath)
        }
        source.resume()
        self.source = source
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    /// Одно подключение: сообщение клиента — агенту, ответ агента — клиенту, пока кто-то не закроет.
    private func serve(_ client: Int32) {
        defer { close(client) }
        // Запись в закрытое соединение не должна уронить Радарчик. Не включилось —
        // клиент уже ушёл (ядро не даёт setsockopt такому сокету), отвечать некому.
        var one: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        // Освободить поток, если клиент открыл соединение и молчит час.
        Self.setTimeout(client, seconds: 3_600)
        // Только свои: тот же пользователь (сокет и так 600).
        var credentials = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) == 0, credentials.cr_uid == getuid() else { return }
        var pid: pid_t = 0
        size = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0 { pid = 0 }
        guard let agent = Self.connect(upstream) else { return }
        defer { close(agent) }
        // Агент может спросить подтверждение (`ssh-add -c`) — ждём его до двух минут.
        Self.setTimeout(agent, seconds: 120)

        var hostKey: Data?
        while let request = Self.readMessage(client) {
            let sign = SSHAgentProtocol.signRequest(request)
            if let bound = SSHAgentProtocol.sessionBindHostKey(request) { hostKey = bound }
            let chain = sign == nil ? [] : ProcessChain.read(pid: pid)
            if let sign, decide(Request(pid: pid, chain: chain, request: sign, hostKey: hostKey)) == .refuse {
                // Агент просьбу не видел: клиенту — отказ, как от агента без такого ключа.
                guard Self.writeAll(client, SSHAgentProtocol.frame(Data([SSHAgentProtocol.Kind.failure]))) else { return }
                continue
            }
            guard Self.writeAll(agent, SSHAgentProtocol.frame(request)), let response = Self.readMessage(agent) else { return }
            if let sign {
                onSign(Signing(pid: pid, chain: chain, request: sign, signed: response.first == SSHAgentProtocol.Kind.signResponse, hostKey: hostKey))
            }
            guard Self.writeAll(client, SSHAgentProtocol.frame(response)) else { return }
        }
    }

    // MARK: - Сокеты

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// К настоящему агенту. SO_NOSIGPIPE — до connect: свой сокет, гонки нет.
    private static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Тело следующего сообщения; nil — соединение закрыто, ошибка или сообщение негодное.
    private static func readMessage(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4), let length = SSHAgentProtocol.bodyLength(header) else { return nil }
        return readExactly(fd, length)
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let result = data.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress! + filled, count - filled) }
            if result > 0 {
                filled += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let result = data.withUnsafeBytes { raw in write(fd, raw.baseAddress! + sent, data.count - sent) }
            if result > 0 {
                sent += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
