# v2 Phase 4c: "Keep watching in the background" in the app (+ the 4i export click-through)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 14:45 · terminal: db52e29d-3ad5-485b-b6c4-149707024d4e

## Goal
Brief **4c** in `docs/v2/ADR-0008-background-helper.md` ("4c · App: Keep watching in the
background", ~lines 358–398), built as specified: the Settings switch (off by default) with its §4
caption and status line, `LiveModel` driving `BackgroundMonitor`, panel close → `viewerClosed()`,
launch with the switch on starts background mode, Scan detaches instead of stopping,
`LiveAlertService` posting from `BackgroundEvent.alerts` with `.active` interruption level, the Live
header line, the status-item tooltip, and the Alerts caption change. Then the click-through in that
brief, plus the 4i Export incident click-through.

## Done when
- `swift build` and `scripts/run-app.sh --build-only` succeed with no new warnings, and the full
  suite passes under the lock (command in Checks).
- With the switch on and the panel closed, a CPU alert notification arrives within ~2.5 min of
  loading ≥70 % of cores, Live's header reads "every 5 s (incident)", and within 2 min of stopping
  the load it reads "every 30 s (idle…)" (ADR-0008 4c steps 2–5).
- Idle app CPU grows ≤ 0.3 s per 60 s (`ps -o time= -p <pid>`, step 6); after Quit no HeatLens
  process remains; with the switch off, closing the panel stops Live (step 7).
- 4i: an export saved from the banner as Markdown and as anonymised JSON; `grep -nE "PID [0-9]|$HOME"`
  on both prints nothing; the anonymised file names no real project; cancelling the Save panel
  writes nothing.
- The handoff records pass/fail per step (or "screen locked" plus the steps for the user).

## Context
- Core merged: `handoffs/merged/2026-10-28-2000-v2-p4b-background-monitor.md` — **read its "For the
  4c worker" notes and follow them exactly**:
  - "Start live" = `resume()` then `viewerAttached(interval:)` (attach alone never undoes Pause).
  - Pause → `pause()`; panel close or switching to Scan → `viewerDetached()`; picker change →
    `viewerAttached(interval:)` again.
  - Alert settings → `setAlerts(_:)` (no restart); other settings → `configure(_:keepWatching:)`
    (restarts a running session, as today).
  - `LiveAlertService` subscribes `.summary` and posts from `.alerts`; `LiveModel` subscribes
    `.full` while the Live view shows.
- ADR-0008 §4 lifecycle table, v2.0 column, is the behaviour spec. Owner decisions (final): off by
  default; Quit stops it; alerts respect Focus (`.active`, never Time Sensitive).
- 4f (`handoffs/merged/2026-10-28-2000-v2-p4f-watchlists-core.md`) made `Alert.rule` optional; the
  notification identifier is already `prefix + (alert.rule?.rawValue ?? alert.id)`. Leave watch
  notification wording to 4g.
- 4i Export incident is merged but was never driven (`handoffs/merged/2026-10-28-1930-v2-p4i-incident-export-app.md`,
  "Steps for the click-through"). Key risk: the menu-bar panel closing when `NSSavePanel` takes
  focus. With 4c, a panel close no longer has to stop Live, but the sheet may still be dismissed.
  If the export breaks, fix it in `App/IncidentExportSheet.swift` and re-test.
- Patterns: the `dockerEnabled` toggle + caption in SettingsModel/SettingsView;
  `LiveAlertService.followSettings`'s observation loop; `ThermalAlertService` for click-opens-panel.

## Scope
- May touch: `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/LiveModel.swift`,
  `App/HeatLensApp.swift`, `App/PopoverView.swift`, `App/LiveAlertService.swift`, `App/LiveView.swift`,
  `App/StatusPanel.swift`, `App/AlertSettingsSection.swift`, `App/IncidentExportSheet.swift` (only
  for the export fix).
- Must not touch: `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs (Jarvis updates
  README/LIMITATIONS/CLICKTHROUGH). Entitlements: none needed — if you think one is, stop and say so.

## Phase
One phase: 4c + both click-throughs.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/run-app.sh --build-only 2>&1 | tail -20` — no new warnings.
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`.
- Click-through: ADR-0008 4c steps 1–7, then the 4i steps. First check the screen isn't locked
  (the last worker found `CGSSessionScreenIsLocked` true and couldn't drive anything); if it is,
  report that and list the steps — don't wait. Driving tip from docs/CLICKTHROUGH.md: CoreGraphics
  click on the status icon + System Events. `yes > /dev/null` processes are your own fixtures: note
  their PIDs and stop exactly those by PID (no pkill/killall). Exports and screenshots go to scratch
  only, never committed (public repo); report pass/fail and numbers, not contents or real paths.
  Step 6 numbers (`ps -o time=`) may be inflated if other workers are building; say so if so.

## Questions first
None expected. Genuine contradictions only: one blocked handoff, then stop.
