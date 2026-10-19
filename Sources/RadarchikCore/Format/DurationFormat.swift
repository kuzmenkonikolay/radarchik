import Foundation

/// Длительности и «сколько назад» для экранов наблюдения.
/// По-английски — как «Экранное время» в macOS: «1h 5m», «5m ago».
public enum DurationFormat {
    /// «меньше минуты», «12 мин», «1 ч 05 мин», «2 ч».
    public static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return L("меньше минуты", "under a minute") }
        let hours = minutes / 60
        let rest = minutes % 60
        switch Language.current {
        case .ru:
            if hours == 0 { return "\(minutes) мин" }
            return rest == 0 ? "\(hours) ч" : String(format: "%d ч %02d мин", hours, rest)
        case .en:
            if hours == 0 { return "\(minutes)m" }
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
    }

    /// «только что», «5 мин назад», «2 ч назад», «3 дн. назад».
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return L("только что", "just now") }
        if seconds < 3_600 { return L("\(Int(seconds / 60)) мин назад", "\(Int(seconds / 60))m ago") }
        if seconds < 86_400 { return L("\(Int(seconds / 3_600)) ч назад", "\(Int(seconds / 3_600))h ago") }
        return L("\(Int(seconds / 86_400)) дн. назад", "\(Int(seconds / 86_400))d ago")
    }
}
