import Foundation

/// Адрес вкладки → то, что можно хранить: хост и путь без query, фрагмента и
/// идентификаторов. `https://github.com/acme/app/pull/123?tab=files` →
/// `github.com/acme/app/pull/:id`. Так приватнее (в query бывают токены),
/// и одинаковые страницы склеиваются для поиска повторов.
public enum URLNormalizer {
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard var host = components.host?.lowercased(), !host.isEmpty else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let segments = components.path.split(separator: "/").prefix(6).map { normalizeSegment(String($0)) }
            return ([host] + segments).joined(separator: "/")
        case "file":
            // Локальные файлы: путь может многое рассказать, храним только факт.
            return "file"
        case "about", "data", "blob", "javascript":
            return nil
        default:
            // chrome://newtab, chrome-extension://… — схема и хост, без пути.
            guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
            return "\(scheme)://\(host)"
        }
    }

    /// Хост из нормализованного адреса: `github.com/acme` → `github.com`.
    public static func host(of normalized: String) -> String? {
        if normalized.contains("://") { return normalized }
        return normalized.split(separator: "/").first.map(String.init)
    }

    /// Часть пути, похожая на идентификатор, заменяется шаблоном.
    static func normalizeSegment(_ segment: String) -> String {
        if segment.allSatisfy(\.isNumber) { return ":id" }
        if segment.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil {
            return ":uuid"
        }
        if segment.contains("@") { return ":email" }
        if segment.count >= 16, segment.allSatisfy(\.isHexDigit) { return ":hash" }
        if segment.count >= 20, segment.contains(where: \.isNumber), segment.contains(where: \.isLetter) { return ":token" }
        return String(segment.prefix(40))
    }
}

/// Заголовок окна без «шума»: спиннеров (Claude Code крутит ✳ и ⠋ в заголовке
/// терминала), эмодзи и счётчиков вроде «(12)». Иначе каждый кадр спиннера
/// выглядел бы новым окном и резал сессию.
public enum TitleNormalizer {
    public static func normalize(_ title: String?) -> String? {
        guard let title else { return nil }
        let scalars = title.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .otherSymbol
                && scalar.value != 0xFE0F && scalar.value != 0xFE0E && scalar.value != 0x200D
        }
        var text = String(String.UnicodeScalarView(scalars))
        text = text.replacingOccurrences(of: #"\s*[\(\[]\d+[\)\]]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}
