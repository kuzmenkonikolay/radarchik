import Darwin
import Foundation
import RadarchikCore

/// Проверка кода из git-хука (SPEC §3б):
///
///     Radarchik --codescan post-merge <squash>               после git pull
///     Radarchik --codescan post-checkout <old> <new> <flag>  после checkout и clone
///     Radarchik --codescan scan [папка]                      вручную, весь проект
///
/// `--print-only` — только напечатать, без журнала и чёлки (для проверки руками).
///
/// Работает без окна и AppKit:
/// 1. берёт изменённые файлы у git и проверяет их;
/// 2. печатает итог в терминал;
/// 3. пишет его в журнал «Защиты»;
/// 4. говорит запущенному Радарчику, чтобы показал в чёлке.
///
/// Код выхода всегда 0: проверка никогда не ломает git.
///
/// Чем отличается от codescan.sh старого guard: там post-merge получал флаг
/// squash («0») и делал `git diff 0 HEAD` — после git pull код не проверялся
/// вовсе. Здесь сравнивается ORIG_HEAD с HEAD, а clone проверяется целиком
/// (post-checkout со старым коммитом из нулей).
enum CodeScanCommand {
    private struct Target {
        let root: String
        let files: [String]
        let trigger: CodeScanTrigger
    }

    static func run(_ allArguments: [String]) -> Int32 {
        Language.setAppWide(storedLanguage())
        let printOnly = allArguments.contains("--print-only")
        let arguments = allArguments.filter { $0 != "--print-only" }
        guard let mode = arguments.first else {
            printUsage()
            return 0
        }
        let rest = Array(arguments.dropFirst())
        let target: Target? = switch mode {
        case "post-merge": afterPull()
        case "post-checkout": afterCheckout(rest)
        case "scan": fullScan(rest.first ?? FileManager.default.currentDirectoryPath)
        default: nil
        }
        guard let target else {
            if !["post-merge", "post-checkout", "scan"].contains(mode) { printUsage() }
            return 0
        }
        let report = scan(target)
        // Проверять было нечего (поменялись только картинки и данные) — молчим.
        guard report.filesChecked > 0 else { return 0 }
        printReport(report)
        if !printOnly { record(report) }
        return 0
    }

    // MARK: - Что проверять

    private static func afterPull() -> Target? {
        guard let root = topLevel(FileManager.default.currentDirectoryPath),
              let files = changed(from: "ORIG_HEAD", to: "HEAD", in: root)
        else { return nil }
        return Target(root: root, files: files, trigger: .pull)
    }

    /// post-checkout: старый коммит, новый, 1 — сменили ветку (а не файл).
    /// Старый из нулей — это git clone: проверяем всё.
    private static func afterCheckout(_ arguments: [String]) -> Target? {
        guard arguments.count >= 3, arguments[2] == "1", arguments[0] != arguments[1],
              let root = topLevel(FileManager.default.currentDirectoryPath)
        else { return nil }
        if arguments[0].allSatisfy({ $0 == "0" }) {
            return tracked(in: root).map { Target(root: root, files: $0, trigger: .clone) }
        }
        return changed(from: arguments[0], to: arguments[1], in: root).map { Target(root: root, files: $0, trigger: .checkout) }
    }

    private static func fullScan(_ path: String) -> Target? {
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path
        if let root = topLevel(folder), let files = tracked(in: root) {
            return Target(root: root, files: files, trigger: .manual)
        }
        // Не git — обходим папку сами, без скрытых, node_modules и vendor.
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return nil }
        var files: [String] = []
        for case let relative as String in enumerator where CodeScanner.shouldScan(relative) {
            files.append(relative)
        }
        return Target(root: folder, files: files, trigger: .manual)
    }

    private static func topLevel(_ folder: String) -> String? {
        guard let result = Git.run(["rev-parse", "--show-toplevel"], in: folder), result.status == 0 else { return nil }
        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    /// Добавленные и изменённые файлы между коммитами (удалённые проверять незачем).
    private static func changed(from old: String, to new: String, in root: String) -> [String]? {
        guard let result = Git.run(["-c", "core.fsmonitor=false", "diff", "--name-only", "--diff-filter=ACMR", "-z", old, new], in: root),
              result.status == 0
        else { return nil }
        return result.output.split(separator: "\0").map(String.init)
    }

    private static func tracked(in root: String) -> [String]? {
        guard let result = Git.run(["-c", "core.fsmonitor=false", "ls-files", "-z"], in: root), result.status == 0 else { return nil }
        return result.output.split(separator: "\0").map(String.init)
    }

    // MARK: - Проверка

    private static func scan(_ target: Target) -> CodeScanReport {
        var checked = 0
        var skipped = 0
        var findings: [CodeFinding] = []
        for file in target.files where CodeScanner.shouldScan(file) {
            let path = target.root + "/" + file
            // Ссылки не читаем: в чужом репозитории ссылка может вести куда угодно.
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            guard info.st_size <= CodeScanner.maxFileSize, let data = FileManager.default.contents(atPath: path) else {
                skipped += 1
                continue
            }
            checked += 1
            findings += CodeScanner.scan(path: file, content: String(decoding: data, as: UTF8.self))
        }
        // Опасное — первым.
        findings.sort { $0.threat.level > $1.threat.level }
        return CodeScanReport(repository: target.root, trigger: target.trigger, filesChecked: checked, skipped: skipped, findings: findings)
    }

    // MARK: - Терминал

    private static func printReport(_ report: CodeScanReport) {
        let colors = isatty(STDOUT_FILENO) == 1
        func paint(_ text: String, _ code: String) -> String { colors ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
        // После «Радарчик:» фраза продолжается — со строчной буквы.
        let phrase = GuardPhrase.scan(report)
        let headline = L("Радарчик: ", "Radarchik: ") + phrase.prefix(1).lowercased() + phrase.dropFirst()
        switch report.level {
        case .critical: print(paint(headline, "1;31"))
        case .warning: print(paint(headline, "1;33"))
        case .info: print(paint(headline, "32"))
        }
        let groups = report.groups
        for group in groups.prefix(10) {
            let mark = group.level == .critical ? paint("✗", "31") : paint("!", "33")
            print("  \(mark) " + GuardPhrase.group(group))
        }
        if groups.count > 10 {
            print(L("  …и ещё \(groups.count - 10) — на экране «Защита»", "  …and \(groups.count - 10) more — on the Guard screen"))
        }
    }

    private static func printUsage() {
        print("""
            Radarchik --codescan post-merge <squash>
            Radarchik --codescan post-checkout <old> <new> <flag>
            Radarchik --codescan scan [folder]
            --print-only   print the result, don’t log it or show it in the notch
            """)
    }

    // MARK: - Журнал и чёлка

    /// В журнал «Защиты» — та же база, что у приложения: SQLite подождёт, если оно пишет.
    /// Опасное ждёт ответа в чёлке, остальное — просто запись.
    private static func record(_ report: CodeScanReport) {
        guard let path = try? LedgerRepository.defaultDatabaseURL().path,
              let repository = try? GuardRepository(database: Database(path: path))
        else { return }
        let detail = report.groups.prefix(5).map(GuardPhrase.group).joined(separator: "\n")
        guard let event = try? repository.add(
            kind: .code, level: report.level, at: Date(), title: GuardPhrase.scan(report), detail: detail.isEmpty ? nil : detail,
            allowKey: nil, status: report.level == .critical ? .active : .logged
        ) else { return }
        notifyApp("code \(event.id)")
    }

    /// Сказать запущенному Радарчику через его сокет. Не запущен — не страшно:
    /// запись уже в журнале, опасное он покажет при запуске.
    private static func notifyApp(_ message: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Радарчик закрыл соединение раньше — запись не должна убить git-хук (SIGPIPE).
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(GuardSocket.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return }
        _ = message.withCString { write(fd, $0, strlen($0)) }
    }

    /// Язык из настроек приложения: хук запускается вне его, а говорить должен так же.
    static func storedLanguage() -> Language {
        let stored = CFPreferencesCopyAppValue("language" as CFString, "dev.kuzmenko.radarchik" as CFString) as? String
        return (stored.flatMap(LanguageChoice.init(rawValue:)) ?? .system).resolved()
    }
}

/// Сокет, через который git-хук говорит запущенному Радарчику «проверил код».
/// Лежит рядом с базой; писать в него может только сам пользователь.
enum GuardSocket {
    static var path: String { ShellHook.folder.appendingPathComponent("guard.sock").path }
}
