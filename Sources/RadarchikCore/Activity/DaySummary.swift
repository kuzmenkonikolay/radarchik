import Foundation

/// Сводка дня из лога наблюдения. Её видно на экране «Что записано сегодня»,
/// и на этапе 4 она же станет основой разбора дня (в Claude пойдёт именно сводка, не сырой лог).
public struct DaySummary: Equatable, Sendable {
    public struct AppTime: Equatable, Sendable {
        public let bundleId: String
        public let appName: String
        public let seconds: TimeInterval
    }

    public struct SiteTime: Equatable, Sendable {
        public let host: String
        public let seconds: TimeInterval
        /// Сколько раз заходил (отдельные сессии на этом хосте).
        public let visits: Int
    }

    public struct CommandCount: Equatable, Sendable {
        public let template: String
        public let count: Int
        public let totalDurationMs: Int64
        /// Сколько раз команда завершилась с ошибкой.
        public let failures: Int
    }

    /// Копирование из одного приложения в другое (оценка, см. `PasteHeuristic`).
    public struct PasteFlow: Equatable, Sendable {
        public let fromApp: String
        public let toApp: String
        public let count: Int
    }

    /// Переключения туда-обратно между двумя приложениями.
    public struct SwitchPair: Equatable, Sendable {
        public let first: String
        public let second: String
        public let count: Int
    }

    /// Все списки — по убыванию.
    public var apps: [AppTime]
    public var sites: [SiteTime]
    public var commands: [CommandCount]
    public var pastes: [PasteFlow]
    public var switches: [SwitchPair]
    public var callSeconds: TimeInterval
    public var callCount: Int
    /// Время за компьютером (сумма сессий, без простоя).
    public var activeSeconds: TimeInterval
}

public enum DaySummaryBuilder {
    public static func build(
        sessions: [ActivitySession], commands: [ShellCommand], pastes: [PasteEvent], calls: [CallSession],
        now: Date = Date()
    ) -> DaySummary {
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        // Имена приложений берём из сессий; если приложение не встречалось — показываем bundle id.
        var names: [String: String] = [:]
        for session in ordered { names[session.bundleId] = session.appName }
        func name(_ bundleId: String) -> String { names[bundleId] ?? bundleId }

        var appSeconds: [String: TimeInterval] = [:]
        var siteSeconds: [String: TimeInterval] = [:]
        var siteVisits: [String: Int] = [:]
        for session in ordered {
            appSeconds[session.bundleId, default: 0] += session.duration
            if let url = session.url, let host = URLNormalizer.host(of: url) {
                siteSeconds[host, default: 0] += session.duration
                siteVisits[host, default: 0] += 1
            }
        }
        let apps = appSeconds
            .map { DaySummary.AppTime(bundleId: $0.key, appName: name($0.key), seconds: $0.value) }
            .sorted { ($1.seconds, $0.appName) < ($0.seconds, $1.appName) }
        let sites = siteSeconds
            .map { DaySummary.SiteTime(host: $0.key, seconds: $0.value, visits: siteVisits[$0.key] ?? 0) }
            .sorted { ($1.seconds, $0.host) < ($0.seconds, $1.host) }

        let commandCounts = Dictionary(grouping: commands, by: \.template)
            .map { template, runs in
                DaySummary.CommandCount(
                    template: template,
                    count: runs.count,
                    totalDurationMs: runs.reduce(0) { $0 + $1.durationMs },
                    failures: runs.filter { $0.exitCode != 0 }.count
                )
            }
            .sorted { ($1.count, $1.totalDurationMs, $0.template) < ($0.count, $0.totalDurationMs, $1.template) }

        var pasteCounts: [String: (from: String, to: String, count: Int)] = [:]
        for paste in pastes {
            guard let from = paste.fromBundleId, let to = paste.toBundleId else { continue }
            let key = from + "→" + to
            pasteCounts[key, default: (name(from), name(to), 0)].count += 1
        }
        let pasteFlows = pasteCounts.values
            .map { DaySummary.PasteFlow(fromApp: $0.from, toApp: $0.to, count: $0.count) }
            .sorted { ($1.count, $0.fromApp) < ($0.count, $1.fromApp) }

        // Переключение — соседние сессии в разных приложениях; пара без направления.
        var switchCounts: [String: (first: String, second: String, count: Int)] = [:]
        for (previous, next) in zip(ordered, ordered.dropFirst()) where previous.bundleId != next.bundleId {
            let pair = [previous.appName, next.appName].sorted()
            switchCounts[pair.joined(separator: "↔"), default: (pair[0], pair[1], 0)].count += 1
        }
        let switches = switchCounts.values
            .map { DaySummary.SwitchPair(first: $0.first, second: $0.second, count: $0.count) }
            .sorted { ($1.count, $0.first) < ($0.count, $1.first) }

        let callSeconds = calls.reduce(0) { $0 + max(($1.endedAt ?? now).timeIntervalSince($1.startedAt), 0) }

        return DaySummary(
            apps: apps,
            sites: sites,
            commands: commandCounts,
            pastes: pasteFlows,
            switches: switches,
            callSeconds: callSeconds,
            callCount: calls.count,
            activeSeconds: ordered.reduce(0) { $0 + $1.duration }
        )
    }
}
