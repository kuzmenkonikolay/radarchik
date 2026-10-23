import Darwin
import Foundation

/// Имя адреса, когда ответа DNS в эфире не было: имя уже лежало в кэше mDNSResponder
/// или резолвер шифрованный. Обратная запись (PTR) сама по себе ничего не доказывает —
/// хозяин адреса пишет туда что хочет, — поэтому подтверждаем её прямым разрешением
/// (FCrDNS): имя из PTR должно разрешаться обратно в тот же адрес. Подделать это для
/// чужого домена нельзя: github.com на свой сервер не направишь.
public enum ReverseDNS {
    public static func confirmedName(_ address: String) -> String? {
        guard let name = pointer(address), addresses(of: name).contains(address) else { return nil }
        return name
    }

    /// PTR: «140.82.121.5» → «lb-140-82-121-5-fra.github.com»; nil — записи нет.
    static func pointer(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.lowercased()
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// Все адреса имени, как их пишет `inet_ntop` — сравнимо с адресами из пакетов.
    static func addresses(of name: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var result: [String] = []
        var current = list
        while let entry = current {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if entry.pointee.ai_family == AF_INET {
                var address = entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil { result.append(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
            } else if entry.pointee.ai_family == AF_INET6 {
                var address = entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil { result.append(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
            }
            current = entry.pointee.ai_next
        }
        return result
    }
}
