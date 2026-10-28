# HeatLens v2 — Phase 4 plan: background monitoring, policy and polish

Date 2026-10-28. Source: PRD-v2 §6 Phase 4. Plan: [PLAN.md](PLAN.md). Decision record for
background monitoring and the helper: [ADR-0008](ADR-0008-background-helper.md). Previous:
[PHASE-3-REPORT.md](PHASE-3-REPORT.md).

**Phase 4 exit (PRD-v2):** a stable daily-driver release with controlled resource overhead and a
reversible installer/uninstaller.

Rulings in force throughout: new behaviour is off by default; HeatLens explains and offers typed
actions only; the CLI and MCP are read-only; nothing is stored except settings unless Keep history
is on (with owner decision 4's log exception); Live and background monitoring never stop
anything; only Jarvis signs, notarizes, installs outside the repo and changes entitlements.

## Owner decisions (2026-10-28)

Asked in `handoffs/2026-10-28-1800-v2-p4-design.md`. All nine recommendations were accepted.

1. **Helper timing.** v2.0 ships in-app background monitoring, "Keep watching in the background"
   (opt-in, off), on a shared core `BackgroundMonitor`. The LaunchAgent + XPC helper ships in
   v2.1 (ADR-0008).
2. **Focus.** Background alerts respect Focus: the default `.active` interruption level, never
   Time Sensitive.
3. **Quit and notifications.** Quit pauses background monitoring until the app opens again. The
   helper never posts notifications: the app posts them, and alerts raised while it was closed
   are listed on the next open. Turning the switch off unregisters the helper.
4. **Logs.** Operational events go to the macOS unified log through `os.Logger`, with process and
   project names marked `.private`. HeatLens writes no log file of its own.
5. **Incident export.** Keep names, explanations, alerts, the incident's timeline ±2 min and that
   window's action records. Drop PIDs, paths, argv and container IDs. Everything goes through
   `Redactor`. The file is written only where the user picks in a Save panel (Markdown or JSON).
   An optional switch replaces project names with "Project A, B…".
6. **Watchlists.** Set up from a Projects-card row, keyed by the project's folder, with preset
   thresholds. They alert only and reuse `AlertEvaluator`'s hysteresis and cooldown.
7. **MCP.** Read-only `live_status`, `recent_alerts` and `explanations` tools sit behind an off
   switch. They answer only while the helper samples, the helper checks the caller's code
   signature on every connection, and a call never starts sampling. They land with the helper
   (v2.1).
8. **Battery.** Idle every 30 s on power and 60 s on battery; incident every 5 s and 10 s; Low
   Power Mode every 120 s and never fast.
9. **Auto-update.** The click-only update check stays for v2. Auto-update is deferred.

## Order

| Brief | Release | What | Needs | Where it's specified |
|---|---|---|---|---|
| 4a | v2.0 | Adaptive sampling policy (core + probe) | — | below |
| 4b | v2.0 | `BackgroundMonitor` (core) | 4a | ADR-0008 |
| 4c | v2.0 | "Keep watching in the background" (app) | 4b | ADR-0008 |
| 4d | v2.0 | Structured local logs | 4b (it logs mode changes) | below |
| 4e | v2.0 | Crash recovery | 4c, 4d | below |
| 4f | v2.0 | Watchlists (core) | 4a (`LiveTick` fields) | below |
| 4g | v2.0 | Watchlists (app) | 4f, 4c | below |
| 4h | v2.0 | Incident export (core) | — | below |
| 4i | v2.0 | Incident export (app) | 4h | below |
| 4j | v2.1 | Helper protocol, codec, XPC server/client (core) | 4b, 4f | ADR-0008 |
| 4k | v2.1 | Helper target, registration, app client (signed build for verification) | 4j | ADR-0008 |
| 4l | v2.1 | MCP read-only live tools | 4k | below |

4a → 4b → 4c is the critical path. 4h can run in parallel with it, and 4f can start as soon as 4a
lands. 4d touches files that 4b and 4c also touch, so it runs after them, not alongside. Every
brief ends green on `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build
&& swift test` and `scripts/run-app.sh --build-only`.

## Adaptive sampling (4a)

**Design.** A `SamplingPolicy` picks the next interval after every tick and says why. The panel's
interval picker (2/5/10 s) still applies whenever someone is looking at Live. ADR-0003's
"no interval under 2 s" holds; the background intervals are all longer.

| Situation | On power | On battery (or power source unknown) | Low Power Mode |
|---|---|---|---|
| Viewer on Live | user's 2/5/10 s | user's 2/5/10 s | user's 2/5/10 s |
| Incident | 5 s | 10 s | 120 s (never fast) |
| Idle | 30 s | 60 s | 120 s |

- **What makes an incident.** Any one of these on a tick:
  - an alert rule (or watch) is holding or has fired and not yet cleared;
  - an explanation has no `endedAt`;
  - the tick produced a `testRunStarted`, `expensiveCommandStarted`, `containerStarted`,
    `concurrentCommands` or `thermalChanged` event;
  - all cores are at least 60 % busy;
  - the thermal state is serious or above.

  The incident cadence holds for **2 minutes after the last trigger**, then drops back to idle,
  so one quiet tick doesn't flap the cadence.
- **Why the triggers include starts.** `ConcurrencyRules` dates commands by their fork time, so a
  burst is still explained after a 30 s idle tick, as long as the processes are alive at the
  tick. A container's start time is the tick that first saw it, so idle ticks can place it up to
  one interval late. Going fast on the first start keeps the rest of a burst precise. The
  explanation's uncertainty line already says "up to one refresh late".
- **Power facts** come from `PowerContext` (`source`, `lowPowerMode`). It is read on every tick
  even with hardware sensors off (`DisabledHardwareProvider`). Apple:
  [`ProcessInfo.isLowPowerModeEnabled`](https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled).
- **Sleep and wake.** A tick whose span exceeds 3× the planned interval (the Mac slept) resets
  alert hold and clear timers, so "swap above 2 GB for 1 minute" can't fire on time spent asleep.
  Cooldowns are kept.
- **Product decisions:** the intervals (owner decision 8). Nothing else open.

### 4a · Core: `SamplingPolicy` and adaptive `LiveMonitor` (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Live/SamplingPolicy.swift` (new): `SamplingPolicy` with
    `enum Mode { fixed(TimeInterval), adaptive }`, `struct Context { viewerInterval:
    TimeInterval?; power: PowerContext?; incident: Bool }`, `enum Reason: String { viewer, idle,
    incident, battery, lowPowerMode, fixed }`, and `static func next(_ context:) ->
    (interval: TimeInterval, reason: Reason)` implementing the table. Add `IncidentTracker`, a
    struct fed each tick, with a 120 s hold, implementing the trigger list.
  - `Sources/HeatLensCore/Live/LiveMonitor.swift`: `LiveConfiguration.sampling: SamplingPolicy.Mode`
    (default `.fixed(interval)`, so today's behaviour is unchanged); `autoPauseAfter:
    TimeInterval?` (nil = never); `setViewer(interval: TimeInterval?)`. After each tick the loop
    waits `next(...)` instead of `interval`. `LiveTick` gains `plannedInterval` and
    `sampling: (interval, reason)`. Keep the 2...10 clamp for viewer intervals only.
  - `Sources/HeatLensCore/Rules/AlertPolicy.swift`: `AlertEvaluator` resets hold and clear timers
    when `tick.snapshot.interval > 3 × tick.plannedInterval`.
  - `Sources/heatlens-probe/Live.swift` and `main.swift`: `--background <seconds>
    [--assume-battery | --assume-low-power]`, an adaptive session printing each tick's interval,
    reason and cost.
  - Tests: `Tests/HeatLensCoreTests/SamplingPolicyTests.swift` (new): every cell of the table;
    Low Power Mode never fast; unknown power counts as battery; the 120 s hold; the viewer wins.
    `LiveMonitorTests.swift`: an adaptive session's recorded sleeps follow the policy; `.fixed`
    is unchanged. `AlertPolicyTests.swift`: the sleep-gap reset.
- **Pattern to copy:** `AlertRule`'s static tables and tests; `LiveMonitorTests`' injected sleep.
- **Done when:** the tests pass three runs in a row; every existing `LiveMonitor`/`AlertPolicy`
  test passes unchanged. `/usr/bin/time -l .build/release/heatlens-probe --background 900`, run
  idle on power, averages ≤ 0.3 % of one core with a median interval of 30 s; with
  `--assume-low-power`, every interval is 120 s. Results go in `docs/PERFORMANCE.md` §2.9.
- **May touch:** `Sources/HeatLensCore/Live/SamplingPolicy.swift` (new),
  `Sources/HeatLensCore/Live/LiveMonitor.swift`, `Sources/HeatLensCore/Rules/AlertPolicy.swift`,
  `Sources/heatlens-probe/Live.swift`, `Sources/heatlens-probe/main.swift`, the three test files,
  `docs/PERFORMANCE.md` (new §2.9 only).
- **Must not touch:** `App/`, `Model/`, `Package.swift`, `project.yml`, the CLI targets, other docs.

## Background monitoring (4b, 4c) and the helper (4j, 4k)

These are designed in [ADR-0008](ADR-0008-background-helper.md), which carries the build briefs.
In short, v2.0 keeps sampling in the app after the panel closes, behind "Keep watching in the
background" (off). v2.1 moves the same core into a LaunchAgent started on demand, which the app
talks to over XPC with code-signing checks. The helper never signals and never posts
notifications.

## Structured local logs (4d)

**Design.** One logging entry point in `HeatLensCore`, whose types decide what is public:

```swift
public enum HeatLensLog {
    public enum Category: String { live, background, history, docker, alerts, actions, helper, export }
    public enum Value: Sendable {
        case count(Int), seconds(Double), percent(Double), flag(Bool), word(StaticString)
        case name(String)          // process, project, container names: always privacy .private
    }
    public static func notice(_ category: Category, _ event: StaticString, _ values: KeyValuePairs<StaticString, Value> = [:])
    public static func error(...)  // same shape
    public static func debug(...)  // per-tick detail; not persisted by macOS
}
```

- **Backed by** [`os.Logger`](https://developer.apple.com/documentation/os/logger), subsystem
  `dev.heatlens`. `.name` is interpolated `privacy: .private`, so saved logs show `<private>`.
  Every other case is `.public`, because they are numbers and static words. There's no
  `String` case that could be public, so nobody can log argv or a path by accident. Never log
  PIDs, paths, argv, environment or Docker IDs.
- **What's logged** at notice/error (persisted by macOS; see Apple's
  [Generating log messages from your code](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)):
  - session start, stop, auto-pause and failure;
  - background mode and interval changes, with their reason;
  - history open, write and delete failures;
  - Docker availability changes;
  - an alert firing (rule and held seconds);
  - each action record (action and outcome; the target as `.name`);
  - an export saved (format, anonymised flag);
  - helper connect, refusal and version mismatch (v2.1).

  Per-tick data is `debug` only. A steady background session writes **no more than one persisted
  message per 10 minutes**.
- **No file of our own.** macOS rotates the unified log. A user reads it with
  `log show --last 1h --info --predicate 'subsystem == "dev.heatlens"'`, and Jarvis adds that line
  to LIMITATIONS/README.
- **Product decisions:** owner decision 4. None open.

### 4d · Core + app: `HeatLensLog` and its call sites (claude, sonnet, medium)

- **Do:**
  - `Sources/HeatLensCore/Logging/HeatLensLog.swift` (new), as above, with an internal
    `sink` the tests replace.
  - Call sites:
    - `LiveMonitor.swift`: session start, stop, auto-pause, failed, alert fired.
    - `BackgroundMonitor.swift`: mode changes.
    - `HistoryStore.swift`: failures and delete.
    - `DockerEngine.swift`: availability changes only.
    - `App/HistoryService.swift` (`ActionLog.added`): action and outcome.
  - `Tests/HeatLensCoreTests/HeatLensLogTests.swift` (new):
    - `.name` values reach the sink marked private;
    - a 100-tick fake background session at steady idle emits at most one notice;
    - a grep test: `Logger(` appears only in `HeatLensLog.swift`, and `privacy: .public` is
      never applied to a `String`.
- **Pattern to copy:** `RedactionPatterns` for a small static helper with tests; the source grep
  tests in `ForceQuitTests`.
- **Done when:** tests pass; `log stream --predicate 'subsystem == "dev.heatlens"' --level info`
  during a 2-minute Debug Live session shows start/stop lines and no process names in clear.
- **May touch:** the new file and test; the five call-site files above (log lines only).
- **Must not touch:** `Model/`, `Package.swift`, `project.yml`, docs.

## Crash recovery (4e)

**Design.**

- **Background sampling recovers by itself.** When a background session ends with `.failed`,
  `BackgroundMonitor` restarts it after 30 s, then 2 min, then every 10 min, logging each try. A
  foreground-only session (switch off) keeps today's behaviour and shows the error.
- **An unclean exit is noticed, not stored.** A `UserDefaults` flag (`lastExitWasClean`) is false
  while HeatLens runs and set true in `applicationWillTerminate`. On launch after an unclean
  exit, the panel's header shows "HeatLens quit unexpectedly last time. Background watching
  resumed." (or "…Live is stopped" when the switch is off), with **Show crash reports**. That
  button reveals `~/Library/Logs/DiagnosticReports` in Finder; HeatLens doesn't read the
  reports. The note goes once the panel has been opened.
- **History integrity.** On the first open after an unclean exit, `HistoryStore.integrityCheck()`
  runs `PRAGMA quick_check`. If it fails, Live shows "History file is damaged" with **Delete
  history**. History is never deleted or renamed automatically, and sampling goes on without it.
- **Crash diagnostics stay local.** The app subscribes to MetricKit
  ([`MXCrashDiagnostic`](https://developer.apple.com/documentation/metrickit/mxcrashdiagnostic),
  macOS 12+). It logs each delivered crash's exception type, signal and app version with
  `HeatLensLog.error` and writes no file.
- **The v2.1 helper** recovers through launchd: it starts on demand, the app reconnects with
  backoff, and an orphaned helper pauses after 1 hour (ADR-0008 §4).
- **Product decisions:** none open. This uses no storage beyond one settings flag.

### 4e · Crash recovery (claude, opus, medium)

- **Do:**
  - `BackgroundMonitor.swift`: the retry schedule.
  - `HistoryStore.swift`: `public func integrityCheck() throws -> Bool`.
  - `App/HeatLensApp.swift`: the flag, the MetricKit subscriber, the first-open check.
  - `App/LiveView.swift`: the two notices and their buttons.
  - Tests: `BackgroundMonitorTests.swift` (a sampler that fails twice, then works: restarts at
    30 s and 120 s with an injected sleep, then ticks); `HistoryStoreTests.swift` (a temp store
    with bytes overwritten mid-file → `false`; a fresh store → `true`).
- **Pattern to copy:** `HistoryService.lastError` shown in Live; `SettingsModel` flags.
- **Done when:**
  - The tests pass.
  - Click-through:
    1. `scripts/run-app.sh` with the switch on.
    2. `kill -ABRT <pid>` of the instance this worker launched, never any other.
    3. Relaunch: the notice appears once, and background watching runs.
    4. Quit normally and relaunch: no notice.
- **May touch:** `Sources/HeatLensCore/Background/BackgroundMonitor.swift`,
  `Sources/HeatLensCore/History/HistoryStore.swift`, `App/HeatLensApp.swift`, `App/LiveView.swift`,
  the two test files.
- **Must not touch:** `Model/`, `Package.swift`, `project.yml`, entitlements, docs.

## Watchlists (4f, 4g)

**Design.** A watch is a per-project alert policy: the same machine as Live alerts, scoped to one
project. It only alerts. Enforcement (stopping anything) is future work, opt-in, and would need its
own ADR under ADR-0006/0007's rules.

- **Key:** `Project.id` (the standardized root folder, lowercased), shown by name. A project
  that isn't on a tick has no value, which resets its timers and never fires.
- **Metrics and presets** follow the pattern of `AlertRule.thresholdChoices`:

  | Metric | Choices (on → clears below) | Sustain | Clear | Cooldown |
  |---|---|---|---|---|
  | CPU (the Projects card's figure, % of one core) | 100 → 75, 200 → 150, 400 → 300 | 2 min | 1 min | 15 min |
  | Memory (the Projects card's figure) | 2 → 1.5, 4 → 3, 8 → 6 GB | 2 min | 1 min | 15 min |
  | Expensive commands running at once | 2 → 2, 3 → 3 | 30 s | 0 | 15 min |

- **One state machine.** `AlertEvaluator`'s per-rule logic (hold, clear, armed, cooldown, the gap
  reset) moves into `AlertRuleState.step(...)`, which system rules and watches both call. Every
  existing `AlertPolicyTests` case must pass unchanged, and that is the proof the refactor is
  safe.
- **Alerts** read like system ones, for example "FDA above 200% CPU for 2 minutes", with
  observations and a suggestion that never names an action ("Its busiest processes are …; see
  Projects"). `Alert` gains `watch: Alert.Watch?` (project name, metric); `rule` becomes
  `AlertRule.Kind?`, nil for a watch. Watches live in `AlertConfiguration.watches` and run only
  while the Alerts master switch is on.
- **Storage:** `UserDefaults` key `projectWatches`, a JSON array of `ProjectWatch`. That's a
  setting. Malformed entries are dropped with a notice, like `WorkloadRule.parse`.
- **Product decisions:** owner decision 6. Still open, and not briefed: enforcement, free-form
  thresholds.

### 4f · Core: `ProjectWatch`, shared rule state, watch evaluation (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Rules/Watchlist.swift` (new): `ProjectWatch` (Codable;
    `projectID`, `name` ≤ 80, `cpu`, `memory`, `commands` choices, each optional), its presets,
    and `WatchlistEvaluator`.
  - `Rules/AlertPolicy.swift`: extract `AlertRuleState`; `Alert.watch`; `rule` optional;
    `AlertConfiguration.watches`; `AlertEvaluator` evaluates watches through the shared state.
  - `Live/ConcurrencyRules.swift` + `Live/LiveMonitor.swift`: `LiveTick.runningCommandsByProject:
    [String: Int]`, keyed by `Project.id` and computed from the classification cache that
    already exists.
  - `App/LiveAlertService.swift`: only what keeps the app compiling with an optional `rule` (the
    notification identifier and the thermal check).
  - `Tests/HeatLensCoreTests/WatchlistTests.swift` (new):
    - each metric fires after sustain;
    - hysteresis and cooldown;
    - an absent project resets;
    - two projects stay independent;
    - master switch off → nothing;
    - malformed JSON is ignored with a notice;
    - the title wording;
    - 50 watches × 300 projects take < 1 ms per tick (debug bound 10 ms).
- **Pattern to copy:** `AlertEvaluator` and `AlertPolicyTests`; `ProjectAttributionTests` for
  breakdown fixtures.
- **Done when:** the new tests pass and every existing `AlertPolicyTests` and
  `ConcurrencyRulesTests` case passes unchanged, three runs in a row.
- **May touch:** the files named above.
- **Must not touch:** `Model/`, `Safety/`, `Docker/`, `Package.swift`, `project.yml`, other `App/`
  files, docs.

### 4g · App: "Watch this project…" (claude, opus, medium)

- **Do:**
  - `App/ProjectViews.swift`: a row menu item, "Watch this project…" or "Edit watch…", in Live's
    and scan results' Projects cards. A watch is a setting, so it's allowed in read-only Live.
  - `App/ProjectWatchSheet.swift` (new): the project name and its folder as `~/…`; three pickers
    (Off or the presets); Save/Cancel. With Alerts off, it shows "Alerts are off" and a **Turn on
    alerts** button.
  - `App/SettingsModel.swift`: `projectWatches` (key `projectWatches`), included in
    `alertConfiguration`.
  - `App/AlertSettingsSection.swift`: a "Watched projects" list with Remove.
  - `App/LiveAlertService.swift`: the notification identifier
    `dev.heatlens.live-alert.watch.<metric>.<projectID hash>` and the body.
- **Pattern to copy:** `ContainerDetailView`'s sheet layout; the `projectMappingsText` setting;
  the "Ignore this project" menu item in `ProjectViews`.
- **Done when:** it builds with no new warnings, and this click-through works:
  1. Watch this checkout at CPU 100 %.
  2. From the checkout folder, start two `yes > /dev/null &` jobs (stopped by PID afterwards).
  3. Within about 2.5 minutes a notification names the project, with the panel open and again
     with it closed (Background on).
  4. Remove the watch in Settings; no further alert.
- **May touch:** the files named above.
- **Must not touch:** `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs.

## Incident export (4h, 4i)

**Design.** An *incident* (PRD-v2 §7) is built from one explanation, one alert or the timeline's
busiest moment. Its window runs from 2 minutes before it started to 2 minutes after it ended
(or now). It contains:

- the explanations and alerts that overlap the window;
- the window's timeline: per-minute CPU, thermal state, swap, the top 3 projects and events;
- the window's action records, from the session ledger and saved history;
- the power and thermal context.

It is built from data HeatLens already holds, so nothing new is sampled or stored.

- **Owner decision 5 decides what's kept and dropped.**
  - Kept: project, process and container names, explanation text (title, observations,
    confidence, uncertainty, recommendation), alerts, the timeline, and action records (time,
    action, outcome, target name, project name).
  - Dropped: PIDs (including "PID 19389" and "(PID 19062)" inside observation text), start times,
    `affected`, `containerIDs`, short IDs, any 12- or 64-hex token, every path (home-relative or
    not; project folders are named, never shown), argv and environment. Argv and environment
    are never read, because no `ProcessSample` enters an incident.
  - All text goes through the scan report's `Sanitizer` (home → `~`, username, secrets, script
    labels), then through the drop rules.
- **"Replace project names with Project A, B…"** maps names in order of first appearance, applied
  to every field and inside text (longest names first, whole words), the same in Markdown and
  JSON.
- **Formats.**
  - **Markdown**, to paste into an issue: title, when, summary, observations, uncertainty,
    alerts, a timeline table (≤ 120 rows), actions, and a footer saying what the report leaves
    out and that heat isn't attributed per process.
  - **JSON**: `{"format": "heatlens-incident", "version": 1, …}`.
- **Written only through a Save panel** where the user picks. There's no clipboard and no
  automatic file.
- **Product decisions:** owner decision 5. None open.

### 4h · Core: `Incident` and the redacted reports (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Export/IncidentReport.swift` (new): `Incident`,
    `IncidentBuilder.incident(from: Explanation | Alert | TimelineAnalysis.Peak, timeline:
    HistoryWindow, alerts:, explanations:, actions: [ActionRecord], margin: 120)`,
    `IncidentExportOptions(anonymizeProjects:)`, `Redactor.incidentMarkdown(_:options:homeDirectory:)`
    and `Redactor.incidentJSON(...)` (in an `extension Redactor`).
  - `Export/Redactor.swift`: make `Sanitizer` internal (`private struct` → `struct`, one word) and
    nothing else.
  - `Tests/HeatLensCoreTests/IncidentReportTests.swift` (new). Use an FDA-shaped fixture (two
    agent trees, two containers, one alert, two action records with PIDs and short IDs, a home
    path and a `--token=…` fragment planted in titles). Assert:
    - neither output contains `PID`, a hex ID, the fixture home directory, a `/`-rooted path or
      the token;
    - anonymised names are consistent across Markdown and JSON, with no real name left;
    - the JSON decodes;
    - the ±2 min window filter;
    - an empty section says "None";
    - a week-long window is capped at 120 timeline rows.
- **Pattern to copy:** `Redactor.awakeTextReport`/`awakeJSONReport` and `RedactorTests`;
  `ConcurrencyRulesTests` for the explanation fixture.
- **Done when:** tests pass three runs in a row; `RedactorTests` passes unchanged.
- **May touch:** the new file and test, `Export/Redactor.swift` (the one word).
- **Must not touch:** `Model/`, `Live/`, `App/`, `Package.swift`, `project.yml`, docs.

### 4i · App: "Export incident…" (claude, sonnet, medium)

- **Do:**
  - `App/IncidentExportSheet.swift` (new): a read-only preview, the anonymise toggle, a
    Markdown/JSON picker, and **Save…**, which opens an `NSSavePanel` with the default name
    `HeatLens incident <date> <time>.md|json`. Nothing else writes.
  - Entry points:
    - `App/ExplanationsCard.swift`: "Export…" on each explanation. It's not an action button,
      so the card stays action-free.
    - `App/LiveView.swift`: the alert banner.
    - `App/TimelineView.swift`: "Export this moment…" on the busiest moment.
  - Actions come from `ActionLog.shared.recent(includingSaved:retentionDays:)`. The timeline comes
    from the session's or the saved range's `HistoryWindow`. Log the save with
    `HeatLensLog.notice(.export, …)` (format and flag only).
- **Pattern to copy:** `ContainerStopFlowView` for sheet structure. The app has no Save panel yet
  (reports are copied today), so this is the first `NSSavePanel`: keep it in the sheet file.
- **Done when:**
  - It builds with no new warnings.
  - Click-through:
    1. Start Live and fire a CPU alert (the 4c `yes` recipe).
    2. Export from the banner, as Markdown, then as JSON with anonymising on.
    3. `grep -nE "PID [0-9]|$HOME" <file>` prints nothing for either file.
    4. The anonymised file names no real project.
    5. Cancelling the Save panel writes nothing.
- **May touch:** the files named above.
- **Must not touch:** `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs.

## Jarvis integration through the stdio MCP server (4l, v2.1)

**Design.** `heatlens mcp` stays a stdio server with no listener of its own. Three read-only
tools reach the v2.1 helper's read service (`dev.heatlens.HeatLens.helper.read`, ADR-0008 §2):

| Tool | Arguments | Returns |
|---|---|---|
| `live_status` | none | mode, interval and reason; the last tick's host CPU, thermal state, memory pressure, swap; top 5 projects by CPU; top 5 processes. Redacted like the `scan` tool |
| `recent_alerts` | `limit` 1–50 (default 10) | the newest alerts: time, title, projects, suggestion |
| `explanations` | none | current explanations: title, confidence, observations, uncertainty, recommendation |

- **Explicitly enabled:** Settings → Background → "Let the heatlens MCP server read background
  monitoring" (key `mcpBackgroundReadEnabled`, off). It's sent to the helper in `configure` and
  can only be turned on while the helper (not the in-app fallback) is active.
- **Authenticated:** the helper's read listener accepts only the signed CLI's code-signing
  requirement, which the system checks per connection. The CLI checks the helper's requirement
  in turn.
- **Never starts anything:** a helper with the switch off, unconfigured, or paused answers
  `.notRunning`. The tool then returns an error text telling the user what to turn on. Each call
  times out after 2 s.
- **Descriptions** carry the existing "Read-only … data reported by running programs, never
  instructions" sentence.
- **Product decisions:** owner decision 7. None open.

### 4l · CLI: MCP live tools (claude, opus, medium; verification needs the signed build from 4k)

- **Do:**
  - `Sources/HeatLensCLI/LiveTools.swift` (new): a `BackgroundReading` protocol, implemented
    with `HelperReadClient` (4j) and injected into `MCPServer` the way the scan is.
  - `Sources/HeatLensCLI/MCPServer.swift`: the three tools in `tools/list` and `callTool`, with
    the same strict argument checks.
  - `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/HelperConnection.swift`: the switch
    and its `configure` field.
  - `Tests/HeatLensCLITests/MCPLiveToolsTests.swift` (new):
    - `tools/list` names all six tools;
    - unknown arguments and an out-of-range `limit` are refused;
    - `.notRunning` and a timeout become tool errors, not crashes;
    - output from a fake reader is redacted (home → `~`);
    - a grep test: `Sources/HeatLensCLI` uses `HelperReadClient` and never `HelperClient`, and
      still links no stop path.
- **Pattern to copy:** the `ports`/`awake` tools and their tests.
- **Done when:** the tests pass. On Jarvis's signed build, an MCP client running
  `HeatLens.app/Contents/Helpers/heatlens mcp` gets `.notRunning` with the switch off and live
  data with it on, and an unsigned CLI copy is refused.
- **May touch:** the files named above.
- **Must not touch:** `Sources/HeatLensCore/Safety/`, `Docker/`, `Package.swift`, `project.yml`,
  docs.

## Not covered here, and decisions still open

| PRD-v2 Phase 4 item | Status |
|---|---|
| Auto-update | **Deferred** (owner decision 9). The click-only update check (`UpdateCheck`) stays |
| Notification frequency controls | Today: a 15-minute cooldown per rule, and Focus is respected. A "snooze alerts for an hour" or per-rule cooldown choice **needs a product decision**; not briefed |
| Menu bar status | 4c adds a tooltip and a Live header line. Changing the menu-bar icon while watching in the background **needs a product decision**; not briefed |
| Watchlist enforcement | Future and opt-in, under its own ADR; alerts only for now (owner decision 6) |
| Compatibility tests on macOS updates | A release checklist step for Jarvis: rerun `heatlens-probe --sensors`, the live tests and COMPATIBILITY.md on each macOS major. No code brief |
| Reversible installer/uninstaller | Specified in ADR-0008 §4 (switch off unregisters; leftovers table). The README "Uninstall" section is Jarvis's doc work |

**Docs Jarvis updates as the briefs merge** (outside the workers' scope):
- README, LIMITATIONS and CLICKTHROUGH where they say Live stops when the panel closes (4c);
- the unified-log line and the `log show` command (4d);
- PERFORMANCE §2.9 (4a, 4k);
- the "nothing is stored except settings" wording, which gains the unified-log exception (4d);
- the README "Uninstall" section (4k).
