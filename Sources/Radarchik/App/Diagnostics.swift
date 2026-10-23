import Darwin
import Foundation
import os

/// Журнал Радарчика в системном журнале macOS — его видно в Console.app и через
///
///     /usr/bin/log show --last 15m --style compact --predicate 'subsystem == "dev.kuzmenko.radarchik"'
///
/// (в zsh `log` — своя встроенная команда, поэтому полный путь).
/// Командные строки и пути пишутся как `.private` — в журнале они скрыты;
/// шаги, категории ключей и коды ошибок — открыто.
enum Log {
    /// «Защита»: хук терминала, Touch ID, root-часть.
    static let guardFlow = Logger(subsystem: "dev.kuzmenko.radarchik", category: "guard")
}

/// Ловушка на SIGPIPE. 2026-10-20 Радарчик умер от SIGPIPE через секунду после
/// Touch ID для `git commit`. Причина: хук пишет «done» и сразу закрывает соединение;
/// если он успевал раньше, чем Радарчик его принял, ядро не давало включить
/// SO_NOSIGPIPE, и ответ «ok» убивал процесс (см. `LineSocketServer`). Это исправлено,
/// а ловушка осталась насовсем: если что-то ещё запишет в закрытое соединение,
/// Радарчик не упадёт (запись вернёт EPIPE), а стек ляжет в `~/Library/Logs/Radarchik/sigpipe.log`.
///
/// В обработчике сигнала нельзя выделять память и брать блокировки — поэтому
/// файл открыт и буфер для стека выделен заранее, а пишет только
/// `backtrace_symbols_fd` (она для этого и сделана).
enum SigpipeTrap {
    static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Radarchik/sigpipe.log").path
    }

    static func install() {
        let path = logPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        trapFile = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        trapFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(trapFrameCount))
        // Первый вызов backtrace может что-то подгрузить — пусть это будет здесь, а не в обработчике.
        if let frames = trapFrames { _ = backtrace(frames, trapFrameCount) }
        signal(SIGPIPE, sigpipeHandler)
    }
}

private let trapFrameCount: Int32 = 64
nonisolated(unsafe) private var trapFile: Int32 = -1
nonisolated(unsafe) private var trapFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

/// Только то, что можно в обработчике сигнала: write и backtrace в заранее открытый файл.
private func sigpipeHandler(_ signal: Int32) {
    guard trapFile >= 0, let frames = trapFrames else { return }
    let header: StaticString = "--- SIGPIPE ---\n"
    _ = write(trapFile, header.utf8Start, header.utf8CodeUnitCount)
    let count = backtrace(frames, trapFrameCount)
    backtrace_symbols_fd(frames, count, trapFile)
}
