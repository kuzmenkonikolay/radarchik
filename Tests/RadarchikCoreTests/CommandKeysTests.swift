import Foundation
import Testing
@testable import RadarchikCore

/// Этап 3 «Защиты» (SPEC §3б): какой команде терминала какие ключи нужны.
/// Набрал `git push` — Радарчик сам спросит Touch ID и откроет SSH-ключи
/// на время команды. Ключи проекта (`rails credentials:edit`) — только этого проекта.
@Suite("Защита: ключи под команду")
struct CommandKeysTests {
    let project = "/Users/me/work/storefront"

    private func context(
        remote: String? = "git@github.com:me/storefront.git", project: String? = "/Users/me/work/storefront", signing: GitSigning = .off
    ) -> CommandContext {
        CommandContext(cwd: "/Users/me/work/storefront", projectRoot: project, signing: signing) { _ in remote }
    }

    private func needs(_ command: String, _ context: CommandContext? = nil) -> [KeyNeed] {
        CommandKeys.needs(command, context: context ?? self.context())
    }

    // MARK: - SSH

    @Test func gitOverSSHNeedsTheSSHKey() {
        #expect(needs("git push") == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git pull --rebase origin main") == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git fetch --all") == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git -C ../other push") == [KeyNeed(category: .ssh, scope: nil)])
    }

    @Test func gitOverHTTPSOrLocalNeedsNothing() {
        #expect(needs("git push", context(remote: "https://github.com/me/x.git")).isEmpty)
        #expect(needs("git push", context(remote: nil)).isEmpty)
        #expect(needs("git status").isEmpty)
        #expect(needs("git add . && git commit -m 'fix'").isEmpty)
    }

    @Test func cloneLooksAtTheURL() {
        #expect(needs("git clone git@github.com:me/x.git", context(remote: nil)) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git clone https://github.com/me/x.git", context(remote: nil)).isEmpty)
    }

    @Test func chainsAreCheckedSegmentBySegment() {
        #expect(needs("git add . && git commit -m 'wip' && git push") == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("make test; git push origin HEAD") == [KeyNeed(category: .ssh, scope: nil)])
    }

    // MARK: - Подпись коммитов

    /// У пользователя коммиты подписываются SSH-ключом (gpg.format = ssh,
    /// commit.gpgsign = true): `git commit` без открытого ключа падал с
    /// «Couldn't load public key …/id_ed25519.pub».
    @Test func signedCommitsNeedTheSigningKey() {
        let ssh = context(signing: GitSigning(format: .ssh, commits: true, tags: false))
        #expect(needs("git commit -am 'intake: new line'", ssh) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git commit --amend --no-edit", ssh) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git rebase main", ssh) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git merge feature", ssh) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git cherry-pick abc123", ssh) == [KeyNeed(category: .ssh, scope: nil)])
        // Подпись выключили для этой команды — ключ не нужен.
        #expect(needs("git commit --no-gpg-sign -m x", ssh).isEmpty)
        // Без подписи коммит ключей не читает.
        #expect(needs("git commit -m x").isEmpty)
        #expect(needs("git stash", ssh).isEmpty)
    }

    @Test func explicitSigningAndTags() {
        let sshFormat = context(signing: GitSigning(format: .ssh, commits: false, tags: false))
        #expect(needs("git commit -S -m x", sshFormat) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git tag -s v1.0 -m release", sshFormat) == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("git tag v1.0", sshFormat).isEmpty)
        let signedTags = context(signing: GitSigning(format: .ssh, commits: false, tags: true))
        #expect(needs("git tag v1.0 -m release", signedTags) == [KeyNeed(category: .ssh, scope: nil)])
        // Подпись GPG — нужен GPG-ключ, а не SSH.
        let gpg = context(signing: GitSigning(format: .gpg, commits: true, tags: false))
        #expect(needs("git commit -m x", gpg) == [KeyNeed(category: .gpg, scope: nil)])
    }

    @Test func pullWithSigningNeedsTheKeyOnce() {
        let ssh = context(signing: GitSigning(format: .ssh, commits: true, tags: false))
        #expect(needs("git pull && git commit -m x && git push", ssh) == [KeyNeed(category: .ssh, scope: nil)])
    }

    @Test func signingSettingsFromGitConfig() {
        let global = """
            [user]
            \tsigningkey = ~/.ssh/id_ed25519.pub
            [gpg]
            \tformat = ssh
            [commit]
            \tgpgsign = true
            """
        #expect(GitSigning.read([global]) == GitSigning(format: .ssh, commits: true, tags: false))
        // Настройка репозитория важнее общей.
        #expect(GitSigning.read([global, "[commit]\n\tgpgSign = false\n"]) == GitSigning(format: .ssh, commits: false, tags: false))
        #expect(GitSigning.read(["[tag]\n\tgpgsign = yes\n"]) == GitSigning(format: .gpg, commits: false, tags: true))
        #expect(GitSigning.read([]) == .off)
    }

    @Test func publicKeysAreGivenBack() {
        #expect(GuardRules.isPublicKey("/Users/me/.ssh/id_ed25519.pub"))
    }

    @Test func sshToolsNeedTheKey() {
        #expect(needs("ssh deploy@prod") == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("scp dump.sql prod:/tmp/") == [KeyNeed(category: .ssh, scope: nil)])
        #expect(needs("rsync -av ./public/ prod:/srv/app/") == [KeyNeed(category: .ssh, scope: nil)])
        // Копия на этом же маке — без ssh.
        #expect(needs("scp a.txt b.txt").isEmpty)
        #expect(needs("rsync -av ./a/ ./b/").isEmpty)
    }

    // MARK: - Ключи проекта

    @Test func railsCredentialsNeedThisProjectsKeys() {
        let mine = [KeyNeed(category: .env, scope: project)]
        #expect(needs("bin/rails credentials:edit") == mine)
        #expect(needs("EDITOR=vim rails credentials:edit --environment production") == mine)
        #expect(needs("bundle exec rails c") == mine)
        #expect(needs("./bin/rails db:migrate") == mine)
        // Вне проекта Rails не угадать, чьи ключи.
        #expect(needs("rails credentials:edit", context(project: nil)).isEmpty)
        #expect(needs("rails new app").isEmpty)
    }

    @Test func dockerBuildReadsTheWholeFolder() {
        let mine = [KeyNeed(category: .env, scope: project)]
        #expect(needs("docker build -t app .") == mine)
        #expect(needs("docker compose up --build") == mine)
        #expect(needs("docker-compose build web") == mine)
        // Внутри контейнера ключ приходит через -e: на маке ничего открывать не надо.
        #expect(needs("docker compose run --rm -e RAILS_MASTER_KEY=x web bin/rails c").isEmpty)
        #expect(needs("docker compose up").isEmpty)
    }

    @Test func kamalNeedsBoth() {
        #expect(needs("kamal deploy") == [KeyNeed(category: .ssh, scope: nil), KeyNeed(category: .env, scope: project)])
        #expect(needs("kamal version").isEmpty)
    }

    @Test func quotesAndOtherProgramsDoNotConfuse() {
        #expect(needs("echo 'git push'").isEmpty)
        #expect(needs("grep -r \"ssh\" .").isEmpty)
        #expect(needs("swift build && make run").isEmpty)
    }

    // MARK: - Подписи и адреса

    @Test func labelForTheTouchIDWindow() {
        #expect(CommandKeys.label("git push origin main") == "git push")
        #expect(CommandKeys.label("EDITOR=vim bin/rails credentials:edit -e production") == "rails credentials:edit")
        #expect(CommandKeys.label("git add . && git push") == "git push")
        #expect(CommandKeys.label("ssh deploy@prod") == "ssh")
        #expect(CommandKeys.label("docker compose up --build") == "docker compose up")
    }

    @Test func sshURLs() {
        #expect(CommandKeys.isSSHURL("git@github.com:me/x.git"))
        #expect(CommandKeys.isSSHURL("ssh://git@github.com/me/x.git"))
        #expect(CommandKeys.isSSHURL("github.com:me/x.git"))
        #expect(!CommandKeys.isSSHURL("https://github.com/me/x.git"))
        #expect(!CommandKeys.isSSHURL("/Users/me/repos/x.git"))
        #expect(!CommandKeys.isSSHURL("file:///Users/me/x.git"))
    }

    @Test func remoteFromGitConfig() {
        let config = """
            [core]
            \trepositoryformatversion = 0
            [remote "origin"]
            \turl = git@github.com:me/storefront.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            [remote "upstream"]
            \turl = https://github.com/org/storefront.git
            [branch "main"]
            \tremote = origin
            """
        #expect(GitConfigFile.remoteURL(config, name: nil) == "git@github.com:me/storefront.git")
        #expect(GitConfigFile.remoteURL(config, name: "upstream") == "https://github.com/org/storefront.git")
        #expect(GitConfigFile.remoteURL(config, name: "nope") == nil)
        #expect(GitConfigFile.remoteNames(config) == ["origin", "upstream"])
    }

    // MARK: - Окно Touch ID и журнал

    @Test func promptForACommand() {
        #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 10, command: "git push") == "Радарчик откроет SSH-ключи на время команды «git push».")
        #expect(GuardPhrase.unlockPrompt([.env], minutes: 10, project: "storefront", command: "rails credentials:edit")
            == "Радарчик откроет ключи проекта storefront на время команды «rails credentials:edit».")
        english {
            #expect(GuardPhrase.unlockPrompt([.ssh], minutes: 10, command: "git push") == "Radarchik will open SSH keys while “git push” runs.")
        }
    }

    @Test func needNamesForTheTerminal() {
        #expect(GuardPhrase.need(KeyNeed(category: .ssh, scope: nil)) == "SSH-ключи")
        #expect(GuardPhrase.need(KeyNeed(category: .env, scope: "/Users/me/work/storefront")) == "ключи проекта storefront")
        #expect(GuardPhrase.commandHint(command: "git push", needs: [KeyNeed(category: .ssh, scope: nil)])
            == "Радарчик: git push нужны SSH-ключи, а они закрыты. Открывать по Touch ID сам я смогу, когда поставишь root-часть: make install-guard")
    }

    @Test func onlySafeLabelsReachTheWindow() {
        #expect(GuardHelper.isSafeCommandLabel("git push"))
        #expect(GuardHelper.isSafeCommandLabel("rails credentials:edit"))
        #expect(!GuardHelper.isSafeCommandLabel("ls». Это безопасно, жми"))
        #expect(!GuardHelper.isSafeCommandLabel(String(repeating: "a", count: 40)))
    }

    @Test func scopedJournalLinesStillParse() {
        let zone = TimeZone(identifier: "Europe/Moscow")!
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        let text = [
            GuardJournal.line(.unlock(["env"], user: "me", minutes: 10, scope: "/Users/me/work/storefront"), at: at, timeZone: zone),
            GuardJournal.line(.lock(["env"], scope: "/Users/me/work/storefront"), at: at + 3, timeZone: zone),
        ].joined(separator: "\n")
        let entries = LegacyGuardLog.parse(text, timeZone: zone)
        #expect(entries.map(\.action) == [.unlock(.timer, timeout: 600), .lock])
        #expect(entries.map(\.category) == ["env", "env"])
    }
}
