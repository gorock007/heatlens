# v2 Phase 4f: ProjectWatch, shared rule state, watch evaluation (core) + incident-cadence fix
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 14:33 · terminal: 0b8cc7dd-9806-417d-8420-b323ddcfc036

## Goal
Brief **4f** in `docs/v2/PHASE-4-PLAN.md` ("Watchlists (4f, 4g)" design and "4f · Core", ~lines
252–311), built as specified: `Rules/Watchlist.swift` (`ProjectWatch`, presets,
`WatchlistEvaluator`), `AlertRuleState` extracted from `AlertEvaluator` and shared by system rules
and watches, `Alert.watch` + optional `rule`, `AlertConfiguration.watches`,
`LiveTick.runningCommandsByProject`, and `WatchlistTests`. Plus one extra fix (below).

## Context
- Owner decision 6 (final): watches are set up from a Projects-card row (that's 4g, app), keyed by
  project folder, preset thresholds only, alert-only, reusing AlertEvaluator's hysteresis and
  cooldown. No free-form numbers, no enforcement.
- Read first: that PHASE-4-PLAN section; `Sources/HeatLensCore/Rules/AlertPolicy.swift`,
  `Sources/HeatLensCore/Live/SamplingPolicy.swift` and `LiveMonitor.swift` as merged by 4a
  (`handoffs/merged/2026-10-28-1900-v2-p4a-adaptive-sampling.md`).
- **Extra fix (Jarvis ruling, from 4a's notes):** `AlertEvaluator.isActive` counts "fired and not
  yet cleared" as active, so a value settling between `off` and `on` after an alert (e.g. swap
  1–2 GB) keeps the 5 s incident cadence for hours. Change it so only *holding* (at/above `on`,
  sustain timer running) counts; a tick on which an alert fired counts too (so the 120 s
  `IncidentTracker` hold covers the aftermath). Watches follow the same rule. Add a test: after an
  alert fires and the value settles between off and on, the incident ends ~120 s later.
  Update `SamplingPolicy.swift`/`IncidentTracker` only if needed for that, and the doc comment.
- The refactor's proof: every existing `AlertPolicyTests` case passes unchanged (except any test
  that asserted the old isActive meaning — name it and why in the handoff).

## Scope
- May touch: `Sources/HeatLensCore/Rules/Watchlist.swift` (new), `Rules/AlertPolicy.swift`,
  `Live/ConcurrencyRules.swift`, `Live/LiveMonitor.swift`, `Live/SamplingPolicy.swift` (extra fix
  only), `App/LiveAlertService.swift` (only what keeps it compiling with an optional `rule`),
  `App/IncidentExportSheet.swift` / `Export/IncidentReport.swift` only if an optional `rule` breaks
  compilation (4h says it doesn't read `rule`), `Tests/HeatLensCoreTests/WatchlistTests.swift`
  (new), `AlertPolicyTests.swift`, `SamplingPolicyTests.swift`.
- Must not touch: `Sources/HeatLensCore/Background/` and `BackgroundMonitorTests.swift` — **another
  worker (4b) is creating those now**; `Model/`, `Safety/`, `Docker/`, `Package.swift`,
  `project.yml`, other `App/` files, docs.

## Phase
One phase: 4f + the extra fix. The app UI (4g) is a later brief.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/with-timeout.sh 600 swift test --filter "Watchlist|AlertPolicy|ConcurrencyRules|SamplingPolicy|IncidentTracker|LiveMonitor" 2>&1 | tail -30`, three runs in a row.
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`.
- `scripts/run-app.sh --build-only 2>&1 | tail -20`.

## Questions first
The design is decided. Genuine contradictions only: one blocked handoff, then stop.
