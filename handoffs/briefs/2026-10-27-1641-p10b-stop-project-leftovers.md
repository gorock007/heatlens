# Phase 10b: stop a project's leftovers together — one listed confirmation, each PID revalidated
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-27 16:41 · terminal: 65c85c16-3758-48e4-bc6c-1abdcae245ba

## Goal
A project often leaves several leftovers at once: a stale `next dev`, a detached worker, another old server. Today each needs its own Stop flow. User ruling (2026-10-27): **one confirmation dialog that lists every process with a checkbox**, then each selected PID is **revalidated immediately before its own SIGTERM**.
- Only processes the rules already offer to stop as leftovers qualify: findings of kind `staleDevServer` / `detachedWorker` that carry `.requestStop`. HeatLens never adds candidates on its own judgement (PRD §6: age or PPID 1 is never proof).
- PRD §8 still holds: no bulk `pkill`, no SIGKILL, no `sudo`, no system processes, and nothing is stopped without that confirmation.

Done means:
1. **Core candidates (testable).** Add `Sources/HeatLensCore/Rules/LeftoverCandidates.swift`, a pure function that groups a `ScanReport`'s leftover findings by project path and returns, per project, the stop identities those findings offer, with each one's process sample.
   - Only `.requestStop` actions from `staleDevServer`/`detachedWorker` findings count.
   - Groups without a project are never batched.
   - It takes the set of hidden finding IDs, so user exclusions drop candidates (ruling: exclusion also suppresses stop).
   - De-duplicate identities.
2. **Core runner (testable).** Add `Sources/HeatLensCore/Safety/BatchStop.swift`, which stops identities **one at a time, in order**, through an injected `(ProcessIdentity) async -> StopOutcome` closure.
   - The app passes `ProcessStopping.requestStop`, which already revalidates PID and start time.
   - It reports per-identity progress and outcome.
   - It stops at the next item when cancelled; items not yet reached are reported as not attempted.
   - **Do not edit `ProcessTerminator.swift`.**
3. **UI entry point.** When a project has **2 or more** candidates, show a single "Stop leftovers (N)…" button for that project, once per project. Put it on the first leftover `FindingCard` of that project (or a small row above that project's leftover cards; your call, say which).
   - A project with one candidate keeps today's single `StopFlowView` unchanged.
   - Hide the button when `stopService.eligibility` isn't `.eligible` for fewer than 2 of the candidates.
4. **Batch sheet.** Add `BatchStopFlowView` in a new `App/BatchStopFlowView.swift`, presented from `ResultsView` the way `StopFlowView` is.
   - Title: "Stop N leftovers in <project name>?"
   - One row per process: checkbox (default on), name, PID, age, CPU in this scan, and the finding title.
   - One line explaining SIGTERM: they get a chance to exit cleanly; HeatLens checks each one is still the same process right before signalling it.
   - Destructive "Stop selected (k)" button, disabled at k = 0.
   - While it runs, show per-row status (stopping… / stopped / already gone / skipped: it changed / still running), plus Cancel.
   - Afterwards, a summary and "Scan again" (reuse `onScanAgain`).
   - Match `StopFlowView`'s wording and outcome mapping (`App/ResultsView.swift` ~line 203); factor out a shared outcome-label helper rather than copying it.
5. **Fixtures.** In `App/FixtureScanService.swift`, give the fixture project a second leftover (another stale server or detached worker in the same project), so the preview shows the batch button. Make sure `FixtureStopService` works for it.

## Context
- Prior handoffs:
  - `handoffs/merged/` for Phase 2 safety (2a–2d: FR-09 revalidation, eligibility, exclusion suppresses stop)
  - `handoffs/merged/2026-10-27-1431-p9a-keeping-awake.md`: current results layout
- Read first: `App/ResultsView.swift` (`ReportContext`, `visibleFindings` ~line 180, `StopFlowView` ~line 203, the requestStop check ~line 47), `App/FindingCard.swift` (~lines 78–115), `App/StopService.swift`, `Sources/HeatLensCore/Safety/ProcessTerminator.swift` (read only), and `Sources/HeatLensCore/Rules/RulesEngine.swift` ~lines 88–125 (`staleDevServer`/`detachedWorker`, `offersStop`; read only).
- Another worker (10a, thermal alert) is editing `App/HeatLensApp.swift`, `App/StatusPanel.swift`, `App/ScanModel.swift`, `App/SettingsModel.swift`, `App/SettingsView.swift` and adding `Sources/HeatLensCore/Rules/ThermalAlertPolicy.swift` / `ExclusionFilter.swift` in this same checkout right now. Don't touch those.
- This is safe-stop code: Claude only, never OpenCode. Tests use synthetic snapshots and processes you spawn yourself, never real listings from this Mac.

## Scope
- May touch: `Sources/HeatLensCore/Rules/LeftoverCandidates.swift` (new), `Sources/HeatLensCore/Safety/BatchStop.swift` (new), `App/BatchStopFlowView.swift` (new), `App/ResultsView.swift`, `App/FindingCard.swift`, `App/ProcessDetailView.swift` (only if a shared helper moves), `App/StopService.swift`, `App/FixtureScanService.swift`, `Tests/HeatLensCoreTests/LeftoverCandidatesTests.swift` and `BatchStopTests.swift` (new), `README.md` (one feature line)
- Must not touch: `Sources/HeatLensCore/Safety/ProcessTerminator.swift`, `Sources/HeatLensCore/Rules/RulesEngine.swift`, `App/HeatLensApp.swift`, `App/StatusPanel.swift`, `App/ScanModel.swift`, `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/PopoverView.swift`, `Sources/HeatLensCLI/`, `scripts/`, `site/`, `dist/`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/` only if a small public accessor is unavoidable

## Phase
One phase: core, UI and tests. The click-through comes later.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/with-timeout.sh 600 swift build 2>&1 | tail -20 && scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`.

## Done when
- Checks pass with new tests:
  - Candidates: only leftover kinds with `.requestStop`, grouped per project, no-project groups excluded, hidden findings excluded, de-duplicated, ≥2 rule.
  - BatchStop with a fake closure: order, per-item outcomes, cancellation leaves the rest not attempted.
  - **A live BatchStop test** that spawns 3 `/bin/sleep 300` children, builds their real identities, runs BatchStop through the real `ProcessTerminator().requestStop`, and checks all 3 stop. In the same test, a 4th identity with a wrong start time comes back skipped and that process is still alive. Clean up every child in a `defer`.
- The `ResultsView` SwiftUI preview (fixture) shows the batch button and sheet. Render a screenshot of the sheet, through an `ImageRenderer` snapshot test or the preview, put it in your scratch folder and name the path in the handoff.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
