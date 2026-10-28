# v2 Phase 4a: SamplingPolicy and adaptive LiveMonitor (core + probe)
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 14:06 · terminal: 166b0047-d658-4c33-ace5-8b5b4c22552c

## Goal
Brief **4a** in `docs/v2/PHASE-4-PLAN.md` ("Adaptive sampling (4a)" design section and the
"4a · Core" brief, lines ~65–133), built exactly as specified there: `SamplingPolicy` +
`IncidentTracker`, adaptive mode in `LiveMonitor` (default `.fixed`, so today's behaviour is
unchanged), the sleep-gap reset in `AlertEvaluator`, the probe's `--background` mode, tests, and
the measured result in `docs/PERFORMANCE.md` §2.9.

## Context
- Owner decisions 2026-10-28 (all final, don't re-ask): intervals = idle 30 s power / 60 s battery;
  incident 5 s / 10 s; Low Power Mode 120 s, never fast; unknown power counts as battery.
- Read first: that PHASE-4-PLAN section, `docs/v2/ADR-0008-background-helper.md` §1 and §6 (how
  4b will consume this), `Sources/HeatLensCore/Live/LiveMonitor.swift`,
  `Sources/HeatLensCore/Rules/AlertPolicy.swift`, `Tests/HeatLensCoreTests/LiveMonitorTests.swift`.
- Previous design handoff: `handoffs/merged/2026-10-28-1800-v2-p4-design.md`. The polish handoff
  `handoffs/merged/2026-10-28-1800-v2-p3-polish.md` explains how LiveMonitor stitches tick spans
  (relevant to the 3× planned-interval sleep test).
- Patterns to copy: `AlertRule`'s static tables and tests; `LiveMonitorTests`' injected sleep.

## Scope
- May touch: `Sources/HeatLensCore/Live/SamplingPolicy.swift` (new),
  `Sources/HeatLensCore/Live/LiveMonitor.swift`, `Sources/HeatLensCore/Rules/AlertPolicy.swift`,
  `Sources/heatlens-probe/Live.swift`, `Sources/heatlens-probe/main.swift`,
  `Tests/HeatLensCoreTests/SamplingPolicyTests.swift` (new), `LiveMonitorTests.swift`,
  `AlertPolicyTests.swift`, `docs/PERFORMANCE.md` (new §2.9 only).
- Must not touch: `App/` (except the minimum to keep it compiling if a `LiveTick`/`LiveConfiguration`
  init changes — name it in the handoff), `Sources/HeatLensCore/Model/`, `Sources/HeatLensCore/Export/`
  (another worker is in `Export/` now), `Package.swift`, `project.yml`, CLI targets, other docs.
- PERFORMANCE.md: write measured numbers only, no real paths/usernames/process names (public repo).

## Phase
One phase: 4a only. 4b (BackgroundMonitor) is a later brief.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `swift test --filter "SamplingPolicy|LiveMonitor|AlertPolicy" 2>&1 | tail -30`, three runs in a row.
- Full suite once, only via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`.
- `scripts/run-app.sh --build-only 2>&1 | tail -20`.
- Measurement: `swift build -c release --product heatlens-probe`, then
  `/usr/bin/time -l .build/release/heatlens-probe --background 900` idle on power (≤ 0.3 % of one
  core, median interval 30 s) and a short `--assume-low-power` run (every interval 120 s). If the
  Mac is busy and the run comes back as incident cadence, say so and record what you saw rather
  than retrying for long.

## Questions first
The design is decided. If something in the spec is genuinely contradictory, put it in one first
handoff (`status: blocked`) and stop; otherwise build straight through.
