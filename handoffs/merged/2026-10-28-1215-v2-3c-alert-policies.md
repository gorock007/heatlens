# v2 Phase 3c: alert policies during Live (sustained CPU, memory, swap, thermal, containers)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1215-v2-3c-alert-policies.md
## What the user asked
Alerts checked only while Live runs: sustained CPU, memory, swap, thermal and running
containers, each with hysteresis and a cooldown. Each alert posts a notification, adds a timeline
marker and shows a Live banner. Everything is off by default. Ruling (2026-10-28): memory used =
100 − `availablePercent` (`kern.memorystatus_level`), with a one-line "Memory used: N%" row in
Live's overview.
## What changed
- **Core: `Sources/HeatLensCore/Rules/AlertPolicy.swift`**
  - **Types:**
    - `AlertRule`: kind, on/off, sustain, clear, cooldown, with the brief's defaults as documented constants.
    - `AlertConfiguration`: the master switch plus the rules. `.off` is the default.
    - `Alert`: id, rule, firedAt, title, observations as `Evidence`, up to 3 project names, suggestion.
    - `AlertEvaluator`: fed one `LiveTick` at a time.
  - **Firing:**
    - A rule fires once when its value has been ≥ *on* for `sustain`. Hold time is measured from
      the start of the first high tick to the end of the current one.
    - After firing, the rule is disarmed until the value has stayed < *off* for `clear`.
    - Even once re-armed, it can't fire again until `cooldown` has passed since the last firing.
  - **Gaps and missing data:**
    - A tick that doesn't start within 1 s of where the previous one ended resets the hold and
      clear timers. That covers a pause, a new session and Mac sleep.
    - A value that can't be read (thermal `.unavailable`, Docker off or unreachable, no
      `availablePercent`) also resets the timers and never fires.
  - **Values:**
    - CPU: `busyCores / coreCount`
    - memory: `1 − availablePercent/100`
    - swap: `swapUsedBytes`
    - thermal: rank (serious = 2)
    - containers: running count, only when Docker is available
  - **Threshold choices** (`AlertRule.thresholdChoices`), each *on* with its *off*:
    - CPU 60/80/90% → off 40/60/70%
    - memory 80/90/95% → off 70/80/85%
    - containers 4/6/10 → clears at 2/4/8 or fewer
    - swap 1/2/4 GB → off 0.5/1/2 GB. Swap clears at half rather than keeping a fixed gap,
      because "1 GB, off 0 GB" could never clear.
    - thermal: a single level, serious.
  - **Wording:**
    - Titles look like "CPU above 80% for 2 minutes", "Memory above 90% used for 2 minutes",
      "Swap above 2 GB for 1 minute", "Thermal pressure serious for 1 minute" and "6 or more
      containers running for 1 minute".
    - Observations are: value now, threshold ("80%; clears below 60%"), how long it held, and
      the busiest projects.
    - Projects come only from project rows, never the Docker VM or Unattributed. They're ranked
      by CPU (for CPU and thermal), memory (for memory and swap) or running containers. Names
      are sanitized: any `/` is reduced to the last component, and names are capped at 40 characters.
    - Each alert has one advice-only suggestion, e.g. "Open Live to see what's busy."
- **Wiring:**
  - `LiveConfiguration.alerts` (default `.off`) and `LiveTick.alerts`.
  - `LiveMonitor` sets `tick.alerts` right after the `ConcurrencyRules` call. Each alert's
    `.alertFired` event is added to `tick.events`, so it reaches the session timeline and history.
  - The evaluator is a property of the `LiveMonitor` actor, not local to `run()`, so the
    cooldown survives Pause → Start. It's in memory only.
  - `LiveMonitor.setAlerts(_:)` updates a running session's rules without resetting the timers.
- **History:** a new `TimelineEvent.Kind.alertFired` (not an inference, so it gets a solid
  marker). The schema is unchanged and `HistoryStore.swift` is untouched; a round-trip test was added.
- **Settings:** a new `App/AlertSettingsSection.swift`, inserted after the thermal-alert switch.
  - Master switch "Alert me while Live is running", off by default. Turning it on asks for
    notification permission, like the thermal switch does.
  - Once on, each rule has its own switch (all on) and an *on* picker, with "for N min ·
    clears below X" beside it. Thermal shows "serious or higher".
  - Caption: "Checked only while Live mode is running. HeatLens does nothing in the background.
    Live stops when the panel closes, so drag the panel off the menu bar to keep it open."
  - When the v1 thermal alert is also on, a note explains that the Live thermal rule only marks
    the timeline. A "Notifications are off" row appears if notifications have been denied.
  - Stored in `SettingsModel` as plain UserDefaults keys with `didSet`, like
    `thermalAlertsEnabled`: `liveAlertsEnabled`, `liveAlert.<kind>.enabled` and `liveAlert.<kind>.on`.
  - Changes reach a running Live session on its next tick.
- **Notifications: `App/LiveAlertService.swift`**
  - It observes `live.latest`. For each new alert id it posts one `UNNotificationRequest`, with
    id `dev.heatlens.live-alert.<rule>`.
  - Title = the alert title. Body = "FDA, shop · Open Live to see what's busy."
  - **No double alerts:** when `thermalAlertsEnabled` is on, the thermal rule posts nothing; its
    timeline event and banner still appear.
  - It has no timer of its own; it acts only on Live ticks.
  - Foreground banners and click-to-open come from `ThermalAlertService`, which is the app's
    notification delegate and is created at every launch. Its handlers don't check the
    notification id, so they cover Live alerts too, and that file is untouched. A click opens the
    panel, not specifically Live: opening on Live would need `PopoverView.swift`.
- **Live UI (`App/LiveView.swift`, current post-3a file):**
  - A small orange one-line banner under the "What's going on" card, shown while the newest tick
    has alerts: "🔔 CPU above 60% for 2 minutes", with "+N more" and a tooltip listing the suggestions.
  - A "Memory used N%" row in the overview, between Memory pressure and Swap. Its tooltip says
    the memory alert checks this number.
## Files
- Sources/HeatLensCore/Rules/AlertPolicy.swift — created
- Sources/HeatLensCore/Live/LiveMonitor.swift — modified
- Sources/HeatLensCore/History/HistoryModel.swift — modified (new `.alertFired` kind only)
- App/AlertSettingsSection.swift — created
- App/LiveAlertService.swift — created
- App/SettingsModel.swift — modified
- App/SettingsView.swift — modified (one inserted line)
- App/LiveView.swift — modified (banner + Memory used row)
- App/LiveModel.swift — modified (passes `alerts:`; `setAlerts(_:)`)
- App/HeatLensApp.swift — modified (starts `LiveAlertService`)
- Tests/HeatLensCoreTests/AlertPolicyTests.swift — created
- docs/v2/PLAN.md — modified (alert line ✅ + Did)
- handoffs/2026-10-28-1215-v2-3c-alert-policies.md — created
## Checks run
- `swift build`: Build complete.
- `scripts/with-timeout.sh 600 swift test --filter "AlertPolicy|ConcurrencyRules|Timeline|LiveMonitor"`: 62 tests in 8 suites passed.
- Full suite, `handoffs/bin/jarvis lock suite -- scripts/with-timeout.sh 600 swift test`: **323 tests in 55 suites passed**.
  - The first run had one failure: the `RedactorTests` "1,000 processes … under a second" timing
    test took 1.14 s while another worker's Redactor changes were uncommitted in the tree. It
    passed alone (0.52 s), and the full re-run after Jarvis committed `c294794` was all green.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- **`AlertPolicyTests` (16 tests, 24 cases):**
  - For each of the 5 rules:
    - below on → nothing; on for less than sustain → nothing
    - on for sustain → exactly one alert, firing at exactly `sustain`
    - staying high through a whole cooldown → no repeat
    - dipping between off and on → no clear and no repeat (thermal has no in-between band)
    - below off for clear, then high inside the cooldown → nothing; the tick a full cooldown
      later → the second alert
  - Master switch off → nothing; a single rule off → nothing for it, while the other rules fire.
  - Gaps: a tick gap resets holding. A gap resets clearing too, and the cooldown carries across it.
  - Missing data: thermal `.unavailable` never fires and breaks a hold. Containers with Docker
    unavailable → nothing.
  - Wording: exact titles and observations. No `/` and no home path in any title, observation,
    project or suggestion.
  - Plumbing: the `.alertFired` event matches its alert, and a history round trip works.
  - Threshold choices and their nearest-match lookup.
  - **`LiveMonitor` end to end:** off by default → no alerts. With a rule on → an alert on the
    expected tick and in its events and session timeline. Pause → Start on the same monitor →
    still inside the cooldown.
  - **Cost:** 200 ticks of 1,000 processes ran in 0.14 s including setup, so under 0.7 ms a
    tick (debug build). The limit is 2 ms.
- **Not checked:** I didn't launch the app, look at the Settings section or the banner, or receive
  a real notification. The user's step below covers that.
## Verification for the user
1. `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh`.
2. In the panel, open Settings → turn on **Alert me while Live is running** (allow notifications if
   macOS asks) → set **CPU** to **60%**. Leave Settings.
3. **Drag the panel off the menu bar** so it stays open: an attached panel closes when you
   click into Terminal, and closing it stops Live. Then go to Live → Start live. Check that the
   overview shows a "Memory used N%" row.
4. In Terminal, load every core: `for i in $(seq $(sysctl -n hw.ncpu)); do yes > /dev/null & done`.
   Wait 3 minutes, then run `killall yes`. Those are the `yes` processes you just started.
5. After about 2 minutes of load, expect:
   - one notification, "CPU above 60% for 2 minutes", whose body names the busiest projects (or
     just "Open Live to see what's busy.")
   - an orange one-line banner under the "What's going on" area, for one update
   - a solid marker with that title on the Timeline card
6. Within 15 minutes, there should be no second notification, even if you load the CPU again or
   pause and restart Live. Live auto-pauses after 15 minutes; restarting keeps the cooldown.
## Processes left running
none
## Notes for Jarvis
- **Shared files:** none. `Alert` lives in `Rules/AlertPolicy.swift`, not in `Model/`.
- **Naming hazard:** `HeatLensCore.Alert` clashes with SwiftUI's `Alert`. Any App file that
  imports SwiftUI and names the type must write `HeatLensCore.Alert`, as `LiveView.swift`'s
  banner does. I kept the brief's name. Renaming it to `LiveAlert` would be a mechanical
  follow-up if you prefer.
- **Implicit dependency:** `LiveAlertService` relies on `ThermalAlertService` being the
  notification delegate, which handles any notification id. If the delegate ever moves or starts
  checking ids, Live alerts lose their foreground banners and click-to-open. There's a comment at
  both the `LiveAlertService` header and the `HeatLensApp` call site.
- **Phase numbering:** PLAN.md calls this item "3b", while the brief calls it 3c. I marked the
  alert line done and left the numbering alone, as 3b did.
- **`handoffs/OPEN.md`** shows as modified in the tree; that's Jarvis's edit, not mine.
- Suggested commit: `feat(v2): Phase 3c — Live alert policies (CPU, memory, swap, thermal, containers) with hysteresis and cooldown`
