# Phase 2b: process detail, stop confirmation flow, group list limits, settings (App only)
worker: codex
model: gpt-5.6-sol
effort: high
started: 2026-10-26 18:02 · terminal: 118133ad-be70-4fcd-a947-bdfba07cc3de

## Goal
The popover gets four things. First, a **process detail** view. Second, the **Request stop** flow: an explicit confirmation, then the engine's `ProcessTerminator`, then a re-check and a plain outcome. Third, a "What's using resources" list that's usable on a real Mac (about 600 groups). Fourth, **Settings** (sample duration, exclusions, launch at login, off by default). Done means `scripts/run-app.sh --build-only` passes and the flows work against the fixture service in previews.

## Context
- Spec: PRD §3 (UI sections and Settings), §4.4 (every safe-remediation bullet is UI copy you must honour), §7 ("Process detail"), and FR-04, FR-09 and FR-12.
- **Pattern to copy:** `App/FindingCard.swift` (cards, action buttons, `FlowLayout`), `App/ResultsView.swift` (sections) and `App/Formatting.swift` (CPU and memory text, "via ps", "Not accessible"). Previous handoff: `handoffs/merged/2026-10-26-1800-p1b-wire-real-scan.md`.
- **Engine API**, being built in parallel by another worker in `Sources/HeatLensCore/Safety/`. Code against exactly this; if it hasn't landed when you build, add a temporary stub in `App/` and say so in the handoff:
  ```swift
  public enum StopEligibility: Equatable, Sendable { case eligible, denied(reason: String) }
  public enum StopOutcome: Equatable, Sendable { case stopped, stillRunning, alreadyExited, identityChanged, denied(reason: String), failed(errno: Int32) }
  public struct ProcessTerminator: Sendable { public init(); public func eligibility(of: ProcessSample) -> StopEligibility; public func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3) async -> StopOutcome }
  ```
  The rules engine will start emitting `.requestStop(identity)` on eligible stale-dev-server and detached-worker findings.

## What to build (App/ only)
1. **Process detail**, opened from Inspect and from group member rows. It shows:
   - PID, parent chain (name and pid, from the snapshot), owner, uptime, executable, command (shell-joined argv, or "Not accessible") and working directory
   - CPU in the sample and memory, with "via ps" where that applies
   - project attribution with its basis and confidence
   - the evidence and limitations of findings that name this process
   - the actions: Copy PID, Copy command, Open project, Activity Monitor, and Request stop when eligible
2. **Request stop:**
   - Show the button only when the finding offers `.requestStop` **and** `eligibility` is `.eligible`. Otherwise show nothing, or, in the detail view, the denial reason in secondary text.
   - Confirmation: an in-popover sheet or alert, never automatic. It states the exact PID, the command, the project, the measured impact ("0.1% CPU in this sample — stopping it is unlikely to cool your Mac" when CPU < 5%), and the warning "Stopping a dev server or agent can interrupt tests, edits, builds or active sessions." Buttons: **Cancel** (default) and **Send SIGTERM**, with no default focus on the destructive one.
   - Then call `requestStop`, show progress, and map each `StopOutcome` to a plain sentence. `.stillRunning` says it didn't exit and that HeatLens does not force-quit; use Activity Monitor if needed. Then offer **Scan again**.
3. **Group list:** show the top 12 groups by CPU, then a "Show all N groups" toggle. Collapse groups with zero measured CPU and under 50 MB into "N idle groups" unless the list is expanded.
4. **Settings** (a gear in the popover header, opening an in-popover settings view, not a window):
   - Sample duration, 5, 10 or 15 s (default 10), used by `ScanModel`.
   - Excluded processes and projects: a text list. Findings whose affected processes all match by name, or by project directory prefix, are hidden, with "N findings hidden by your exclusions".
   - Launch at login: `SMAppService.mainApp`, off by default, and it reflects the real status.
   - Store everything in `UserDefaults`. No other persistence, no history.
5. Keep the idle cost at zero: no timers and no observers outside an active scan or stop.

## Scope
- May touch: `App/` (except `Info.plist`), scratchpad
- Must not touch: `Sources/`, `Tests/`, `Package.swift`, `docs/`, `scripts/`
- Shared files (edit minimally, name in handoff): `project.yml` (only if a framework link is needed for `ServiceManagement`)

## Checks
`scripts/run-app.sh --build-only 2>&1 | tail -20` and `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -5`. Launch the app, take its PID, record idle `ps -o %cpu=,rss=` after 30 s, then quit with `osascript -e 'quit app "HeatLens"'`. **Never click Send SIGTERM on a real process. Never signal anything yourself.** List exactly what the user should click. Never run git commands that change state.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
