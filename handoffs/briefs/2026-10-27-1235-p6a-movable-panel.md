# Phase 6a: movable HeatLens panel, Escape closes it, "Copied" labels reset
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-27 12:36 · terminal: 83bddd18-3166-475b-8752-64d3952e4485

## Goal
Today the app is a SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)` (`App/HeatLensApp.swift`): the panel is stuck under the menu-bar icon, Escape does nothing, and it vanishes as soon as you click another app. The user wants to drag it wherever they like and close it with Escape. Done means this exact behavior (rulings made, don't re-ask):

1. Clicking the menu-bar icon opens the panel directly under the icon, as now. Clicking the icon again closes it.
2. Dragging the panel's background (at least the header row with the "HeatLens" title; anywhere not a control is better) moves it anywhere on screen, any display.
3. Once the panel has been moved, it is **detached**: it stays open when the user clicks another app (so they can read it beside Activity Monitor) and floats above normal windows. A panel that hasn't been moved keeps today's behavior and closes when the user clicks elsewhere.
4. **Escape closes the panel**, whether it's detached or not. If the stop-confirmation sheet (`App/ResultsView.swift:92`) or another sheet is open, Escape closes only that sheet. The existing Done buttons keep doing what they do (`model.dismiss()` back to idle); don't change them.
5. The next open after a close starts under the icon again and not detached. Don't remember the position.
6. In `App/FindingCard.swift` the "Copied" label (and "Copied PID" / "Copied command" in `App/ProcessDetailView.swift:119-126`) stays forever today. It should revert to the normal label about 2 seconds after the click, using a one-shot `Task.sleep`, not a repeating timer.
7. Keep everything else: no Dock icon (`LSUIElement`), ⌘Q quits, the scan/idle/settings views unchanged, and no timers or polling while idle (PRD §9: idle CPU ≈ 0%).

## Context
- Prior handoff: none for the panel. The last app-side change was `handoffs/merged/2026-10-27-1216-p5a-app-icon.md` (icon only, unrelated).
- Recommended approach: drop `MenuBarExtra` for an AppKit `NSStatusItem` (same SF Symbol `thermometer.medium`) plus a borderless, non-activating `NSPanel` subclass hosting `PopoverView` in an `NSHostingView`, wired up from an `@NSApplicationDelegateAdaptor`. Set `isMovableByWindowBackground = true` and use `windowDidMove` (ignore the move you make when positioning it under the icon) to switch to detached, which means `level = .floating` and no close on resign-key. Escape via `cancelOperation(_:)` on the panel; sheets attached to the panel get Escape first. Keep the rounded, translucent look close to today's (an `NSVisualEffectView` with `.popover`/`.menu` material and a corner radius). If you find a cleaner way that meets 1–7 while keeping `MenuBarExtra`, that's fine too; say why in the handoff.
- Patterns to copy: the new panel file follows `App/StopService.swift` (one small AppKit-facing type per file, a `///` doc line saying what it is and that it holds no timers); the Copied reset extends the existing `@State private var copiedCommand` in `App/FindingCard.swift:14` rather than adding a new mechanism.
- `ScanModel` is created in `HeatLensApp.init()`; keep a single instance shared by the panel's lifetime (don't recreate it on each open, or a running scan and the last result are lost).
- The panel's SwiftUI content sizes itself (`.frame(width: 300)`, results scroll). The panel must follow content height changes (idle → results) and stay on screen.
- The click-through notes are in `docs/CLICKTHROUGH.md`. Driving tip from earlier sessions: `cua.getApp` times out on LSUIElement apps; a CoreGraphics click on the status icon plus System Events works. Use it (or `screencapture`) to verify 1–5 yourself, and add a short "Panel" step to `docs/CLICKTHROUGH.md`.
- What "Copy command" does, for reference: it copies the process's full argv, shell-quoted by `Format.command` (`App/Formatting.swift:101`), to the clipboard. Don't change that.

## Scope
- May touch: `App/HeatLensApp.swift`, new files under `App/` (e.g. `App/StatusPanel.swift`), `App/PopoverView.swift`, `App/FindingCard.swift`, `App/ProcessDetailView.swift`, `App/ResultsView.swift` (only for sheet/Escape handling), `docs/CLICKTHROUGH.md`
- Must not touch: `Sources/`, `Tests/`, `site/`, `scripts/`, `handoffs/` except your handoff
- Shared files (edit minimally, name in handoff): `project.yml`, `App/Info.plist` (you shouldn't need either; `project.yml` already globs `App/`)

## Done when
`swift build`, `swift test` and `scripts/run-app.sh --build-only` all pass (commands under Checks), and launching with `scripts/run-app.sh` shows behaviors 1–6 working: the handoff names each one with how it was verified (a screenshot path in your scratch folder or the scripted click sequence).

## Phase
One phase. Build, verify by driving the app, hand off.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`. Then launch with `scripts/run-app.sh` and verify behaviors 1–6 by hand or by script; list in the handoff which you verified and how. Quit the app you launched before handing off.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
