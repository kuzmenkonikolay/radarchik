<p align="center">
  <img src="docs/social-preview.png" alt="Radarchik — a tiny mascot that lives in your MacBook notch" width="800">
</p>

<p align="center">
  <b>A tiny mascot that lives in your MacBook notch.</b><br>
  It keeps an eye on your side projects’ money, watches your Mac, and once a day asks Claude what in your routine could be automated.
</p>

<p align="center">
  <a href="README.ru.md">Русский</a> ·
  <a href="#install">Install</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#development">Development</a>
</p>

<p align="center">
  <img src="docs/notch-loop.gif" alt="The notch wakes up, the month’s net grows from red to green, the summary opens" width="540">
</p>

## What it does

**Money, right beside the notch.** Add your projects’ recurring costs once — monthly or yearly — and log income as it comes. The left wing shows this month’s net across all projects: red at the start of the month, because costs accrue from the 1st, and green as income lands. Hover the notch for a one-line summary of last month, net by month across all projects and a chip for every project.

**Where to pay.** Recurring costs grouped by where you pay them, with links to the dashboards. Yearly costs count as 1/12 a month in totals and show up in full in their renewal month.

**Your Mac’s resources.** CPU, memory, battery and temperature — on the right wing and on the System screen. When an app uses far more than its usual, a note slides out of the notch: “Arc is using 4.1 GB — 3× its usual”. Norms are learned per app over a week; “That’s normal” raises them.

**Daily tips from Claude (optional).** With activity tracking on, Radarchik logs which apps and sites your day goes to, terminal command templates with secrets stripped, copy-paste flows between apps and calls. Once a day it sends an aggregated summary — never the raw log — to Claude with your own API key and shows 3–5 concrete tips: an alias, a script, a Shortcut.

**Quiet on calls.** While the microphone is in use, the numbers hide: you might be sharing your screen.

**English and Russian.** Follows the system language; you can switch it in Settings.

| | | |
|:---:|:---:|:---:|
| <img src="docs/screenshots/en/summary.png" width="260" alt="Summary"> | <img src="docs/screenshots/en/project.png" width="260" alt="A project"> | <img src="docs/screenshots/en/system.png" width="260" alt="System"> |
| Summary | A project | System |
| <img src="docs/screenshots/en/summary-alert.png" width="260" alt="An app uses more than usual"> | <img src="docs/screenshots/en/tips.png" width="260" alt="Daily tips"> | <img src="docs/screenshots/en/settings.png" width="260" alt="Settings"> |
| An app uses more than usual | Daily tips | Settings |

## Privacy

- Everything lives on your Mac, in one SQLite file: `~/Library/Application Support/Radarchik/radarchik.sqlite`.
- Activity tracking is **off by default**. It never records the screen, keystrokes, clipboard contents or audio. Excluded apps and sites — password managers and banks out of the box — are skipped entirely. The log is kept for 30 days.
- The only network request is the daily review: it goes to `api.anthropic.com` with your key, which is stored in the macOS Keychain. The “What goes to Claude” screen shows exactly what is sent, and window titles can be left out.
- Need a proxy for the Claude API? Set an HTTP proxy in settings, and requests will go only through it.

## Install

Requirements: macOS 15 or later and Xcode 16 or later (Swift 6). It’s made for a MacBook with a notch; on other displays it draws a virtual one.

```sh
git clone https://github.com/kuzmenkonikolay/radarchik.git
cd radarchik
make install   # builds Radarchik.app, copies it to ~/Applications and opens it
```

Hover the notch to open the panel; everything else is in the “⋯” menu.

- To log terminal commands, add the line shown on the Activity tracking screen to `~/.zshrc`.
- For daily tips, add an API key from [console.anthropic.com](https://console.anthropic.com) in “Daily review & Claude”.

> The app isn’t notarized yet. If you download a build from Releases, macOS will block the first launch — allow it in System Settings → Privacy & Security.

<details>
<summary>Permissions reset after every rebuild?</summary>

macOS ties Accessibility and Automation permissions to the code signature, and with ad-hoc signing every build looks like a new app. Create a self-signed code-signing certificate named **Radarchik dev** in Keychain Access (Certificate Assistant → Create a Certificate…, certificate type “Code Signing”). The Makefile picks it up automatically.
</details>

## Development

```sh
make test   # logic tests: money, formats, phrases, resources, SQLite
make run    # build and (re)launch
make zip    # build/Radarchik.zip for GitHub Releases
```

- `Sources/RadarchikCore` — logic without UI, covered by tests.
- `Sources/Radarchik` — the app: the notch window (`Notch/`), screens (`Views/`), the mascot (`Mascot/`), activity tracking (`Observation/`), resources (`Resources/`), the daily review (`Review/`).
- UI strings live next to the code, in pairs: `L("Настройки", "Settings")`.

Everything visual renders without launching the app, which makes reviews easy:

```sh
.build/debug/Radarchik --render-screens <folder> --language en   # every screen as PNG
.build/debug/Radarchik --render-docs <folder> --language en      # the screenshots above
.build/debug/Radarchik --render-promo radarchik.mp4              # the promo video, add --format square for 1:1
.build/debug/Radarchik --render-icon <folder>                    # AppIcon.iconset, then iconutil -c icns
```

The promo video is rendered by the app itself: real SwiftUI views on demo data, frame by frame, encoded with AVFoundation.

## License

[MIT](LICENSE)
