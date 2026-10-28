# v2 Phase 4b: BackgroundMonitor (core)
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 14:33 · terminal: 58adaca5-d3a4-4ad2-bb5e-ed4895fbf399

## Goal
Brief **4b** in `docs/v2/ADR-0008-background-helper.md` ("Build briefs → 4b · Core:
`BackgroundMonitor`", ~lines 325–356), built as specified: `public actor BackgroundMonitor` in
`Sources/HeatLensCore/Background/BackgroundMonitor.swift` owning one `LiveMonitor`, with the API,
rules, recent-alerts ring and `BackgroundMonitorTests` listed there.

## Context
- Read first: ADR-0008 §1 (one core, two hosts), §3 (what runs where), §4 (lifecycle table, v2.0
  column) and the 4b brief; `Sources/HeatLensCore/Live/LiveMonitor.swift` and
  `Sources/HeatLensCore/Live/SamplingPolicy.swift` as merged by 4a.
- Previous handoff: `handoffs/merged/2026-10-28-1900-v2-p4a-adaptive-sampling.md`. Its Notes say:
  `setViewer` doesn't cut the current wait short, so `viewerAttached` must call `refreshNow()` after
  it, so the panel fills at once instead of after up to 120 s. `LiveConfiguration(sampling:)` takes
  `Mode?`; `autoPauseAfter: nil` never pauses.
- Owner decisions (final): v2.0 is in-app only; the helper is v2.1. The monitor never signals and
  never stops anything.
- Pattern to copy: `LiveMonitor`'s session ID and `stop(session:)` guard; per-subscriber
  `AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(2))`; `LiveMonitorTests` fakes and the
  instant-sleep init.
- "15 minutes of foreground → background cadence" with keepWatching on: with keepWatching off,
  keep today's 15-min auto-pause exactly.

## Scope
- May touch: `Sources/HeatLensCore/Background/BackgroundMonitor.swift` (new),
  `Tests/HeatLensCoreTests/BackgroundMonitorTests.swift` (new).
- Must not touch: `Sources/HeatLensCore/Live/LiveMonitor.swift`, `Rules/AlertPolicy.swift`,
  `Live/ConcurrencyRules.swift` — **another worker (4f watchlists) is editing those now**. If
  4b genuinely needs a hook in `LiveMonitor`, don't add it: build around it if you can, otherwise
  write a blocked handoff naming the exact hook. Also must not touch `App/`, `Model/`,
  `Package.swift`, `project.yml`, CLI targets, docs.

## Phase
One phase: 4b. The app side (4c) is the next brief.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/with-timeout.sh 600 swift test --filter "BackgroundMonitor|LiveMonitor" 2>&1 | tail -30`, three runs in a row.
- `grep -rnE "kill\(|requestStop|forceQuit|ContainerStopper|StopLedger" Sources/HeatLensCore/Background/` prints nothing.
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`.
- `scripts/run-app.sh --build-only 2>&1 | tail -20`.

## Questions first
The design is decided. Genuine contradictions only: one blocked handoff, then stop.
