import Foundation
import Observation
import RadarchikCore
import Security

/// Состояние «Что это?» для одного алерта.
enum ExplainState: Equatable {
    /// 1 — собираю факты, 2 — спрашиваю Claude, 3 — читаю ответ.
    case thinking(step: Int)
    case answer(ExplainResult)
    /// `needsKey` — нет ключа или адреса прокси: вместо «Ещё раз» кнопка «Настроить».
    case failed(String, needsKey: Bool)
}

/// «Что это?» (2026-10-22): спросить Claude про процесс из алерта ресурсов или про то,
/// что заметила «Защита». Ключ и маршрут — те же, что у разбора дня (`ReviewService`).
/// Ответы живут, пока открыт Радарчик: по ключу алерта, чтобы раскрытие панели
/// показывало тот же ответ, а не спрашивало снова.
@MainActor
@Observable
final class ExplainService {
    private(set) var states: [String: ExplainState] = [:]
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func state(for key: String) -> ExplainState? { states[key] }

    func reset(_ key: String) { states[key] = nil }

    /// Для листа экранов.
    func preview(_ key: String, _ state: ExplainState) { states[key] = state }

    /// Спросить. Факты собираются на месте (путь, подпись, цепочка — миллисекунды).
    func explain(_ key: String, facts: @escaping @MainActor () -> ExplainFacts) {
        if case .thinking = states[key] { return }
        states[key] = .thinking(step: 1)
        Task { await run(key, facts: facts) }
    }

    private func run(_ key: String, facts: @escaping @MainActor () -> ExplainFacts) async {
        guard let apiKey = KeychainStore.read(ReviewService.keyAccount) else {
            states[key] = .failed(L("Нет ключа Claude — добавь его в «Разбор дня и Claude».", "No Claude key — add one in “Daily review & Claude”."), needsKey: true)
            return
        }
        guard let route = ClaudeRoute.parse(settings.proxyAddress) else {
            states[key] = .failed(L("Не разобрал адрес прокси в настройках.", "Couldn’t parse the proxy address in Settings."), needsKey: true)
            return
        }
        let collected = facts()
        // Факты собраны за миллисекунды — пусть шаг будет виден.
        try? await Task.sleep(for: .milliseconds(350))
        guard case .thinking = states[key] else { return }
        states[key] = .thinking(step: 2)
        let model = settings.claudeModel
        do {
            let request = try ClaudeAPI.explainRequest(apiKey: apiKey, model: model, facts: collected)
            let (data, status) = try await ClaudeClient(route: route).send(request)
            guard case .thinking = states[key] else { return }
            states[key] = .thinking(step: 3)
            let result = try ClaudeAPI.parseExplanation(data: data, statusCode: status, model: model)
            try? await Task.sleep(for: .milliseconds(250))
            states[key] = .answer(result)
        } catch let error as ClaudeAPIError {
            states[key] = .failed(error.description, needsKey: false)
        } catch {
            states[key] = .failed(route.describe(error), needsKey: false)
        }
    }
}

// MARK: - Факты

extension ExplainFacts {
    /// Алерт ресурсов: процесс по имени из алерта — путь, подпись, кто запустил, сколько держится.
    @MainActor static func resource(_ alert: ResourceAlert) -> ExplainFacts {
        let name = alert.app?.name ?? L("мак целиком", "the Mac as a whole")
        var path: String?
        var chain: String?
        if let app = alert.app, let pid = LiveProcess.find(app) {
            path = ProcessArguments.path(of: pid)
            let links = ProcessChain.read(pid: pid)
            if links.count > 1 { chain = AgentWatchRules.chainText(links) }
        }
        let held = DurationFormat.short(Date().timeIntervalSince(alert.startedAt))
        var notes = [L("Держится \(held).", "Going on for \(held).")]
        if alert.usual == nil { notes.append(L("Нормы для него ещё нет: наблюдаю меньше недели.", "No norm for it yet: watching for less than a week.")) }
        return ExplainFacts(
            subject: .resource, headline: [alert.title, alert.detail].compactMap { $0 }.joined(separator: ". "), process: name, path: path,
            signing: path.flatMap(CodeSigning.describe), chain: chain, notes: notes
        )
    }

    /// Запись «Защиты»: программа и цепочка — из заголовка и второй строки, которые уже без секретов.
    static func guardEvent(_ event: GuardEvent) -> ExplainFacts {
        let subject: Subject = switch event.kind {
        case .network: .network
        case .agent: .agent
        default: .process
        }
        let name = GuardPhrase.programName(event)
        var chain: String?
        var notes: [String] = []
        var command: String?
        if let detail = event.detail {
            if event.kind == .process {
                command = detail
            } else {
                let parts = detail.split(separator: " · ").map(String.init)
                chain = parts.last
                notes = parts.dropLast()
            }
        }
        let path = LiveProcess.find(name: name).flatMap(ProcessArguments.path(of:))
        return ExplainFacts(
            subject: subject, headline: event.title, process: name, path: path, signing: path.flatMap(CodeSigning.describe), chain: chain, notes: notes,
            commandLine: command
        )
    }
}

/// Живой процесс по тому, что знает алерт: bundle id приложения или имя программы.
enum LiveProcess {
    static func find(_ app: AppIdentity) -> Int32? {
        if app.key.hasPrefix("process:") { return find(name: String(app.key.dropFirst("process:".count))) }
        for pid in ProcessArguments.allPids() where pid > 0 {
            guard let path = ProcessArguments.path(of: pid), let range = path.range(of: "/Contents/MacOS/") else { continue }
            if Bundle(path: String(path[..<range.lowerBound]))?.bundleIdentifier == app.key { return pid }
        }
        return nil
    }

    static func find(name: String) -> Int32? {
        let wanted = name.lowercased()
        guard !wanted.isEmpty else { return nil }
        for pid in ProcessArguments.allPids() where pid > 0 {
            if let path = ProcessArguments.path(of: pid), (path as NSString).lastPathComponent.lowercased() == wanted { return pid }
        }
        return nil
    }
}

/// Чья подпись у программы — сильный довод в ответе: системный бинарник Apple
/// или Developer ID знакомого разработчика против неподписанного скрипта.
enum CodeSigning {
    static func describe(_ path: String) -> String? {
        var staticCode: SecStaticCode?
        // По ссылке (`/opt/homebrew/bin/node` → Cellar) код не читается — идём к файлу.
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return L("не подписан", "unsigned") }
        if let platform = dictionary[kSecCodeInfoPlatformIdentifier as String] as? Int, platform != 0 {
            return L("системный, подпись Apple", "system, signed by Apple")
        }
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            return summary
        }
        if let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String {
            return L("подпись без сертификата (ad hoc): \(identifier)", "ad hoc signature: \(identifier)")
        }
        return L("не подписан", "unsigned")
    }
}
