import Foundation

/// Что посреднику делать с просьбой «подпиши» (SPEC §3б, 2026-10-21).
///
/// Ключ из ssh-agent доступен любой программе под тобой, и закрытый файл ему не
/// мешает: так Claude Code подписывал коммиты без Touch ID. Поэтому посредник не
/// только смотрит, но и спрашивает: чужому источнику защищённый ключ — только после
/// Touch ID, пока клиент ждёт ответа. Своё — команда из терминала, команда, для
/// которой ты уже открыл ключ по Touch ID, источник из списка «Всегда» — проходит.
/// Одно подтверждение действует `grace` для того же источника и того же действия:
/// пять коммитов подряд — одно окно.
public enum AgentGate {
    public enum Verdict: Equatable, Sendable {
        /// Передать агенту.
        case pass
        /// Спросить Touch ID через root-часть; отказ — отказ агента.
        case ask
        /// Root-части нет: передать, а потом тревога — как раньше.
        case alarm
    }

    /// На сколько хватает одного подтверждения для того же источника и действия.
    public static let grace: TimeInterval = 10 * 60

    public static func verdict(
        origin: AgentOrigin, isProtected: Bool, approved: Bool, allowedAlways: Bool, confirmedUntil: Date?, now: Date, canAsk: Bool
    ) -> Verdict {
        guard isProtected, AgentWatchRules.isAlarm(origin), !approved, !allowedAlways else { return .pass }
        if let confirmedUntil, confirmedUntil > now { return .pass }
        return canAsk ? .ask : .alarm
    }
}
