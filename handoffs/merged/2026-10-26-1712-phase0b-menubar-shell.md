# Phase 0b: menu-bar app shell (idle popover, no Dock icon)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-26-1708-phase0b-menubar-shell.md
## What the user asked
A native SwiftUI menu-bar app `HeatLens.app` that builds from one script, has no Dock icon (`LSUIElement`), and shows the PRD §7 idle popover. It does no work while idle, and its idle CPU and memory are measured.
## What changed
- xcodegen project `project.yml`: one app target `HeatLens`, sources `App/`, Swift 6, macOS 14.0, bundle id `dev.heatlens.HeatLens`, ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`), no hardened runtime, no entitlements, unsandboxed. HeatLensCore is not linked yet.
- `App/HeatLensApp.swift`: `@main` app with `MenuBarExtra("HeatLens", systemImage: "thermometer.medium")` and `.menuBarExtraStyle(.window)`.
- `App/PopoverView.swift`: a 300 pt idle popover with the title "HeatLens", "Last scan: never", a prominent **Scan now** button, the caption "Nothing is monitored until you scan." and a "Quit HeatLens" button (⌘Q, calls `NSApplication.shared.terminate`). Scan now only reveals "Scanning arrives in Phase 1." It shows no fake data. There are no timers, no tasks and no polling. It uses system fonts and semantic colours only.
- `scripts/run-app.sh [--build-only]`: exports `DEVELOPER_DIR`, runs `xcodegen generate`, then a quiet `xcodebuild … -derivedDataPath .build/xcode build` (on failure it prints the last 40 log lines), prints the `.app` path, and `open`s the app unless `--build-only` is passed.
- Built app: `.build/xcode/Build/Products/Debug/HeatLens.app`
## Files
- project.yml — created
- App/Info.plist — created
- App/HeatLensApp.swift — created
- App/PopoverView.swift — created
- scripts/run-app.sh — created (executable)
- handoffs/2026-10-26-1712-phase0b-menubar-shell.md — created
## Checks run
1. `scripts/run-app.sh --build-only 2>&1 | tail -20`: succeeded and printed the `.app` path.
2. `plutil -extract LSUIElement raw …/HeatLens.app/Contents/Info.plist` printed `true`. `codesign -dv` reports `Signature=adhoc` and `Identifier=dev.heatlens.HeatLens`.
3. Launched with `scripts/run-app.sh`. The PID came from `pgrep -nf`, and no HeatLens was running beforehand. After 30 s idle:
   - 17:10:45: `%cpu 0.0`, RSS 24,192 KB, CPU time 0:00.70
   - 17:10:55: `%cpu 0.0`, RSS 6,672 KB, CPU time 0:00.70 (unchanged, so zero work done)
   - `top`: 0.0% CPU, 18M memory footprint, 0 idle wakeups
   The RSS fell because macOS compresses or pages out an idle app's memory. The `top` MEM figure of 18 MB is the fairer footprint number, well under the PRD's 50 MB goal. The popover was never opened during measurement.
4. `osascript -e 'quit app "HeatLens"'` quit it cleanly, and the PID is gone. `jarvis leftovers --mine` lists nothing.
- The standard check line (`swift build` / `swift test`) **could not run**: `Package.swift` doesn't exist yet. It belongs to the 0a worker.
- **Not checked:** I can't click the menu-bar icon from a script, so the popover's look in light and dark mode, the Scan now stub and the Quit button are unverified. **User:** run `scripts/run-app.sh`, click the thermometer in the menu bar, check that there's no Dock icon, click Scan now, then Quit.
## Processes left running
none
## Notes for Jarvis
- Derived data goes to `.build/xcode`, which is already gitignored, as is the generated `HeatLens.xcodeproj`. Nothing was added to `.gitignore`.
- Suggested app-bundle line to join the Checks line in CLAUDE.md/AGENTS.md: `scripts/run-app.sh --build-only 2>&1 | tail -20`.
- When Phase 1 links HeatLensCore, add a `packages:` entry (local path `.`) and a target dependency on `HeatLensCore` in `project.yml`.
- Suggested commit message: `feat: menu-bar app shell with idle popover (Phase 0b)`
