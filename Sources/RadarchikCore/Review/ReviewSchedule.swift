import Foundation

/// Когда разбирать день (SPEC §3): раз в день в заданный час по часам
/// компьютера (по умолчанию 22:00). Если в этот момент мак спал — при первой
/// активности после, например утром. Разбор берёт всё с прошлого разбора.
public enum ReviewSchedule {
    /// Дальше двух суток назад не смотрим, даже если разбора давно не было.
    public static let maxPeriod: TimeInterval = 48 * 3_600

    /// Последняя граница разбора, которая уже наступила: сегодня в `hour`:00,
    /// если это время прошло, иначе вчера в `hour`:00.
    public static func latestBoundary(now: Date, hour: Int, calendar: Calendar) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    }

    public static func isDue(lastReview: Date?, now: Date, hour: Int, calendar: Calendar) -> Bool {
        guard let lastReview else {
            // Самый первый разбор — вечером, когда за день уже что-то накопилось.
            return now >= calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        }
        return lastReview < latestBoundary(now: now, hour: hour, calendar: calendar)
    }

    /// Что разбираем: с прошлого разбора (но не раньше двух суток назад) до сейчас.
    /// Первый разбор — с начала сегодняшнего дня.
    public static func period(lastReview: Date?, now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let earliest = now.addingTimeInterval(-maxPeriod)
        let start = lastReview.map { max($0, earliest) } ?? calendar.startOfDay(for: now)
        return min(start, now)...now
    }
}
