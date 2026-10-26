# Phase 0b: menu-bar app shell (idle popover, no Dock icon)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-26 17:09 · terminal: c4b1205a-8421-481c-9fe1-3be383cae19e

## Goal
A native SwiftUI menu-bar app, `HeatLens.app`, that builds from one script, has no Dock icon, and opens a compact popover showing the PRD's idle screen. It must do zero work while idle: no timers, no polling. Done means `scripts/run-app.sh` builds and launches it, the built `Info.plist` has `LSUIElement = true`, and idle CPU and memory are measured and reported.

## Context
- Spec: `docs/PRD.md` §3 (entry point, primary flow) and §7 ("Popover / idle"). FR-01 and FR-12 are this brief's acceptance criteria.
- **Decided by Jarvis:** the app is an xcodegen project (`project.yml` → generated `HeatLens.xcodeproj`, which is gitignored). App sources live in `App/`. The engine is a SwiftPM library `HeatLensCore` at the root, built in parallel by another worker (`handoffs/briefs/2026-10-26-1708-phase0a-feasibility-probe.md`). **Don't link it yet.** Phase 1 wires it in.
- Unsandboxed, ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`), no entitlements file, deployment target macOS 14.0, bundle id `dev.heatlens.HeatLens`.
- `xcodegen` is at `/opt/homebrew/bin/xcodegen`. Builds need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the script should export it itself.

## What to build
- `project.yml`: one app target `HeatLens`, sources `App/`, `INFOPLIST_FILE: App/Info.plist`, Swift 6 language mode.
- `App/Info.plist`: `LSUIElement` true, plus the usual bundle keys.
- `App/HeatLensApp.swift`: `@main` App with `MenuBarExtra("HeatLens", systemImage: "thermometer.medium")` and `.menuBarExtraStyle(.window)`.
- `App/PopoverView.swift`: compact view, about 300 pt wide, idle state per PRD §7. Title "HeatLens", "Last scan: never", a prominent **Scan now** button (Phase 0 stub: it can show "Scanning arrives in Phase 1"; no fake data), caption "Nothing is monitored until you scan.", and a Quit button (`NSApplication.shared.terminate`). Use system fonts and semantic colours, so it looks right in light and dark.
- `scripts/run-app.sh` (executable, `set -euo pipefail`): runs `xcodegen generate`, then `xcodebuild -project HeatLens.xcodeproj -scheme HeatLens -configuration Debug -derivedDataPath .build/xcode build` (quiet, last lines on failure), then `open` the built `.app`. Takes `--build-only` to skip launching, and prints the `.app` path.

## Scope
- May touch: `project.yml`, `App/`, `scripts/run-app.sh`, your scratchpad
- Must not touch: `Package.swift`, `Sources/`, `Tests/`, `docs/`, `handoffs/` (except your handoff)
- Shared files (edit minimally, name in handoff): `project.yml`, `App/Info.plist` (you create them)

## Checks
1. `scripts/run-app.sh --build-only 2>&1 | tail -20` succeeds.
2. `plutil -extract LSUIElement raw <built app>/Contents/Info.plist` prints `true`.
3. Launch with `scripts/run-app.sh`, find **its** PID (`pgrep -nf 'HeatLens.app/Contents/MacOS/HeatLens'` right after launch, which is the one you started). Wait 30 s, then record `ps -o %cpu=,rss= -p <pid>` twice, 10 s apart. Report both in the handoff (target: ~0% CPU, note the RSS).
4. Quit it with `osascript -e 'quit app "HeatLens"'`, or `kill <that pid>` only if that fails, and confirm it's gone.
You can't click the menu-bar icon from a script. Say so plainly; the user verifies the popover visually.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
