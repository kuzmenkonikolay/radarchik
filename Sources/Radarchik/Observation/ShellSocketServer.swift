import Darwin
import Foundation
import RadarchikCore

/// Принимает выполненные команды от zsh-хука через Unix-сокет
/// `~/Library/Application Support/Radarchik/shell.sock`.
///
/// Сырые команды живут только в памяти: секреты вычищаются (`ShellRedactor`)
/// до записи в базу. Сокет есть, только пока наблюдение включено. Если
/// Радарчик не запущен, хук молча ничего не отправляет.
final class ShellSocketServer: @unchecked Sendable {
    let path: String
    private let onMessage: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.kuzmenko.radarchik.shell", qos: .utility)
    // Ниже — только из `queue`.
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    init(path: String, onMessage: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            listenFD = -1
        }
    }

    private func startOnQueue() throws {
        guard source == nil else { return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure(description: L("Слишком длинный путь к сокету: ", "Socket path is too long: ") + path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "bind: \(message)")
        }
        // Писать в сокет может только сам пользователь.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw Failure(description: "listen: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let socketPath = path
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler {
            close(fd)
            unlink(socketPath)
        }
        source.resume()
        self.source = source
    }

    /// Принимаем всех, кто ждёт: каждое подключение — одна команда, хук сразу закрывает его.
    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EWOULDBLOCK — очередь пуста
            // Принятый сокет на macOS наследует O_NONBLOCK — снимаем, читаем с таймаутом.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.count < 64 * 1024 {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            close(client)
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                onMessage(text)
            }
        }
    }
}

/// zsh-хук. Приложение кладёт его в Application Support при каждом запуске,
/// а пользователь один раз подключает строкой в ~/.zshrc (`sourceLine`).
enum ShellHook {
    /// Папка Радарчика в Application Support — та же, где база.
    static var folder: URL {
        (try? LedgerRepository.defaultDatabaseURL().deletingLastPathComponent())
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
    static var socketPath: String { folder.appendingPathComponent("shell.sock").path }
    static var scriptURL: URL { folder.appendingPathComponent("radarchik.zsh") }

    /// Строка для ~/.zshrc. Если Радарчика удалить, она ничего не сломает.
    static let sourceLine = #"[[ -r "$HOME/Library/Application Support/Radarchik/radarchik.zsh" ]] && source "$HOME/Library/Application Support/Radarchik/radarchik.zsh""#

    static func install() throws {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    /// Хук отправляет команду только после её завершения, с длительностью и кодом выхода.
    static let script = #"""
    # Радарчик: передаёт выполненные команды в приложение (SPEC.md, раздел 3).
    # Файл перезаписывается при каждом запуске Радарчика — правки сюда не вносить.
    #
    # Подключение — одна строка в ~/.zshrc:
    #   [[ -r "$HOME/Library/Application Support/Radarchik/radarchik.zsh" ]] && source "$HOME/Library/Application Support/Radarchik/radarchik.zsh"
    #
    # Команда уходит, только если Радарчик запущен и наблюдение включено (есть сокет).
    # Секреты вычищаются в приложении до записи на диск.
    # Команда с пробелом в начале не отправляется. Выключить на время: export RADARCHIK_OFF=1

    zmodload zsh/datetime 2>/dev/null || return 0
    zmodload zsh/net/socket 2>/dev/null || return 0

    typeset -g _radarchik_socket="$HOME/Library/Application Support/Radarchik/shell.sock"
    typeset -g _radarchik_command=""
    typeset -g _radarchik_started=""

    _radarchik_preexec() {
      _radarchik_command=""
      [[ -n $RADARCHIK_OFF || $1 == ' '* ]] && return 0
      _radarchik_command=$1
      _radarchik_started=$EPOCHREALTIME
    }

    _radarchik_precmd() {
      local exit_code=$?
      if [[ -z $_radarchik_command || ! -S $_radarchik_socket ]]; then
        _radarchik_command=""
        return 0
      fi
      local duration=$(( (EPOCHREALTIME - _radarchik_started) * 1000 ))
      duration=${duration%%.*}
      local command=${_radarchik_command//$'\n'/ }
      command=${command//$'\t'/ }
      _radarchik_command=""
      local payload="1"$'\t'"${_radarchik_started}"$'\t'"${duration}"$'\t'"${exit_code}"$'\t'"${PWD}"$'\t'"${command}"
      if zsocket "$_radarchik_socket" 2>/dev/null; then
        local fd=$REPLY
        print -rn -- "$payload" >&$fd 2>/dev/null
        exec {fd}>&-
      fi
      return 0
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _radarchik_preexec
    add-zsh-hook precmd _radarchik_precmd
    """#
}
