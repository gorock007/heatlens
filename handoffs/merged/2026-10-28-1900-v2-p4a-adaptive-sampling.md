# v2 Phase 4a: SamplingPolicy and adaptive LiveMonitor (core + probe)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1900-v2-p4a-adaptive-sampling.md

## What the user asked
Build brief 4a from `docs/v2/PHASE-4-PLAN.md`:
- `SamplingPolicy` and `IncidentTracker`;
- an adaptive mode in `LiveMonitor`, off by default so today's behaviour is unchanged;
- the sleep-gap reset in `AlertEvaluator`;
- the probe's `--background` mode;
- tests, and the measured result in `docs/PERFORMANCE.md` §2.9.

No questions were needed: the spec held together.

## What changed
- **`SamplingPolicy`** (new, `Live/SamplingPolicy.swift`) implements the PHASE-4-PLAN table.
  - `Mode` is `.fixed(TimeInterval)` or `.adaptive`. `Context` holds `viewerInterval`, `power`
    and `incident`. `Reason` is one of `viewer, idle, incident, battery, lowPowerMode, fixed`.
  - `next(_ context:)` returns a `Decision { interval, reason }`. `next(_ mode:, _ context:)`
    also handles `.fixed`.
  - The viewer always wins, clamped to 2...10 s. Low Power Mode is next: 120 s, never fast.
    Then incident: 5 s on power, 10 s otherwise. Then idle: 30 s on power (reason `idle`),
    60 s otherwise (reason `battery`). An unknown or unreadable power source counts as battery.
- **`IncidentTracker`** (same file) is fed one tick at a time through
  `update(_ tick:, alertsActive:) -> Bool`. Any one of these is a trigger:
  - `alertsActive`;
  - an explanation with no `endedAt`;
  - a `testRunStarted`, `expensiveCommandStarted`, `containerStarted`, `concurrentCommands` or
    `thermalChanged` event;
  - `hostBusyFraction` ≥ 0.6;
  - thermal state serious or above.

  The incident holds while less than 120 s has passed since the last trigger, timed by the
  ticks' own end times (no timer).
- **`LiveMonitor`**
  - New settings:
    - `LiveConfiguration.sampling: SamplingPolicy.Mode`, which defaults to `.fixed(interval)`;
    - `autoPauseAfter` is now `TimeInterval?` (nil never pauses; the default is still 15 min);
    - `setViewer(interval:)` on the actor. The viewer is kept across sessions, so 4b can set
      it before `start`.
  - After each tick the loop feeds `IncidentTracker`, using `alertEvaluator.isActive`, and
    waits for the policy's interval. The decision is recomputed just before the wait, so a
    picker or viewer change made during the history write still counts.
  - Ticks gain `LiveTick.plannedInterval` (the wait before this tick; warm-up 1 s for the
    first) and `LiveTick.sampling: SamplingPolicy.Decision?` (the wait after it, and why).
  - `setInterval` now updates `.fixed`'s interval, plus the viewer's when one is attached.
  - `.fixed` waits exactly as before: warm-up, then the interval.
- **`AlertEvaluator`**
  - New `isActive`: true while an enabled rule is holding, or has fired and not yet cleared.
    It is false while alerts are off.
  - New sleep-gap reset: a tick whose span is more than 3× `plannedInterval` resets the hold
    and clear timers, and those timers then **start at the tick's end**. Without that, the
    post-sleep tick's own 1-hour span would count as holding, and swap would fire anyway.
  - Cooldowns are kept. Ticks with no `plannedInterval` (hand-made in tests) never count as
    sleep.
- **Probe:** `heatlens-probe --background <seconds> [--assume-battery | --assume-low-power]`
  runs an adaptive session with sensors and Docker on and nobody looking.
  - Per tick it prints the span, the planned interval, the next interval and its reason, the
    host load, the power source, the number of events and the cost. Event kinds only, never
    names.
  - It ends with a summary: median span, median and max cost, and a count per reason.
  - It stops after `<seconds>` through `monitor.stop()`.
- **`docs/PERFORMANCE.md` §2.9** holds the measured numbers (below).

## Files
- Sources/HeatLensCore/Live/SamplingPolicy.swift — created
- Sources/HeatLensCore/Live/LiveMonitor.swift — modified
- Sources/HeatLensCore/Rules/AlertPolicy.swift — modified
- Sources/heatlens-probe/Live.swift — modified
- Sources/heatlens-probe/main.swift — modified
- Tests/HeatLensCoreTests/SamplingPolicyTests.swift — created
- Tests/HeatLensCoreTests/LiveMonitorTests.swift — modified
- Tests/HeatLensCoreTests/AlertPolicyTests.swift — modified
- docs/PERFORMANCE.md — modified (new §2 item 9 only)
- handoffs/2026-10-28-1900-v2-p4a-adaptive-sampling.md — created

## Checks run
- `swift build`: Build complete.
- `swift test --filter "SamplingPolicy|IncidentTracker|LiveMonitor|AlertPolicy"`, three runs in
  a row: 61 tests in 5 suites passed each time (1.6 s, 1.5 s, 1.5 s). Every existing
  LiveMonitor and AlertPolicy test is unchanged and passes.
- Full suite through the lock:
  `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test` gave 401
  tests in 61 suites, all passed, on the final tree. An earlier run, on the same code of mine,
  gave 393; the difference is the parallel 4h worker's tests in the shared checkout.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
  No `App/` change was needed.
- `swift build -c release --product heatlens-probe`: built.
- **Measurements** (on power, about 800 processes; details in PERFORMANCE §2.9):
  - **`--background 900`:** 904.6 s wall, 11.21 s CPU, which is **1.24% of one core**, with a
    20.6 MB peak footprint. **Every tick was at incident cadence:** 173 ticks, all planned
    at 5 s, median span 5.2 s.
    - The Mac was busy with other workers' builds and tests. Host load was 37–100% (median
      60%), 88 of 174 ticks had all cores at least 60% busy, and the run saw 24
      expensive-command and 8 test-run starts.
    - **So the idle-on-power target (≤ 0.3%, median 30 s) is NOT verified.** I recorded that
      instead of retrying, as the brief says.
    - The incident case is within its ≤ 2% budget. Extrapolated from about 65 ms of CPU per
      tick, 30 s would be about 0.22%. The doc labels that as an extrapolation.
  - **`--background 400 --assume-low-power`:** all 4 intervals were planned at 120 s even
    though the Mac was busy. 0.32 s CPU in 426 s is **0.075% of one core** (budget ≤ 0.1%),
    with a 12.4 MB peak.
  - **Spans run longer than planned:** 126.7–128.2 s for 120 s, because `Task.sleep` lets
    macOS add slack to long timers. This is well inside the 3× sleep threshold.
- `grep -nE "/Users/|gorock" docs/PERFORMANCE.md` printed nothing.
- `handoffs/bin/jarvis leftovers --mine`: nothing running.
- **Not checked:**
  - an idle-cadence run on a quiet Mac;
  - `--assume-battery` (it is covered by tests only);
  - a real sleep/wake cycle (the reset is covered by unit tests only);
  - anything in the app UI: 4a changes no app behaviour.

## Processes left running
none

## Questions for the user
None.

## Notes for Jarvis
- **Re-measure idle when the Mac is quiet** (no workers building or testing):
  `swift build -c release --product heatlens-probe && /usr/bin/time -l .build/release/heatlens-probe --background 900`.
  The summary line should read `reasons idle …` with a median span near 30 s, and CPU should
  stay ≤ 0.3% (≤ 2.7 s user+sys over 900 s). Then replace §2.9 note 1 with the result.
- **Places where I read the spec loosely** (all in 4a's own files):
  - `next` returns a `SamplingPolicy.Decision` struct (Hashable, Codable) instead of a tuple,
    and `LiveTick.sampling` is `Decision?`. That keeps 4j's Codable work possible; a tuple
    can't conform.
  - `LiveTick.plannedInterval` is optional, so hand-built ticks in other test files keep
    compiling and are never treated as sleep.
  - `LiveConfiguration(sampling:)` takes `Mode?`, where nil means `.fixed(interval)`.
  - `setViewer` doesn't cut the current wait short. 4b's `viewerAttached` should call
    `refreshNow()` after it, so the panel fills at once instead of after up to 120 s.
- **Design consequence to raise with the owner (no change made):** "an alert has fired and not
  yet cleared" counts as an incident. So with alerts on, a value that settles between `off`
  and `on` keeps the 5 s cadence for as long as it stays there. Examples: swap between 1 and
  2 GB after a swap alert, or memory between 80 and 90% used. That could be hours. A possible
  follow-up is to count only "holding" and "fired within the last N minutes". Alerts are off
  by default, so the measured budgets aren't affected.
- **No shared files touched.** No `App/`, `Model/`, `Export/` or `Package.swift` edits.
- **Suggested commit:** `feat(v2): Phase 4a — SamplingPolicy + IncidentTracker, adaptive
  LiveMonitor (default .fixed), sleep-gap alert reset, probe --background; PERFORMANCE §2.9`
- **Docs to update later** (PHASE-4-PLAN's list): only §2.9 is done here. README and
  LIMITATIONS change with 4c.
