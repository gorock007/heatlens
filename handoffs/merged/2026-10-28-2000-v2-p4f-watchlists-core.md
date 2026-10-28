# v2 Phase 4f: ProjectWatch, shared rule state, watch evaluation (core) + incident-cadence fix
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-2000-v2-p4f-watchlists-core.md

## What the user asked
Build brief 4f from `docs/v2/PHASE-4-PLAN.md`:
- `ProjectWatch`, its presets and `WatchlistEvaluator`;
- `AlertRuleState`, pulled out of `AlertEvaluator` and shared by system rules and watches;
- `Alert.watch`, with `rule` now optional;
- `AlertConfiguration.watches` and `LiveTick.runningCommandsByProject`;
- `WatchlistTests`.

Plus one fix ruled by Jarvis: `AlertEvaluator.isActive` should count only *holding*, or a firing
on this tick, so a value that settles between `off` and `on` no longer keeps the 5 s incident
cadence running for hours.

No questions were needed: the spec held together.

## What changed
- **`AlertRuleState`** (in `Rules/AlertPolicy.swift`) is the per-rule state machine: hold, clear,
  armed, cooldown and last fired. It has two parts:
  - `step(_ value:, limits:, start:, end:) -> TimeInterval?` returns how long the value held when
    it fires. A nil value resets the timers.
  - `AlertRuleState.Limits` holds `on`, `off`, `sustain`, `clear` and `cooldown`.
    `AlertRule.limits` builds one from a rule.

  `AlertEvaluator` now runs every system rule and every watch through it. The gap reset, the
  sleep reset and the master switch stay in `AlertEvaluator` and cover watches too. The logic is
  the same code as before, moved.
- **The `isActive` fix:**
  - `AlertRuleState.isActive` is "holding at or above `on` with the sustain timer running, or
    fired on the last step".
  - `AlertEvaluator.isActive` is true when any enabled rule, or any watched metric, is active.
  - So `IncidentTracker`'s 120 s hold covers the aftermath of a firing, and then the incident
    ends.
  - Literal consequence: a value that **stays above `on`** after firing (swap at 3 GB for an
    hour) also ends the incident 120 s after the firing, unless another trigger fires (busy cores,
    events and so on). That case doesn't count as holding, because no sustain timer is running.
  - Doc comments in `AlertPolicy.swift` and `SamplingPolicy.swift` (`IncidentTracker.update`) now
    say this. `SamplingPolicy`'s code is unchanged.
  - There is a new internal `AlertEvaluator.isArmed(_ kind:)` for tests.
- **`ProjectWatch`** (new file, `Rules/Watchlist.swift`). It is Codable, Hashable and
  Identifiable by `projectID`. It has these fields:
  - `projectID`: `Project.id`, lowercased, and it must be absolute.
  - `name`: at most 80 characters. Control characters are stripped. An empty name becomes the
    folder's name.
  - `cpu`: % of one core. Presets are 100→75, 200→150 and 400→300.
  - `memory`: GB. Presets are 2→1.5, 4→3 and 8→6.
  - `commands`: presets are 2→2 and 3→3.

  Every threshold is optional (nil means off). `init?` and decoding reject any value that is not
  a preset: there are no free-form numbers.
  - `limits(_:on:)` gives the PHASE-4-PLAN timing: CPU and memory sustain 2 min and clear 1 min;
    commands sustain 30 s and clear 0; the cooldown is 15 min for all.
  - Other helpers: `choices(_:)`, `describe(_:for:)`, `threshold(_:)` and `isWatching`.
  - **Storage:**
    - `ProjectWatch.parse(Data) -> (watches, notice?)` reads the setting. It drops entries that
      don't decode, keeps the first of any repeated project, and keeps at most `maxWatches = 50`.
    - The notice reads "N watched projects couldn't be read and were dropped." and/or "Only the
      first 50 watched projects are kept." If the setting isn't a JSON array, everything is
      dropped with a notice.
    - `ProjectWatch.encoded(_:)` writes sorted-key JSON.
  - `ProjectWatch.hash(of:)` is a 16-hex FNV-1a of the project ID. It is path-free, for 4g's
    notification identifier.
- **`WatchlistEvaluator`** (same file) keeps one `AlertRuleState` per project and metric.
  - A project missing from the tick has no value: its timers reset and it never fires.
  - The state of a removed watch, or a metric turned off, is forgotten.
  - Values:
    - CPU is `ProjectUsage.totalCPUPercent`, the Projects card's figure.
    - Memory is `memoryBytes + containerMemoryBytes`, in GB. The card shows both figures and
      `AlertEvaluator.topProjects` already ranks memory by that sum.
    - Commands is `tick.runningCommandsByProject[id] ?? 0`.
  - **Alert wording** (`rule: nil`, `watch: Alert.Watch(projectName, metric, projectHash)`,
    `projects: [name]`):
    - "FDA above 200% CPU for 2 minutes"
    - "FDA above 4 GB memory for 2 minutes"
    - "FDA running 2 or more expensive commands at once for 30 seconds"
  - Observations are the value now, the threshold ("200%; clears below 150%", source "your watch
    on FDA"), how long it held, and the busiest processes: up to 3 distinct names, ranked by memory
    for a memory watch.
  - The suggestion is "Its busiest processes are node, swift-build; see Projects.", or "See
    Projects in Live." when there are none. Names only: no paths, no actions.
  - The alert ID is `alert-watch-<metric>-<hash>-<ms>`.
- **`Alert`** gains `watch: Watch?`, and `rule` is now `AlertRule.Kind?`. The init takes
  `watch:` with a default of nil, so existing callers still compile.
- **`AlertConfiguration.watches: [ProjectWatch]`** defaults to empty. Watches run only while
  `isEnabled` is on.
- **`ConcurrencyRules.runningByProject`** counts the outermost expensive commands on each tick
  per `Project.id`, from the classification cache that already exists. **`LiveMonitor`** copies
  it into the new **`LiveTick.runningCommandsByProject`** (default empty) before alerts run.
- **`App/LiveAlertService.swift`:** the notification identifier is now
  `prefix + (alert.rule?.rawValue ?? alert.id)`, so it compiles with an optional `rule`. The
  thermal check compiles unchanged. 4g replaces the watch identifier and the body.

## Files
- Sources/HeatLensCore/Rules/Watchlist.swift — created
- Sources/HeatLensCore/Rules/AlertPolicy.swift — modified
- Sources/HeatLensCore/Live/ConcurrencyRules.swift — modified
- Sources/HeatLensCore/Live/LiveMonitor.swift — modified
- Sources/HeatLensCore/Live/SamplingPolicy.swift — modified (doc comment only)
- App/LiveAlertService.swift — modified (one line)
- Tests/HeatLensCoreTests/WatchlistTests.swift — created
- Tests/HeatLensCoreTests/AlertPolicyTests.swift — modified
- handoffs/2026-10-28-2000-v2-p4f-watchlists-core.md — created

## Checks run
- `swift build`: Build complete. `swift build --build-tests` shows no warnings in the touched
  files.
- `scripts/with-timeout.sh 600 swift test --filter "Watchlist|AlertPolicy|ConcurrencyRules|SamplingPolicy|IncidentTracker|LiveMonitor"`,
  three runs in a row: 88 tests in 7 suites passed each time (1.6 s, 1.4 s, 1.6 s). Every
  `ConcurrencyRulesTests` case is unchanged and passes.
- `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`: 414 tests in
  62 suites passed.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- **`AlertPolicyTests` edits** (every other case is unchanged and passes):
  - `jitteredTicks` and `wording`: `map(\.rule)` became `compactMap(\.rule)` in one line each. A
    `[Kind?]` can't be sorted by `rawValue` or compared to `Set<Kind>`. Compile-only; the
    assertions are the same.
  - **`sleepGapResetsClearing` asserted the old `isActive` meaning.** After the sleep it expected
    `isActive` to be true while the rule hadn't cleared. Those two lines now assert
    `!isArmed(.sustainedCPU)`, which is what they were checking. A third line asserts that it
    re-armed. The rest is unchanged.
  - `isActive`: title only, to the new meaning. Its assertions pass unchanged.
  - New `incidentEndsAfterFiring` (memory, swap, containers): fire, then hold the value between
    `off` and `on` for an hour. The incident ends exactly 120 s after the firing and stays ended.
    CPU is left out because its in-between of 70% counts as busy cores, a trigger of its own.
    Thermal has no in-between.
- **`WatchlistTests`** (13 tests):
  - each metric fires after sustain;
  - hysteresis and cooldown per metric;
  - an absent project resets, and so does a gap;
  - two projects stay independent;
  - several metrics on one project;
  - master switch off;
  - `isActive`;
  - presets only;
  - storage, including malformed JSON with its notice;
  - wording, with no "/" and no action words;
  - `ConcurrencyRules.runningByProject` against real classification and attribution;
  - 50 watches × 300 projects: under 10 ms per tick in debug, 1 ms in release. It passed in debug.
- **Not checked:**
  - the release-build timing bound (tests ran in debug only);
  - an end-to-end `LiveMonitor` test that `runningCommandsByProject` lands on the tick (it's a
    one-line copy, covered at the `ConcurrencyRules` level);
  - anything in the app UI: 4f adds none.
- `handoffs/bin/jarvis leftovers --mine`: nothing running.

## Processes left running
none

## Questions for the user
None.

## Notes for Jarvis
- **Shared files:** none of `Model/`, `Package.swift`, `project.yml` or entitlements. `App/` has
  one line in `LiveAlertService.swift`, as the brief allowed.
- `git status` shows `Sources/HeatLensCore/Background/`. That is 4b's, not mine, and it is not in
  my file list.
- **Places where I read the spec loosely:**
  - Memory is host plus Docker memory (see above).
  - `ProjectWatch` stores memory in GB and CPU in % of one core.
  - `Alert.Watch` also carries `projectHash`, so 4g's identifier
    `dev.heatlens.live-alert.watch.<metric>.<projectID hash>` can be built without a path in the
    alert.
  - `maxWatches = 50`, after `WorkloadRule.maxRules`.
  - The alert names the project by the watch's stored name, which is also what 4g's "Watched
    projects" list shows.
- **For 4g:**
  - Read the setting with `ProjectWatch.parse(UserDefaults…data(forKey: "projectWatches"))` and
    show its `notice`.
  - Write it with `ProjectWatch.encoded(_:)`.
  - Build pickers from `ProjectWatch.choices(metric)` with `describe`.
  - Get the identifier from `alert.watch?.metric` and `alert.watch?.projectHash`.
- **Behaviour change to tell the owner:** with alerts on, the incident cadence now ends 2 minutes
  after a firing even if the value stays high, unless another trigger keeps it going. Alerts are
  off by default.
- **Suggested commit:** `feat(v2): Phase 4f — ProjectWatch presets + WatchlistEvaluator, shared AlertRuleState, Alert.watch (rule optional), LiveTick.runningCommandsByProject; isActive counts holding or firing only, so the incident cadence ends 120 s after an alert`
