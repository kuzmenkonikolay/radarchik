import Dispatch
import Foundation
import RadarchikCore

/// «Защита» из терминала — как старый `guard`, только без sudo: открывает
/// root-часть по Touch ID (SPEC §3б, этап 2).
///
///     Radarchik --guard status
///     Radarchik --guard unlock ssh [минуты|manual]    по умолчанию на 5 минут
///     Radarchik --guard lock [ssh|all]               по умолчанию всё
///     Radarchik --guard export-config                список для make install-guard
///
/// С алиасом в ~/.zshrc руки помнят старое:
///     alias guard='~/Applications/Radarchik.app/Contents/MacOS/Radarchik --guard'
enum GuardCommand {
    static func run(_ arguments: [String]) -> Int32 {
        Language.setAppWide(CodeScanCommand.storedLanguage())
        switch arguments.first {
        case nil, "status":
            return GuardStatusCommand.run()
        case "unlock":
            let category = arguments.dropFirst().first ?? ""
            guard let categories = GuardHelper.categories(category) else { return usage() }
            let argument = arguments.dropFirst(2).first
            let minutes = argument == "manual" ? 0 : argument.flatMap(Int.init) ?? GuardHelper.defaultMinutes
            return perform {
                try await GuardHelperClient.unlock(category, minutes: minutes)
            } done: {
                L("Открыто: ", "Opened: ") + GuardPhrase.unlockPrompt(categories, minutes: GuardHelper.minutes(minutes))
            }
        case "lock":
            let category = arguments.dropFirst().first ?? "all"
            guard GuardHelper.categories(category) != nil else { return usage() }
            return perform {
                try await GuardHelperClient.lock(category)
            } done: {
                L("Закрыто.", "Locked.")
            }
        case "export-config":
            print(exportConfig().render(), terminator: "")
            return 0
        default:
            return usage()
        }
    }

    /// Список для root-части: её текущий (переустановка), иначе старого guard,
    /// иначе встроенный — и исключения: ключи проектов, которые лежат в git
    /// (test.key в storefront). Запускается от тебя: git спрашиваем мы, root
    /// его не запускает никогда.
    ///
    /// Исключения — только у ключей проектов и только из настоящего проекта.
    /// Иначе программа под тобой сделала бы `git init` прямо в домашней папке,
    /// вписала бы в индекс `~/.ssh/id_ed25519` (`git update-index --cacheinfo`
    /// не читает файл) — и SSH-ключ «лежал бы в git», то есть вышел бы из-под защиты.
    static func exportConfig() -> GuardConfig {
        let source: GuardSource = GuardHelper.isInstalled ? .helper : LegacyGuard.isInstalled ? .legacyGuard : .builtIn
        var config = source.config()
        let home = NSHomeDirectory()
        config.excluded = config.excluded.filter { isProjectFile($0, home: home) }
        for rule in config.rules where rule.category == .env && rule.pattern.hasPrefix("~/") {
            for path in LockProbe.files(matching: GuardRules.expandHome(rule.pattern, home: home))
            where isProjectFile(path, home: home) && Git.isTracked(path) {
                config.excluded.insert(path)
            }
        }
        return config
    }

    /// Файл лежит в репозитории проекта: корень репозитория — не сама домашняя
    /// папка и не скрытая папка в ней (`~/.ssh`, `~/.config`).
    private static func isProjectFile(_ path: String, home: String) -> Bool {
        guard let root = Git.repositoryRoot(containing: path) else { return false }
        return root != home && !root.hasPrefix(home + "/.") && root.hasPrefix(home + "/")
    }

    /// Запрос к root-части с ожиданием ответа: окно Touch ID может висеть сколько угодно.
    private static func perform(_ request: @escaping @Sendable () async throws -> String?, done: @escaping @Sendable () -> String) -> Int32 {
        let finished = DispatchSemaphore(value: 0)
        let status = ExitStatus()
        Task.detached {
            do {
                let warning = try await request()
                print(done())
                if let warning { print(warning) }
            } catch is CancellationError {
                print(L("Отменено.", "Cancelled."))
                status.value = 1
            } catch {
                print(error.localizedDescription)
                status.value = 1
            }
            finished.signal()
        }
        finished.wait()
        return status.value
    }

    private static func usage() -> Int32 {
        print("""
            Radarchik --guard status
            Radarchik --guard unlock <ssh|env|aws|kube|gpg|…|all> [minutes|manual]
            Radarchik --guard lock [<category>|all]
            Radarchik --guard export-config
            """)
        return 2
    }
}

/// Код выхода из фоновой задачи. Пишет она, читаем после семафора — гонки нет.
private final class ExitStatus: @unchecked Sendable {
    var value: Int32 = 0
}
