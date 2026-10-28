# v2 Phase 4e: crash recovery (background retry, unclean-exit notice, history integrity, MetricKit)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 15:46 · terminal: 941990b0-2612-4325-8178-0502f981e10c

## Goal
Brief **4e** in `docs/v2/PHASE-4-PLAN.md` ("Crash recovery (4e)" design + "4e · Crash recovery",
~lines 205–251), built as specified: `BackgroundMonitor` retries a failed background session after
30 s, 2 min, then every 10 min (logging each try; foreground-only keeps today's behaviour);
`HistoryStore.integrityCheck()` (`PRAGMA quick_check`) run on the first open after an unclean exit;
the `lastExitWasClean` flag and the two Live notices ("HeatLens quit unexpectedly last time.
Background watching resumed." / "…Live is stopped", with **Show crash reports**, shown once) and
"History file is damaged" with **Delete history**; a MetricKit `MXCrashDiagnostic` subscriber that
logs exception type, signal and app version via `HeatLensLog.error` and writes no file.

## Done when
- New tests pass three runs in a row: `BackgroundMonitorTests` (a sampler that fails twice then
  works → restarts at 30 s and 120 s with injected sleep, then ticks) and `HistoryStoreTests` (temp
  store with bytes overwritten mid-file → `integrityCheck()` false; fresh store → true).
- Full suite once under the lock; `scripts/run-app.sh --build-only` with no new warnings.
- Click-through: launch with Background on; `kill -ABRT` **only the PID of the HeatLens you
  launched** (record it from your own launch, not from `pgrep`); relaunch → the notice appears once
  and background watching runs; quit normally and relaunch → no notice. Pass/fail per step in the
  handoff (or "screen locked" + steps).

## Context
- Builds on: `handoffs/merged/2026-10-28-2000-v2-p4b-background-monitor.md` (PauseReason
  `failed(String)` is sticky; mode/status API), `handoffs/merged/2026-10-28-2230-v2-p4d-structured-logs.md`
  (`HeatLensLog` usage; never log a failure message that can carry a path),
  `handoffs/merged/2026-10-28-2100-v2-p4c-keep-watching-app.md` (app wiring; driving notes).
- No storage beyond the one settings flag. History is never deleted or renamed automatically;
  sampling goes on without it. HeatLens never reads the crash reports — the button only reveals
  `~/Library/Logs/DiagnosticReports` in Finder.
- Patterns: `HistoryService.lastError` shown in Live; `SettingsModel` flags.
- **Process safety:** an earlier worker's Debug HeatLens got an unexplained SIGTERM during a parallel
  run. Never quit/kill HeatLens by name or by `pgrep` result; only the PID you launched. Restore any
  settings keys you add (`defaults delete` only those).

## Scope
- May touch: `Sources/HeatLensCore/Background/BackgroundMonitor.swift`,
  `Sources/HeatLensCore/History/HistoryStore.swift`, `App/HeatLensApp.swift`, `App/LiveView.swift`,
  `Tests/HeatLensCoreTests/BackgroundMonitorTests.swift`, `Tests/HeatLensCoreTests/HistoryStoreTests.swift`.
  If the flag needs a key in `App/SettingsModel.swift`, that one addition is allowed — name it.
- Must not touch: `Model/`, `Package.swift`, `project.yml`, entitlements, docs. MetricKit needs no
  entitlement — if it seems to, stop and say so.

## Phase
One phase: 4e. This completes the v2.0 build list.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/with-timeout.sh 600 swift test --filter "BackgroundMonitor|HistoryStore" 2>&1 | tail -30` ×3
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`
- `scripts/run-app.sh --build-only 2>&1 | tail -20`; the click-through with `scripts/run-app.sh`.

## Questions first
None expected. Genuine contradictions only: one blocked handoff, then stop.
