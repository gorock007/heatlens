# v2 Phase 4e: crash recovery (background retry, unclean-exit notice, history integrity, MetricKit)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-2300-v2-p4e-crash-recovery.md

## What the user asked
Build 4e from `docs/v2/PHASE-4-PLAN.md`:
- a background session that failed is retried after 30 s, then 2 min, then every 10 min;
- `HistoryStore.integrityCheck()`, run after an unclean exit;
- the `lastExitWasClean` flag, the one-time Live notice with **Show crash reports**, and
  "History file is damaged" with **Delete history**;
- a MetricKit crash-diagnostic subscriber that only logs.

Then run the click-through. I had no questions.

## What changed
- **`BackgroundMonitor`:**
  - With Keep watching on, a `.failed` session is restarted after `retryDelays` = 30 s, 120 s,
    then 600 s repeating.
  - Each try logs a notice: `retrying failed session attempt=<n> after=<s>`.
  - A tick that works resets the schedule, and `pause()`/`resume()` cancel a pending retry.
  - While it waits, the status is `.paused(.failed)` as before, so Live shows the error.
  - With Keep watching off, nothing changes: the failure holds until `resume()`.
  - The internal init takes a `retrySleep:` (default `Task.sleep`) so tests can inject the wait.
- **`HistoryStore.integrityCheck() throws -> Bool`:**
  - It runs `PRAGMA quick_check` and returns true only for a single `ok` row.
  - `SQLITE_CORRUPT` or `SQLITE_NOTADB` while checking returns false. Other errors throw.
  - A failure logs `history integrity check failed problems=<n>`.
- **`App/HeatLensApp.swift`, a new `CrashRecovery` (`@MainActor @Observable`, shared):**
  - **The flag:** UserDefaults `lastExitWasClean` is set false at launch and true in
    `applicationWillTerminate`. A missing flag (first launch) counts as clean. It's read and written
    directly, so `SettingsModel` is untouched.
  - **The notice:** after an unclean exit, `uncleanExitNotice` reads "HeatLens quit unexpectedly last
    time. Background watching resumed." or "…Live is stopped." depending on the switch. A notice
    `unclean exit noticed keepWatching=<bool>` is logged.
  - **The notice goes once seen:** after Live has shown it, it clears when the panel closes
    (`onClose`) or the notice view disappears.
  - **History check:** after an unclean exit, if the history file exists (never created for the
    check), it's opened with `HistoryService.existingStore` and `integrityCheck()` runs.
    `historyDamaged` is set when the check returns false, or when the file is there but won't open.
  - **Show crash reports** opens `~/Library/Logs/DiagnosticReports` in Finder. HeatLens never reads
    the reports.
  - **Delete history** calls `HistoryService.shared.deleteHistory()`, the same path as Settings, and
    clears the flag on success. Nothing is deleted automatically.
  - **`CrashDiagnostics`** is an `MXMetricManagerSubscriber`. For each `MXCrashDiagnostic` it logs
    `HeatLensLog.error(.live, "crash diagnostic")` with exceptionType, signal and
    versionMajor/Minor/Patch, all as counts. It writes no file.
  - MetricKit needed no entitlement and no project change.
- **`App/LiveView.swift`:** a `RecoveryNotices` view under Live's controls.
  - The unclean-exit notice is an orange box with a **Show crash reports** link.
  - "History file is damaged" has a **Delete history** link, disabled while the delete runs.

## Files
- Sources/HeatLensCore/Background/BackgroundMonitor.swift — modified
- Sources/HeatLensCore/History/HistoryStore.swift — modified
- App/HeatLensApp.swift — modified
- App/LiveView.swift — modified
- Tests/HeatLensCoreTests/BackgroundMonitorTests.swift — modified
- Tests/HeatLensCoreTests/HistoryStoreTests.swift — modified
- handoffs/2026-10-28-2300-v2-p4e-crash-recovery.md — created

## Checks run
- **`swift build`:** Build complete.
- **Targeted tests, 3 runs:** `scripts/with-timeout.sh 600 swift test --filter "BackgroundMonitor|HistoryStore"`
  passed all three times, 25 tests in 2 suites each.
  - New: "Keep watching on: a failed session is retried after 30 s, then 2 min, and samples again".
    The baseline read fails in the first session and the first retry. The retry waits are
    `[30, 120]`, there are two `.failed` stops, then ticks in background. A second case fails four
    times and gets `[30, 120, 600, 600]`.
  - New: "Pause cancels a pending retry".
  - New: "integrityCheck: a fresh store passes; one with bytes overwritten mid-file fails". It uses
    2,000 ticks, then one 4 KB page of 0x5A mid-file after close.
  - Changed: the existing failure test now runs with Keep watching off and a viewer, since that's
    the mode that still holds until resume. It also checks that no retry is scheduled.
  - The scripted sampler takes a set of failing calls (`failOnCalls`).
- **Full suite:** `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`:
  **457 tests in 66 suites passed.**
- **App build:** `scripts/run-app.sh --build-only` built. A full `xcodebuild` log in scratch has no
  warnings from App/; the only warning is the usual appintents "Metadata extraction skipped".
- **Click-through:** Debug app, screen unlocked. I launched the binary directly, so each PID came
  from my own `$!`. No other HeatLens was running.
  1. **Launch with Background on: pass.** `defaults write … keepWatchingInBackground -bool true`,
     PID 63317. The log showed `mode changed to=background`, and `lastExitWasClean` read 0.
  2. **`kill -ABRT 63317` (only my PID): pass.** The process was gone, and the flag stayed 0. macOS
     wrote `HeatLens-2026-10-28-155020.ips`, which I didn't read.
  3. **Relaunch: pass.** PID 66574.
     - The log showed `unclean exit noticed keepWatching=true`, then `mode changed to=background`.
     - Panel → Live showed "HeatLens quit unexpectedly last time. Background watching resumed." with
       Show crash reports, above "Watching in the background · every 10 s".
     - **Shown once: pass.** I closed the panel, reopened it and chose Live: no notice.
  4. **Quit normally and relaunch: pass.** I quit with the panel's Quit HeatLens button on my PID;
     the flag became 1. Relaunched as PID 83329, Live showed no notice and the log had no
     "unclean exit". I quit it the same way.
- **Cleanup:**
  - `defaults delete` of `keepWatchingInBackground` and `lastExitWasClean`, the only keys I added.
  - `jarvis leftovers --mine`: nothing running.
  - Screenshots are in scratch only.
- **Not checked:**
  - "History file is damaged" in the app: Keep history was off and there was no history file on
    this Mac, so the check didn't run. `integrityCheck` is covered by the unit test.
  - The **Show crash reports** and **Delete history** clicks.
  - The "…Live is stopped" wording, with the switch off.
  - A real background retry in the app: I had no way to make the process list fail.
  - MetricKit delivery: macOS delivers diagnostics on a later launch, sometimes a day later. No
    `crash diagnostic` line appeared during the session.

## Processes left running
none

## Questions for the user
None.

## Notes for Jarvis
- **Placement:** the notice is in Live, as the brief's scope gives `LiveView`, not in the panel
  header. The panel opens on Scan, so the notice is seen only when the user switches to Live. It
  stays until then.
- **Logging:**
  - `HeatLensLog` has no app or crash category, so the crash and unclean-exit lines use `.live`.
  - It has no public string value, so the app version is logged as three counts. If you want a
    `.app` category or a version value, that's a small 4d follow-up in `HeatLensLog.swift`, which
    was outside my scope.
- **Shared files:** none. `SettingsModel` is untouched; the flag is read and written directly in
  `CrashRecovery`.
- **Suggested commit:** `feat(v2): Phase 4e — crash recovery (background session retry at 30 s /
  2 min / 10 min, HistoryStore.integrityCheck via quick_check, lastExitWasClean flag with one-time
  Live notice and Show crash reports, History file is damaged with Delete history, MetricKit crash
  diagnostics to the log); kill -ABRT click-through passes`
