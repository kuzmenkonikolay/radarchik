import Foundation
import Testing
@testable import RadarchikCore

/// Секреты вычищаются до записи на диск (SPEC §3). Пользователь передаёт
/// RAILS_MASTER_KEY через `-e`, поэтому этот случай — первый.
@Suite("Терминал: вычистка секретов и шаблоны")
struct ShellRedactorTests {
    let secret = ShellRedactor.placeholder

    @Test func secretLikeAssignmentsAreRedacted() {
        #expect(ShellRedactor.redact("docker compose run --rm -e RAILS_MASTER_KEY=a91376f0c2d4e5b6a7c8d9e0f1a2b3c4 web bin/rails c")
            == "docker compose run --rm -e RAILS_MASTER_KEY=\(secret) web bin/rails c")
        #expect(ShellRedactor.redact("export GITHUB_TOKEN=abc123") == "export GITHUB_TOKEN=\(secret)")
        #expect(ShellRedactor.redact("DB_PASSWORD='p@ss w0rd' rails s") == "DB_PASSWORD=\(secret) rails s")
        // Обычные переменные остаются как есть.
        #expect(ShellRedactor.redact("RAILS_ENV=test bundle exec rspec") == "RAILS_ENV=test bundle exec rspec")
    }

    @Test func secretFlagsAreRedacted() {
        #expect(ShellRedactor.redact("psql --password=hunter2 -h localhost") == "psql --password=\(secret) -h localhost")
        #expect(ShellRedactor.redact("vercel deploy --token abcdef123") == "vercel deploy --token \(secret)")
        #expect(ShellRedactor.redact("tool --api-key=xyz") == "tool --api-key=\(secret)")
    }

    @Test func authHeadersAndUrlCredentialsAreRedacted() {
        #expect(ShellRedactor.redact(#"curl -H "Authorization: Bearer abc.def" https://api.example.com"#)
            == #"curl -H "Authorization: Bearer \#(secret)" https://api.example.com"#)
        #expect(ShellRedactor.redact("git clone https://user:pa55@github.com/org/repo.git")
            == "git clone https://user:\(secret)@github.com/org/repo.git")
        #expect(ShellRedactor.redact("open 'https://site.ru/cb?code=XYZ&state=1'")
            == "open 'https://site.ru/cb?code=\(secret)&state=1'")
    }

    @Test func knownTokenFormatsAreRedacted() {
        #expect(ShellRedactor.redact("echo sk-ant-api03-AbCdEf123456_xyz") == "echo \(secret)")
        #expect(ShellRedactor.redact("git remote set-url origin https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/x/y")
            == "git remote set-url origin https://\(secret)@github.com/x/y")
        #expect(ShellRedactor.redact("aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE")
            == "aws configure set aws_access_key_id \(secret)")
        #expect(ShellRedactor.redact("cat <<< '-----BEGIN OPENSSH PRIVATE KEY----- abc -----END OPENSSH PRIVATE KEY-----'")
            == "cat <<< '\(secret)'")
    }

    @Test func longRandomBlobsAreRedacted() {
        #expect(ShellRedactor.redact("rails runner a91376f0c2d4e5b6a7c8d9e0f1a2b3c4") == "rails runner \(secret)")
        #expect(ShellRedactor.redact("git checkout 3f2a9c0d1e4b5a6c7d8e9f00112233445566aabb") == "git checkout \(secret)")
        // Длинные пути и слова без цифр — не секреты.
        #expect(ShellRedactor.redact("cd /Users/me/work/radarchik/Sources/RadarchikCore/Format")
            == "cd /Users/me/work/radarchik/Sources/RadarchikCore/Format")
        #expect(ShellRedactor.redact("npm run build-production-bundle-with-sourcemaps")
            == "npm run build-production-bundle-with-sourcemaps")
    }

    @Test func templateKeepsShapeWithoutValues() {
        #expect(ShellRedactor.template("docker compose run --rm -e RAILS_MASTER_KEY=\(secret) web bin/rails db:migrate", home: "/Users/me")
            == "docker compose run --rm -e RAILS_MASTER_KEY=… web bin/rails db:migrate")
        #expect(ShellRedactor.template(#"git commit -m "fix: notch position""#, home: "/Users/me") == #"git commit -m "…""#)
        #expect(ShellRedactor.template("sleep 15", home: "/Users/me") == "sleep N")
        #expect(ShellRedactor.template("cd /Users/me/work/radarchik", home: "/Users/me") == "cd ~/work/radarchik")
        #expect(ShellRedactor.template("ssh  deploy@10.0.0.5", home: "/Users/me") == "ssh deploy@N.N.N.N")
    }

    @Test func parsesHookMessage() throws {
        let message = try #require(ShellMessage.parse("1\t1760000000.250000\t1520\t0\t/Users/me/work\tmake test"))
        #expect(message.startedAt == Date(timeIntervalSince1970: 1_760_000_000.25))
        #expect(message.durationMs == 1520)
        #expect(message.exitCode == 0)
        #expect(message.cwd == "/Users/me/work")
        #expect(message.command == "make test")
        #expect(ShellMessage.parse("garbage") == nil)
        #expect(ShellMessage.parse("2\t1\t2\t3\t/\tls") == nil)   // неизвестная версия формата
    }

    @Test func storedCommandIsAlreadyClean() throws {
        let message = try #require(ShellMessage.parse("1\t1760000000\t15\t1\t/Users/me\texport API_TOKEN=abc"))
        let command = message.makeCommand(home: "/Users/me")
        #expect(command.command == "export API_TOKEN=\(secret)")
        #expect(command.template == "export API_TOKEN=…")
        #expect(command.cwd == "~")
        #expect(command.exitCode == 1)
    }
}
