import Foundation

/// Кандидат в «рутину» — то, что эвристики заметили до Claude. Claude получает
/// их вместе со сводкой и решает, что из этого стоит совета.
public struct RoutineCandidate: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case repeatedCommand
        case slowCommand
        case failingCommand
        case switching
        case copying
        case frequentSite
        case dailyLaunches
        case morningSites
        case callLoad
    }

    public let kind: Kind
    /// По-человечески и с цифрами: «Команда `make test` — 12 раз за день».
    public let evidence: String
    /// Грубая оценка, сколько минут в неделю можно вернуть. Нужна только для сортировки.
    public let weeklyMinutes: Double

    public init(kind: Kind, evidence: String, weeklyMinutes: Double) {
        self.kind = kind
        self.evidence = evidence
        self.weeklyMinutes = weeklyMinutes
    }
}

/// Сжатый след одного дня — для привычек «каждый день одно и то же».
public struct DayDigest: Hashable, Sendable {
    public let day: LocalDate
    /// Приложения, запущенные вручную в этот день (не те, что уже были открыты).
    public let launchedApps: Set<String>
    /// Сайты, открытые в первые 30 минут активности.
    public let morningSites: Set<String>
    /// Сколько раз выполнялся каждый шаблон команды.
    public let commandCounts: [String: Int]

    public init(day: LocalDate, launchedApps: Set<String>, morningSites: Set<String>, commandCounts: [String: Int]) {
        self.day = day
        self.launchedApps = launchedApps
        self.morningSites = morningSites
        self.commandCounts = commandCounts
    }
}

/// Простые эвристики «это похоже на рутину». Пороги подобраны с запасом,
/// чтобы не шуметь: кандидатов лучше меньше, но настоящих. Подкручиваются
/// по реальным дням (SPEC §8).
public enum RoutineDetector {
    public static func candidates(today: DaySummary, history: [DayDigest], limit: Int = 8) -> [RoutineCandidate] {
        var result: [RoutineCandidate] = []

        for command in today.commands where command.count >= 5 {
            let daysSeen = history.filter { ($0.commandCounts[command.template] ?? 0) >= 2 }.count
            let count = times(command.count)
            var evidence = L("Команда `\(command.template)` — \(count) за день", "Command `\(command.template)` — \(count) a day")
            if daysSeen >= 3 {
                evidence += L(", и так \(daysSeen) из последних \(history.count) дней", ", and so on \(daysSeen) of the last \(history.count) days")
            }
            // Набрать или найти в истории длинную команду — секунд 15.
            result.append(RoutineCandidate(kind: .repeatedCommand, evidence: evidence, weeklyMinutes: Double(command.count) * 0.25 * 5))
        }
        for command in today.commands where command.totalDurationMs >= 10 * 60_000 {
            let seconds = Double(command.totalDurationMs) / 1_000
            let total = DurationFormat.short(seconds)
            let runs = "\(command.count) " + Words.plural(command.count, ru: ("запуск", "запуска", "запусков"), en: ("run", "runs"))
            result.append(RoutineCandidate(
                kind: .slowCommand,
                evidence: L("`\(command.template)` суммарно шла \(total) за \(runs)", "`\(command.template)` ran for \(total) in total over \(runs)"),
                // Кэш или фон обычно срезает треть ожидания.
                weeklyMinutes: seconds / 60 * 5 * 0.3
            ))
        }
        for command in today.commands where command.failures >= 3 {
            let failures = times(command.failures)
            result.append(RoutineCandidate(
                kind: .failingCommand,
                evidence: L("`\(command.template)` падала \(failures) из \(command.count)", "`\(command.template)` failed \(failures) out of \(command.count)"),
                weeklyMinutes: Double(command.failures) * 5
            ))
        }
        for pair in today.switches where pair.count >= 20 {
            let count = times(pair.count)
            result.append(RoutineCandidate(
                kind: .switching,
                evidence: L("Переключался \(pair.first) ↔ \(pair.second) \(count)", "Switched \(pair.first) ↔ \(pair.second) \(count)"),
                weeklyMinutes: Double(pair.count) * 0.05 * 5
            ))
        }
        for flow in today.pastes where flow.count >= 4 {
            let count = times(flow.count)
            result.append(RoutineCandidate(
                kind: .copying,
                evidence: L("Копировал из \(flow.fromApp) в \(flow.toApp) \(count)", "Copied from \(flow.fromApp) to \(flow.toApp) \(count)"),
                weeklyMinutes: Double(flow.count) * 0.5 * 5
            ))
        }
        for site in today.sites where site.visits >= 10 {
            let count = times(site.visits)
            let time = DurationFormat.short(site.seconds)
            result.append(RoutineCandidate(
                kind: .frequentSite,
                evidence: L("Заходил на \(site.host) \(count) (\(time))", "Visited \(site.host) \(count) (\(time))"),
                weeklyMinutes: Double(site.visits) * 0.1 * 5
            ))
        }

        // «Почти каждый день» — хотя бы 3 из последних 5 дней.
        let recent = Array(history.suffix(5))
        if recent.count >= 3 {
            let apps = frequent(recent.map(\.launchedApps), atLeast: 3)
            if !apps.isEmpty {
                let list = apps.joined(separator: ", ")
                result.append(RoutineCandidate(
                    kind: .dailyLaunches,
                    evidence: L("Почти каждый день вручную запускаешь: \(list)", "Almost every day you launch by hand: \(list)"),
                    weeklyMinutes: Double(apps.count) * 0.2 * 5
                ))
            }
            let sites = frequent(recent.map(\.morningSites), atLeast: 3)
            if !sites.isEmpty {
                let list = sites.joined(separator: ", ")
                result.append(RoutineCandidate(
                    kind: .morningSites,
                    evidence: L("По утрам открываешь одни и те же сайты: \(list)", "Every morning you open the same sites: \(list)"),
                    weeklyMinutes: Double(sites.count) * 0.3 * 5
                ))
            }
        }

        if today.callSeconds >= 2 * 3_600 {
            let total = DurationFormat.short(today.callSeconds)
            let calls = "\(today.callCount) " + Words.plural(today.callCount, ru: ("звонок", "звонка", "звонков"), en: ("call", "calls"))
            result.append(RoutineCandidate(
                kind: .callLoad,
                evidence: L("Созвоны заняли \(total) (\(calls))", "Calls took \(total) (\(calls))"),
                weeklyMinutes: 0
            ))
        }

        return Array(result.sorted { $0.weeklyMinutes > $1.weeklyMinutes }.prefix(limit))
    }

    /// «12 раз» / «12 times».
    private static func times(_ count: Int) -> String {
        "\(count) " + Words.plural(count, ru: ("раз", "раза", "раз"), en: ("time", "times"))
    }

    /// Что встречается хотя бы в `atLeast` наборах из списка.
    static func frequent(_ sets: [Set<String>], atLeast: Int) -> [String] {
        var counts: [String: Int] = [:]
        for set in sets {
            for item in set { counts[item, default: 0] += 1 }
        }
        return counts.filter { $0.value >= atLeast }.keys.sorted()
    }
}
