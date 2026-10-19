import Darwin
import Foundation
import Testing
@testable import RadarchikCore

/// «Только через прокси — очень важно» (2026-10-18). Поднимаем на свободном
/// порту поддельный прокси, который записывает первую строку запроса и
/// отвечает 502, и убеждаемся, что URLSession с нашими настройками пришла
/// к нему туннелем CONNECT. Ни настоящий прокси, ни API тест не трогает.
@Suite("Прокси: маршрут запросов")
struct ProxyRoutingTests {
    @Test func requestsGoThroughTheProxy() async throws {
        let recorder = try FakeProxy()
        let configuration = ProxyAddress(host: "127.0.0.1", port: recorder.port).sessionConfiguration(timeout: 5)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // Поддельный прокси отвечает 502 — запрос падает, и так и должно быть.
        _ = try? await session.data(from: URL(string: "https://api.anthropic.com/v1/models")!)

        #expect(recorder.firstLine() == "CONNECT api.anthropic.com:443 HTTP/1.1")
    }

    @Test func deadProxyMeansNoRequestAtAll() async throws {
        // Порт, на котором никто не слушает: запрос должен упасть, а не пойти напрямую.
        let proxy = ProxyAddress(host: "127.0.0.1", port: try FakeProxy.unusedPort())
        let session = URLSession(configuration: proxy.sessionConfiguration(timeout: 5))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(from: URL(string: "https://api.anthropic.com/v1/models")!)
            Issue.record("Запрос прошёл, хотя прокси нет, — значит, он ушёл мимо прокси")
        } catch {
            // Известное (2026-10-19): macOS при мёртвом прокси иногда пробует напрямую —
            // примерно раз из 10–30 здесь TLS-ошибка вместо «прокси не отвечает».
            // Сеть решено не менять, прямые соединения закрывает правило LuLu.
            // Тест держим: если запрос мимо прокси когда-нибудь пройдёт, строка выше
            // уронит его по-настоящему.
            withKnownIssue("macOS иногда идёт мимо мёртвого прокси", isIntermittent: true) {
                #expect(proxy.describe(error).contains("не отвечает"), "\(error)")
            }
        }
    }
}

/// Минимальный «прокси»: принимает одно подключение, запоминает первую строку, отвечает 502.
private final class FakeProxy: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var line: String?
    private let done = DispatchSemaphore(value: 0)

    init() throws {
        // Всё через локальную переменную: self нельзя трогать, пока не заданы все свойства.
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketFD, 1) == 0 else {
            close(socketFD)
            throw URLError(.cannotCreateFile)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        fd = socketFD
        port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global().async { [self] in
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &buffer, buffer.count)
            let text = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
            lock.withLock { line = text.components(separatedBy: "\r\n").first }
            let reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
            _ = reply.withCString { write(client, $0, strlen($0)) }
            close(client)
            done.signal()
        }
    }

    deinit { close(fd) }

    func firstLine() -> String? {
        _ = done.wait(timeout: .now() + 5)
        return lock.withLock { line }
    }

    /// Свободный порт: занять на миг через bind и сразу закрыть, никого не оставив слушать.
    static func unusedPort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw URLError(.cannotCreateFile) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
