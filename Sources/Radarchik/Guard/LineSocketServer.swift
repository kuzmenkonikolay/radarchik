import Darwin
import Foundation

/// Сокет «строка — ответ» для zsh-хука «Защиты» (SPEC §3б, этап 3). Хук пишет
/// одну строку («нужны ли ключи команде …») и ждёт ответ, пока ты подтверждаешь
/// Touch ID. Писать в сокет может только сам пользователь (права 600).
///
/// В отличие от `ShellSocketServer` (наблюдение: хук пишет и сразу уходит)
/// соединение держится открытым до ответа. Каждое соединение — одна строка
/// и один ответ; пустой ответ — закрыть молча (на «done» хук ответа не ждёт).
final class LineSocketServer: @unchecked Sendable {
    typealias Reply = @Sendable (String) -> Void

    let path: String
    /// Строка, pid того, кто постучал (от ядра; 0 — не узнали), и как ответить.
    private let onLine: @Sendable (String, Int32, @escaping Reply) -> Void
    private let queue = DispatchQueue(label: "dev.kuzmenko.radarchik.guard-shell", qos: .userInitiated)
    // Ниже — только из `queue`.
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(path: String, onLine: @escaping @Sendable (String, Int32, @escaping Reply) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    func stop() {
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
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure(description: "socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "bind: \(message)")
        }
        // Писать в сокет может только сам пользователь.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
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
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Запись в закрытое соединение не должна уронить Радарчик (SIGPIPE). Но если
            // хук уже закрыл соединение (на «done» он пишет и сразу уходит), ядро не даёт
            // включить SO_NOSIGPIPE (EINVAL) — так Радарчик и упал 2026-10-20. Строку
            // прочитать всё равно можно, а отвечать некому: такой ответ только закрывает.
            var one: Int32 = 1
            let peerGone = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) != 0
            // Кто постучал — pid от ядра, а не со слов клиента: по нему окно Touch ID
            // скажет, кто просит открыть ключи.
            var peer: pid_t = 0
            var peerSize = socklen_t(MemoryLayout<pid_t>.size)
            if getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerSize) != 0 { peer = 0 }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while data.count < 64 * 1_024 {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
                if buffer[..<count].contains(UInt8(ascii: "\n")) { break }
            }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let kind = line.split(separator: "\t").first.map(String.init) ?? "(пусто)"
            Log.guardFlow.notice("терминал: \(kind, privacy: .public), fd \(client), \(data.count) байт\(peerGone ? ", терминал уже ушёл" : "", privacy: .public)")
            let once = ReplyOnce(client, kind: kind, canWrite: !peerGone)
            onLine(line, peer) { once.send($0) }
        }
    }
}

/// Ответ уходит ровно один раз, после него сокет закрывается.
private final class ReplyOnce: @unchecked Sendable {
    private var client: Int32
    private let kind: String
    /// false — SO_NOSIGPIPE не включился, потому что терминал уже ушёл: писать нельзя.
    private let canWrite: Bool
    private let lock = NSLock()

    init(_ client: Int32, kind: String, canWrite: Bool) {
        self.client = client
        self.kind = kind
        self.canWrite = canWrite
    }

    func send(_ text: String) {
        lock.lock()
        let fd = client
        client = -1
        lock.unlock()
        guard fd >= 0 else {
            Log.guardFlow.notice("терминал: ответ на \(self.kind, privacy: .public) второй раз — пропускаю")
            return
        }
        // Пустой ответ — только закрыть. Так на «done»: хук его не ждёт и закрывает
        // соединение сразу, запись туда ушла бы в закрытое соединение (EPIPE).
        guard !text.isEmpty else {
            close(fd)
            return
        }
        guard canWrite else {
            Log.guardFlow.notice("терминал: на \(self.kind, privacy: .public) не отвечаю — терминал уже ушёл, fd \(fd)")
            close(fd)
            return
        }
        let line = text + "\n"
        let written = line.withCString { write(fd, $0, strlen($0)) }
        let failure = written < 0 ? errno : 0
        let answer = text.split(separator: "\t").first.map(String.init) ?? ""
        Log.guardFlow.notice("терминал: ответ «\(answer, privacy: .public)» на \(self.kind, privacy: .public), fd \(fd), записано \(written), errno \(failure)")
        close(fd)
    }

    deinit {
        if client >= 0 {
            Log.guardFlow.notice("терминал: на \(self.kind, privacy: .public) так и не ответили — закрываю fd \(self.client)")
            close(client)
        }
    }
}
