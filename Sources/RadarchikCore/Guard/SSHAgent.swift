import CryptoKit
import Foundation

/// Протокол ssh-agent (draft-miller-ssh-agent) — ровно столько, сколько нужно
/// посреднику «Защиты» (SPEC §3б, слежка за ключом): разрезать поток на сообщения
/// и понять, что просят подписать. Всё остальное посредник передаёт как есть.
///
/// Сообщение — длина (uint32, старшим байтом вперёд) и тело; первый байт тела — тип.
public enum SSHAgentProtocol {
    /// Больше этого не принимает и сам ssh-agent.
    public static let maxMessage = 256 * 1_024

    /// Типы сообщений, которые нам интересны.
    public enum Kind {
        public static let failure: UInt8 = 5
        public static let success: UInt8 = 6
        public static let requestIdentities: UInt8 = 11
        public static let identitiesAnswer: UInt8 = 12
        public static let signRequest: UInt8 = 13
        public static let signResponse: UInt8 = 14
        public static let extensionRequest: UInt8 = 27
    }

    /// Длина тела по четырём байтам заголовка; nil — пустое, больше `maxMessage` или заголовок неполный.
    public static func bodyLength(_ header: Data) -> Int? {
        var reader = SSHReader(header)
        guard header.count == 4, let length = reader.uint32().map(Int.init) else { return nil }
        return length > 0 && length <= maxMessage ? length : nil
    }

    /// Сообщение целиком: длина и тело.
    public static func frame(_ body: Data) -> Data {
        SSHWire.uint32(UInt32(body.count)) + body
    }

    /// Просьба подписать: каким ключом и что.
    public struct SignRequest: Equatable, Sendable {
        public let keyBlob: Data
        public let data: Data
        public let flags: UInt32

        public init(keyBlob: Data, data: Data, flags: UInt32) {
            self.keyBlob = keyBlob
            self.data = data
            self.flags = flags
        }
    }

    /// Тело сообщения → просьба подписать; nil — это другое сообщение или оно обрезано.
    public static func signRequest(_ body: Data) -> SignRequest? {
        var reader = SSHReader(body)
        guard reader.byte() == Kind.signRequest, let blob = reader.string(), let data = reader.string(), let flags = reader.uint32() else { return nil }
        return SignRequest(keyBlob: blob, data: data, flags: flags)
    }

    /// `session-bind@openssh.com`: перед входом OpenSSH 8.9+ называет агенту ключ
    /// сервера, к которому подключается. nil — это другое сообщение.
    public static func sessionBindHostKey(_ body: Data) -> Data? {
        var reader = SSHReader(body)
        guard reader.byte() == Kind.extensionRequest, reader.text() == "session-bind@openssh.com" else { return nil }
        return reader.string()
    }
}

/// Что именно просят подписать.
public enum SSHSignPurpose: Equatable, Sendable {
    /// Вход на сервер под этим пользователем: root, git, deploy.
    case login(user: String)
    /// Подпись `ssh-keygen -Y sign`: «git» — коммит или тег, «file» — файл.
    case signature(namespace: String)
    case other

    public init(signedData data: Data) {
        // `ssh-keygen -Y sign`: «SSHSIG», дальше пространство имён (формат sshsig из OpenSSH).
        let magic = Data("SSHSIG".utf8)
        if data.count > magic.count, data.prefix(magic.count) == magic {
            var reader = SSHReader(data.dropFirst(magic.count))
            if let namespace = reader.text(), !namespace.isEmpty {
                self = .signature(namespace: namespace)
                return
            }
        }
        // Вход (RFC 4252, §7): id сессии, SSH_MSG_USERAUTH_REQUEST (50), пользователь,
        // служба и метод — «publickey» или «publickey-hostbound-v00@openssh.com».
        var reader = SSHReader(data)
        if let session = reader.string(), session.count <= 64, reader.byte() == 50,
           let user = reader.text(), reader.text() == "ssh-connection",
           let method = reader.text(), method.hasPrefix("publickey") {
            self = .login(user: user)
            return
        }
        self = .other
    }
}

/// Публичный ключ: двоичный вид, как его шлёт агент, и отпечаток.
public enum SSHPublicKey {
    /// Строка `.pub` («ssh-ed25519 AAAA… комментарий») → ключ в двоичном виде;
    /// nil — это не ключ или тип в строке не совпал с типом внутри ключа.
    public static func blob(fromLine line: String) -> Data? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        var reader = SSHReader(blob)
        guard reader.text() == String(parts[0]) else { return nil }
        return blob
    }

    /// «SHA256:…» — как у `ssh-keygen -l`: base64 без «=» на конце.
    public static func fingerprint(_ blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob))
        return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Запись полей протокола SSH (RFC 4251): числа старшим байтом вперёд,
/// строка — длина и байты.
enum SSHWire {
    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func string(_ bytes: Data) -> Data { uint32(UInt32(bytes.count)) + bytes }
    static func string(_ text: String) -> Data { string(Data(text.utf8)) }
    static func bool(_ value: Bool) -> Data { Data([value ? 1 : 0]) }
}

/// Чтение тех же полей по порядку; nil — данные кончились раньше.
/// Копирует байты в массив: срезы `Data` начинаются не с нуля.
struct SSHReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func byte() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func uint32() -> UInt32? {
        guard bytes.count - index >= 4 else { return nil }
        defer { index += 4 }
        return bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() -> Data? {
        guard let length = uint32(), length <= UInt32(bytes.count - index) else { return nil }
        let start = index
        index += Int(length)
        return Data(bytes[start..<index])
    }

    mutating func text() -> String? {
        string().flatMap { String(data: $0, encoding: .utf8) }
    }
}
