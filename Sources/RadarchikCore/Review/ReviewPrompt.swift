import Foundation

/// Статус совета (SPEC §3). «Не надо» больше не предлагается; «сделаю» и «уже сделал» не повторяются.
public enum TipStatus: String, CaseIterable, Sendable {
    case new
    case planned
    case done
    case dismissed

    public var title: String {
        switch self {
        case .new: L("новый", "new")
        case .planned: L("сделаю", "will do")
        case .done: L("уже сделал", "done")
        case .dismissed: L("не надо", "not needed")
        }
    }
}

public struct PreviousTip: Hashable, Sendable {
    public let title: String
    public let status: TipStatus

    public init(title: String, status: TipStatus) {
        self.title = title
        self.status = status
    }
}

/// Всё, что уходит в Claude. Только агрегаты: ни сырого лога, ни секретов
/// (команды уже шаблоны), а заголовки окон — только если это разрешено в настройках.
public struct ReviewInput: Sendable {
    public var periodStart: Date
    public var periodEnd: Date
    public var summary: DaySummary
    public var candidates: [RoutineCandidate]
    /// Самые долгие заголовки окон; пусто — заголовки не отправляем.
    public var windowTitles: [String]
    public var previousTips: [PreviousTip]

    public init(
        periodStart: Date, periodEnd: Date, summary: DaySummary, candidates: [RoutineCandidate],
        windowTitles: [String], previousTips: [PreviousTip]
    ) {
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.summary = summary
        self.candidates = candidates
        self.windowTitles = windowTitles
        self.previousTips = previousTips
    }
}

/// Запрос разбора дня. Советы приходят на языке интерфейса: по-английски
/// и запрос английский (2026-10-19).
public enum ReviewPrompt {
    public static var system: String {
        switch Language.current {
        case .ru: systemRussian
        case .en: systemEnglish
        }
    }

    private static let systemRussian = """
        Ты — Радарчик, маленький помощник в чёлке MacBook. Твой человек — разработчик и предприниматель: ведёт несколько своих проектов, много работает в терминале, браузере и с Claude Code.
        Раз в день ты получаешь сводку того, что он делал на компьютере, и ищешь рутину, которую можно убрать: скриптом, алиасом, горячей клавишей, Shortcuts, уведомлением или другим порядком работы.

        Как отвечать:
        - Дай 3–5 советов, только по данным из сводки. Если явной рутины нет, советов может быть меньше. Не придумывай фактов, которых в данных нет.
        - observation — что видно, с цифрами из сводки («12 раз за день», «34 переключения»).
        - suggestion — конкретный следующий шаг: готовая команда, алиас, набросок скрипта или куда нажать. Без общих слов вроде «оптимизируй процесс» или «делай перерывы».
        - time_saved_per_week_min — честная оценка в минутах за неделю, без преувеличений.
        - effort — «низкий», «средний» или «высокий».
        - tool_hint — коротко, чем делать (zsh alias, Raycast, Shortcuts, launchd, n8n…), или пустая строка.
        - Не повторяй прошлые советы: «не надо» — человек отказался, «сделаю» и «уже сделал» — уже в работе.
        - В шаблонах команд «…» и N стоят на месте значений, строк и чисел — их нарочно убрали, не угадывай.
        - Пиши по-русски, коротко, на «ты», дружелюбно.
        """

    private static let systemEnglish = """
        You are Radarchik, a tiny helper living in the MacBook notch. Your person is a developer and founder: they run several projects of their own and spend a lot of time in the terminal, the browser and Claude Code.
        Once a day you get a summary of what they did on the computer, and you look for routine that can be removed: with a script, an alias, a hotkey, Shortcuts, a notification or a different way of working.

        How to answer:
        - Give 3–5 tips, based only on the data in the summary. If there is no clear routine, give fewer. Don't invent facts that aren't in the data.
        - observation — what you see, with numbers from the summary ("12 times a day", "34 switches").
        - suggestion — a concrete next step: a ready command, an alias, a script sketch or where to click. No generic advice like "optimize your process" or "take breaks".
        - time_saved_per_week_min — an honest estimate in minutes per week, no exaggeration.
        - effort — "low", "medium" or "high".
        - tool_hint — briefly, what to use (zsh alias, Raycast, Shortcuts, launchd, n8n…), or an empty string.
        - Don't repeat past tips: "not needed" means the person declined, "will do" and "done" are already in progress.
        - In command templates, "…" and N stand in for values, strings and numbers — they were removed on purpose, don't guess them.
        - Write in English, briefly, casually and kindly.
        """

    public static func userMessage(_ input: ReviewInput, calendar: Calendar = .current) -> String {
        let summary = input.summary
        let period = dateRange(input.periodStart, input.periodEnd, calendar)
        let active = DurationFormat.short(summary.activeSeconds)
        var lines = [
            L("Период: \(period). За компьютером \(active).", "Period: \(period). At the computer for \(active)."),
        ]

        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("")
            lines.append("\(title):")
            lines.append(contentsOf: items.map { "- \($0)" })
        }

        section(L("Приложения (время)", "Apps (time)"), summary.apps.prefix(12).map { "\($0.appName) — \(DurationFormat.short($0.seconds))" })
        section(L("Сайты (время · заходы)", "Sites (time · visits)"), summary.sites.prefix(12).map { "\($0.host) — \(DurationFormat.short($0.seconds)) · \($0.visits)" })
        section(L("Команды терминала (шаблоны без значений)", "Terminal commands (templates without values)"), summary.commands.prefix(15).map { command in
            var line = "`\(command.template)` — ×\(command.count)"
            if command.totalDurationMs >= 60_000 {
                line += L(", всего ", ", total ") + DurationFormat.short(Double(command.totalDurationMs) / 1_000)
            }
            if command.failures > 0 { line += L(", ошибок \(command.failures)", ", failures \(command.failures)") }
            return line
        })
        section(L("Переключения туда-обратно", "Back-and-forth switches"), summary.switches.prefix(8).map { "\($0.first) ↔ \($0.second) — ×\($0.count)" })
        section(L("Копирование между приложениями (оценка)", "Copying between apps (estimate)"), summary.pastes.prefix(8).map { "\($0.fromApp) → \($0.toApp) — ×\($0.count)" })
        if summary.callCount > 0 {
            let total = DurationFormat.short(summary.callSeconds)
            lines.append("")
            lines.append(L("Звонки: \(summary.callCount), всего \(total).", "Calls: \(summary.callCount), \(total) in total."))
        }
        section(L("Заголовки окон (самые долгие)", "Window titles (longest)"), input.windowTitles)
        section(L("Кандидаты в рутину (эвристики Радарчика)", "Routine candidates (Radarchik’s heuristics)"), input.candidates.map(\.evidence))
        section(
            L("Прошлые советы (не повторять)", "Past tips (don’t repeat)"),
            input.previousTips.filter { $0.status != .new }.map { "\(Words.quoted($0.title)) — \($0.status.title)" }
        )
        return lines.joined(separator: "\n")
    }

    /// «18 октября 2026, 09:12–22:00» или «17 октября 22:05 — 19 октября 08:00».
    /// По-английски — «October 18, 2026, 09:12–22:00».
    static func dateRange(_ start: Date, _ end: Date, _ calendar: Calendar) -> String {
        let s = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let e = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        func time(_ c: DateComponents) -> String { String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
        func day(_ c: DateComponents, withYear: Bool = false) -> String {
            Words.dayMonth(c.day ?? 0, c.month ?? 1, year: withYear ? c.year : nil)
        }
        if s.year == e.year && s.month == e.month && s.day == e.day {
            return "\(day(s, withYear: true)), \(time(s))–\(time(e))"
        }
        return "\(day(s)) \(time(s)) — \(day(e)) \(time(e))"
    }
}
