# Phase 2b process detail, safe-stop flow, group limits and settings
status: done
agent: codex gpt-5.6-sol
brief: handoffs/briefs/2026-10-26-1803-p2b-detail-stop-settings-ui.md

## What the user asked
Add the App-side process detail screen, explicit SIGTERM confirmation/outcome flow, a usable
large group list, and persisted sample/exclusion/launch-at-login settings without adding idle work.

## What changed
- **Process detail:** Inspect and every group member row open an in-popover detail view. It shows
  PID, the parent chain found in the snapshot, owner, uptime, executable, shell-joined command,
  cwd, sampled CPU/memory (including `via ps`), project basis/confidence, and every naming
  finding's evidence and limitations. Actions are Copy PID, Copy command, Open project, Activity
  Monitor and, only when offered and eligible, Request stop. An offered-but-denied stop shows the
  engine's plain denial reason.
- **Request stop:** Finding cards and detail use the real `HeatLensCore.ProcessTerminator` delivered
  by Phase 2a. Request stop opens an in-popover sheet with the exact PID, command, project,
  measured impact and the required interruption warning. Cancel is the default action; Send
  SIGTERM has destructive styling and no default focus. The sheet shows progress, maps every
  `StopOutcome` to plain words, explicitly says HeatLens does not force-quit on `.stillRunning`,
  and offers Scan again. The preview-only stopper returns `.stopped` without signalling anything.
- **Group list:** Groups are sorted by summed sampled CPU. The collapsed view shows the top 12
  non-idle groups, summarizes fully measured 0%-CPU / under-50-MB groups as `N idle groups`, and
  offers `Show all N groups`; expanded mode includes every group.
- **Settings:** A gear in the popover header opens settings in the same popover. Sample duration
  is 5/10/15 seconds (10 default) and drives `ScanModel`. Exact process-name exclusions and
  project-directory-prefix exclusions are newline lists in `UserDefaults`; a finding is hidden
  only when all of its affected processes match, and the result view reports the hidden count.
  Launch at login uses `SMAppService.mainApp`, starts off unless already registered, refreshes the
  real service status and reports registration errors. The UI states that no scan history is kept.
- **Idle work:** Removed the idle `TimelineView`; there are no timers or observers outside a user-
  started scan or stop. `ServiceManagement` auto-linked successfully, so `project.yml` was not edited.
- **Fixture:** Removed Request stop from the synthetic high-CPU finding; only the synthetic stale
  server and detached worker offer it, matching the rules engine.

## Files
- App/FindingCard.swift — modified
- App/FixtureScanService.swift — modified
- App/Formatting.swift — modified
- App/HeatLensApp.swift — modified
- App/PopoverView.swift — modified
- App/ProcessDetailView.swift — created
- App/ResultsView.swift — modified
- App/ScanModel.swift — modified
- App/SettingsModel.swift — created
- App/SettingsView.swift — created
- App/StopService.swift — created
- handoffs/2026-10-26-1816-p2b-detail-stop-settings-ui.md — created

## Checks run
- `scripts/run-app.sh --build-only 2>&1 | tail -20` — passed after the final edits; built
  `.build/xcode/Build/Products/Debug/HeatLens.app`.
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build --scratch-path scratchpad/p2b-detail-stop-settings/swiftpm 2>&1 | tail -20 && swift test --scratch-path scratchpad/p2b-detail-stop-settings/swiftpm 2>&1 | tail -30`
  — build passed; **92 tests in 17 suites passed** in 4.101 seconds. A private scratch path was used
  because another worker's long-running SwiftPM test held the shared `.build` lock.
- The mandated default-path `swift build && swift test` was attempted, but it remained waiting on
  that unrelated shared SwiftPM process. I stopped only my waiting `swift-build` and shell by their
  exact PIDs; I did not touch the other worker's process. The equivalent isolated run above passed.
- `git diff --check -- App` — passed.
- Idle app check: launched this built executable as PID 53320, waited 30 seconds, then
  `ps -p 53320 -o pid=,%cpu=,rss=,time=` reported **0.0% CPU, 74,000 KB RSS, 0:00.21 CPU time**.
  Quit via `osascript -e 'quit app "HeatLens"'`; the PID and app process were gone.
- Preview code, including the fixture stop service, compiled as part of the Debug App build.
- Not checked interactively: I did not click the menu-bar UI or run the Canvas preview. In
  particular, I did not click Send SIGTERM on any real process and did not toggle the real login item.

User verification — run `scripts/run-app.sh`, then click exactly these:

1. Click the **thermometer**, then the **gear**. Confirm **10 s** is selected and launch at login
   reports its real status. Select **5 s**, click **Done**, then **Scan now**; progress should end at
   5 seconds. Return to Settings and restore **10 s** when finished.
2. In results, under **What's using resources**, expect at most 12 group rows plus an `N idle groups`
   note and **Show all N groups**. Click that button, then **Show fewer groups**.
3. Expand a group and click one member row. Confirm the detail view contains PID, named parent chain,
   owner, uptime, executable, command, directory, sampled CPU/memory, project basis/confidence, and
   finding evidence/limitations. Click **Copy PID** and **Copy command**, then **Back**.
4. Click the **gear**. Add the exact process name from a leftover finding under **Excluded processes**,
   then click **Done**. Expect `1 finding hidden by your exclusions` (or the applicable count). Remove
   that line afterward. Repeat with that finding's project directory prefix under **Excluded projects**.
5. On an eligible Potential leftovers card, click **Request stop**. Confirm the sheet shows the exact
   PID, command, project, impact sentence and interruption warning. Press Return or click **Cancel**;
   it must cancel. **Do not click Send SIGTERM on this real-process screen.**
6. To exercise the safe synthetic outcome, open `App/ResultsView.swift` in Xcode Canvas, run the
   **Results** preview, click the detached-worker card's **Request stop**, then **Send SIGTERM**. It
   signals nothing; expect progress, `Process PID 12874 exited after SIGTERM.`, and **Scan again**.

## Processes left running
none

## Notes for Jarvis
- No shared file was edited. `project.yml` did not need a ServiceManagement link change.
- Phase 2a's real safety API appeared while this task was in progress. I deleted the temporary App
  stub before the final build; `App/StopService.swift` now imports and calls the core implementation.
- The shared checkout still contained other workers' uncommitted Core/Test/provenance changes while
  this handoff was written. Commit only the App files and this handoff listed above for Phase 2b.
- Suggested commit message: `feat(app): add process detail, safe stop flow, group limits and settings (Phase 2b)`
