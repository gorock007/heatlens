# Phase 10f: click-only "Check for updates…" in Settings (ships as 1.2.1)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-27 17:53 · terminal: 0d4e02a4-8c6e-4b62-b053-a8e5e9989c4a

## Goal
User ruling (2026-10-27): HeatLens gets a **click-only** update check.
- It runs **no** automatic, background or at-launch check, and has no timer and no setting to turn checks on.
- The only network request HeatLens ever makes is the one the user triggers by clicking.
- It doesn't install anything. It tells the user and opens the release page, and they replace the app by hand as today.

Done means:
1. **Core (pure, tested).** Add `Sources/HeatLensCore/Update/UpdateCheck.swift`:
   - `ReleaseInfo.parse(_ data: Data) throws -> ReleaseInfo` for the GitHub "latest release" JSON. It keeps `tag_name` (strip a leading `v`), `html_url` and `draft`/`prerelease`. Reject a draft or prerelease, and reject an `html_url` that doesn't start with `https://github.com/gorock007/heatlens/releases/`.
   - `UpdateCheck.status(current: String, latest: ReleaseInfo) -> UpdateStatus`, with the cases `.upToDate(current)` and `.available(version, url)`.
   - Compare versions numerically per component (1.10.0 > 1.9.0; 1.2 == 1.2.0). A malformed tag gives `.upToDate` and is never reported as an update.
2. **App.** Add `App/UpdateChecker.swift` (`@MainActor @Observable`), with the states idle / checking / upToDate / available / failed(message).
   - It makes one `GET https://api.github.com/repos/gorock007/heatlens/releases/latest` with `URLSession(configuration: .ephemeral)` (no cookies, no cache), a `User-Agent: HeatLens/<version>` header, `Accept: application/vnd.github+json` and a 10 s timeout.
   - It sends nothing else: no identifiers, no system info, no query parameters.
   - The current version is `CFBundleShortVersionString`.
3. **Settings UI.** In `App/SettingsView.swift`, add a row near the bottom with "HeatLens <version>" and a **"Check for updates…"** button.
   - While checking, show "Checking…" and disable the button.
   - Up to date: "You're up to date."
   - Newer: "HeatLens <x.y.z> is available." with a **"Download"** button that opens the release `html_url` in the browser.
   - Failure (offline, rate-limited, bad JSON): "Couldn't check for updates." plus a "Releases page" button that opens `https://github.com/gorock007/heatlens/releases`. Never show a raw error dump.
   - A caption under the button: "Contacts GitHub only when you click."
4. **Copy that promises "no network".** Make these exact edits. They're short:
   - `README.md` line ~87: change `- Fully local: no account, API key, or network access.` to `- Fully local: no account or API key. The only network request is the update check, and only when you click Check for updates.`
   - `site/index.html`: the privacy paragraph that starts `<p>No network access, no account,` (~line 278). Replace `No network access, no account,` with `No network access except a check for updates when you click it, no account,`.
   - `site/index.html`: the FAQ answer that starts `HeatLens itself still makes no network connections;`. Replace that clause with `HeatLens itself makes no network connections apart from the update check you click;`.
   - Change nothing else on the site.

## Context
- Prior handoffs:
  - `handoffs/merged/2026-10-27-1700-p10d-global-hotkey.md`: the latest Settings rows and their layout
  - `handoffs/merged/2026-10-27-1650-p10a-thermal-alert.md`: the "open System Settings" button pattern; use `NSWorkspace.shared.open` the same way
- Read first: `App/SettingsView.swift`, `App/SettingsModel.swift` (the checker can live outside it, owned by `SettingsView` as `@State`), and `Package.swift` (a new folder under `Sources/HeatLensCore/` is picked up automatically; confirm it).
- The app is not sandboxed. HTTPS to api.github.com needs no entitlement or ATS change.
- The privacy model is FR-10 in `docs/PRD.md`: no uploads, no telemetry. A GET that carries only a User-Agent fits it, as long as it's user-initiated.
- Tests use fixture JSON only. **No test may hit the network.**

## Scope
- May touch: `Sources/HeatLensCore/Update/UpdateCheck.swift` (new), `Tests/HeatLensCoreTests/UpdateCheckTests.swift` (new), `App/UpdateChecker.swift` (new), `App/SettingsView.swift`, `README.md` (that one line), `site/index.html` (those two phrases)
- Must not touch: `project.yml` and `Sources/HeatLensCLI/Arguments.swift` (Jarvis bumps the version), `App/HeatLensApp.swift`, `App/ScanModel.swift`, `App/ResultsView.swift`, `Sources/HeatLensCore/Safety/`, `scripts/`, `dist/`
- Shared files (edit minimally, name in handoff): none expected

## Phase
One phase.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/with-timeout.sh 600 swift build 2>&1 | tail -20 && scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`.

## Done when
- Checks pass with new tests covering:
  - parsing the real shape of GitHub's response (a trimmed fixture with `tag_name`, `html_url`, `draft`, `prerelease`)
  - `v` stripping
  - draft and prerelease rejected
  - a foreign `html_url` rejected
  - numeric compare (1.10.0 > 1.9.0, 1.2 == 1.2.0, older latest → up to date)
  - a malformed tag gives up to date
- Live, in the Debug app (`open -n .build/xcode/Build/Products/Debug/HeatLens.app`; leave `/Applications/HeatLens.app` alone):
  - Open Settings and click Check for updates. The Debug build still says 1.2.0 and the latest release is v1.2.0, so it should say "You're up to date."
  - Show that the app made no request before the click: `nettop -p <pid> -L 1` or `lsof -i -p <pid>` shows no connection before it, and one to api.github.com after.
  - Put a screenshot of the Settings row in your scratch folder and name it.
- `grep -n "No network access" site/index.html README.md` shows only the new wording.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
