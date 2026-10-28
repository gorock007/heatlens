# v2 Phase 4d: HeatLensLog (os.Logger, names .private) and its call sites
worker: claude
model: sonnet
effort: medium
started: 2026-10-28 15:18 · terminal: 93f01d4c-4058-447a-9155-68ba6328d02f

## Goal
Brief **4d** in `docs/v2/PHASE-4-PLAN.md` ("Structured local logs (4d)" design + "4d · Core +
app", ~lines 142–204), built as specified: `Sources/HeatLensCore/Logging/HeatLensLog.swift` with
the typed `Value` enum (only `.name` carries a String, always `privacy: .private`), an internal
test `sink`, the listed call sites, and `HeatLensLogTests`. Plus two small extras below.

## Done when
- `swift test --filter HeatLensLog` passes three runs in a row: `.name` reaches the sink marked
  private; a 100-tick steady idle background session emits ≤ 1 notice; the grep test (`Logger(`
  only in `HeatLensLog.swift`, `privacy: .public` never on a `String`) passes.
- Full suite passes once under the lock; `scripts/run-app.sh --build-only` builds with no new warnings.
- During a 2-minute Debug Live session, `log stream --predicate 'subsystem == "dev.heatlens"' --level info`
  shows start/stop lines and no process or project names in clear (report counts/pass-fail only; no
  real names or paths in the handoff — public repo).

## Context
- Owner decision 4 (final): unified log via `os.Logger`, names `.private`, no log file of our own.
  Never log PIDs, paths, argv, environment or Docker IDs.
- Call sites (log lines only): `Live/LiveMonitor.swift` (session start, stop, auto-pause, failed,
  alert fired — rule and held seconds); `Background/BackgroundMonitor.swift` (mode/interval
  changes with reason; at most one persisted notice per 10 min in steady state);
  `History/HistoryStore.swift` (failures, delete); `Docker/DockerEngine.swift` (availability
  changes only); `App/HistoryService.swift` (`ActionLog.added`: action + outcome, target as `.name`).
- **Extra 1:** `App/IncidentExportSheet.swift` has the comment `// 4d: HeatLensLog.notice(.export, format, anonymized)`
  — replace it with the real call (format as `.word`, anonymised as `.flag`).
- **Extra 2:** `App/SettingsView.swift`, two stale strings now that background watching exists (4c,
  `handoffs/merged/2026-10-28-2100-v2-p4c-keep-watching-app.md`): line ~220 History caption "Only while
  Live runs." → "Only while Live runs or HeatLens is watching in the background."; line ~149 "Changes
  apply to the next scan or live start." → "Changes apply to the next scan, and to Live when you close
  Settings." Nothing else in that file.
- Patterns: `RedactionPatterns` (small static helper with tests); source-grep tests in `ForceQuitTests`.

## Scope
- May touch: `Sources/HeatLensCore/Logging/HeatLensLog.swift` (new),
  `Tests/HeatLensCoreTests/HeatLensLogTests.swift` (new), the five call-site files (log lines
  only), `App/IncidentExportSheet.swift` (extra 1 only), `App/SettingsView.swift` (extra 2 only).
- Must not touch: `Model/`, `Safety/` logic, `Package.swift`, `project.yml`, docs, and these App files
  another worker (4g) is editing now: `App/ProjectViews.swift`, `App/SettingsModel.swift`,
  `App/AlertSettingsSection.swift`, `App/LiveAlertService.swift`, `App/ProjectWatchSheet.swift`.

## Phase
One phase: 4d + the two extras.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/with-timeout.sh 600 swift test --filter HeatLensLog 2>&1 | tail -20` ×3
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`
- `scripts/run-app.sh --build-only 2>&1 | tail -20`
- The `log stream` check: run the Debug app (`scripts/run-app.sh`), Start live for 2 min, Pause; quit
  the app you launched by its PID afterwards. If the screen is locked, say so and skip it.

## Questions first
None expected. Genuine contradictions only: one blocked handoff, then stop.
