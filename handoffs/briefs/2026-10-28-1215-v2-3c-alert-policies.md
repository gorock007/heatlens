# v2 Phase 3c: alert policies during Live (sustained CPU, memory, swap, thermal, containers) with hysteresis and cooldown
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 11:34 · terminal: db70ad87-b049-4ac9-8c8e-e73522634b16

## Goal
PRD-v2 Phase 3: "Configurable sustained CPU, thermal pressure, swap, memory and container concurrency alerts with cooldown/hysteresis to avoid alert spam." Alerts are evaluated **only while Live mode runs**. Background sampling is Phase 4: say so in Settings, and don't add any timer or sampling of your own.

**Done when** `swift build`, the targeted and the full `swift test`, and `scripts/run-app.sh --build-only` pass; `AlertPolicyTests` cover every rule's fire → hold → clear → cooldown path; and in the built app, with Alerts on and a low CPU threshold, Live posts one notification and a timeline marker, then stays quiet through the cooldown.

1. **Core (pure, tested).** A new `Sources/HeatLensCore/Rules/AlertPolicy.swift`:
   - `AlertRule` kinds: `.sustainedCPU`, `.memory`, `.swap`, `.thermal`, `.containers`.
   - Each rule has an *on* threshold, a lower *off* threshold (hysteresis), how long it must hold before firing (`sustain`) and before clearing (`clear`), and a per-rule `cooldown`.
   - `AlertEvaluator`, fed one `LiveTick` at a time like `TimelineDetector` (`Sources/HeatLensCore/Live/TimelineDetector.swift`), returns the alerts that fired on this tick. A rule fires once when its value has stayed at or above *on* for `sustain`. It can't fire again until the value has stayed below *off* for `clear` **and** the cooldown has passed since the last firing. A gap in ticks (the Live pause) resets the "holding" timers; it never fires on stale data.
   - Values:
     - CPU: `SystemSample.busyCores / coreCount`
     - memory used: the same "used" figure Live's overview shows, as a fraction
     - swap: `swapUsedBytes`
     - thermal: `ThermalState` ≥ `.serious`; `.unavailable` never fires
     - containers: running containers, only when Docker is available
   - Defaults:

     | Rule | On | Off | Sustain | Clear |
     |---|---|---|---|---|
     | CPU | ≥ 80% | < 60% | 2 min | 1 min |
     | Memory | ≥ 90% | < 80% | 2 min | 1 min |
     | Swap | ≥ 2 GB | < 1 GB | 1 min | — |
     | Thermal | serious+ | below serious | 1 min | — |
     | Containers | ≥ 6 running | ≤ 4 | 1 min | — |

     Cooldown is 15 min per rule. Put them as documented constants on the type.
   - Each `Alert` carries:
     - rule and fired-at
     - title, e.g. "CPU above 80% for 2 minutes"
     - observations: the value now, the threshold, how long it held, and the top 1–3 projects from `tick.projects` (names only, never paths or argv)
     - one non-destructive suggestion, e.g. "Open Live to see what's busy"
   - Each fired alert also adds a `TimelineEvent` of a new kind `.alertFired`. Do it the way `.concurrencyExplained` was added (`handoffs/merged/2026-10-28-1128-v2-3b-concurrency-explanations.md`); the history schema is unchanged.
2. **Wiring.** `LiveTick.alerts: [Alert]` (fired this tick), set in `LiveMonitor` next to the `ConcurrencyRules` call. The evaluator gets its rule configuration from `LiveConfiguration` (add an `alerts` field there, default all off), so the app passes in the user's settings.
3. **Settings.** An **Alerts** section in a new `App/AlertSettingsSection.swift`, inserted into `App/SettingsView.swift` with one line next to the existing thermal-alert switch:
   - a master switch "Alert me while Live is running" (**off by default**), and one switch per rule (all on once the master is on)
   - a small picker per rule for the *on* threshold, with 3–4 choices, e.g. CPU 60/80/90%, memory 80/90/95%, swap 1/2/4 GB, containers 4/6/10. The *off* threshold follows from it, keeping the same gap.
   - a caption: "Checked only while Live mode is running. HeatLens does nothing in the background."

   Store the settings in `App/SettingsModel.swift` the same way `thermalAlertsEnabled` is stored.
4. **Notifications.** A new `App/LiveAlertService.swift` posts one `UNUserNotification` per fired alert, following `App/ThermalAlertService.swift` (permission request, foreground presentation, click opens the panel; open it on Live if that's simple, otherwise just open the panel).
   - Notification text: title = the alert title; body = the top projects and the suggestion.
   - **No double alerts:** when the existing opt-in thermal alert (`thermalAlertsEnabled`, v1 10a) is on, the Live thermal rule records its timeline event but doesn't post a notification.
   - In Live, a fired alert also shows as a one-line banner at the top of `LiveView` until the next tick that has none. Keep it small, and put it under the explanations card.
5. **Tests** in `Tests/HeatLensCoreTests/AlertPolicyTests.swift`. Build ticks from `Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift`, as `ConcurrencyRulesTests.swift` does. Cover:
   - for each rule: below on → nothing; on for less than `sustain` → nothing; on for `sustain` → exactly one alert; staying high → no repeat; dipping between *off* and *on* → no clear and no repeat; below *off* for `clear` then high again inside the cooldown → nothing; after the cooldown → a second alert
   - the master switch off → nothing; a single rule off → nothing for it
   - a tick gap resets holding
   - thermal `.unavailable` never fires
   - containers when Docker is unavailable → nothing
   - titles and observations contain no `/` paths
   - cost: 1,000 processes under 2 ms per tick

## Context
- Read first: `Sources/HeatLensCore/Live/ConcurrencyRules.swift` and `Sources/HeatLensCore/Live/TimelineDetector.swift` (patterns), `Sources/HeatLensCore/Live/LiveMonitor.swift` (where ticks are built; `LiveConfiguration`), `Sources/HeatLensCore/Rules/ThermalAlertPolicy.swift`, `App/ThermalAlertService.swift`, `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/LiveView.swift`, `App/LiveModel.swift`.
- Rulings:
  - New behaviour defaults to off (`docs/v2/PLAN.md`).
  - Explain only, no actions. Alerts never stop or change anything.
  - No new dependency.
  - Names only, never paths or argv, in notifications.
- `docs/v2/PLAN.md` lists this as an item of Phase 3. Mark it ✅ with one "Did" line when done.

## Scope
- May touch: `Sources/HeatLensCore/Rules/AlertPolicy.swift` (new), `Sources/HeatLensCore/Live/LiveMonitor.swift` (wiring, `LiveConfiguration`), `Sources/HeatLensCore/History/HistoryModel.swift` (the new event kind only), `App/AlertSettingsSection.swift` (new), `App/LiveAlertService.swift` (new), `App/SettingsModel.swift`, `App/SettingsView.swift` (one inserted line), `App/LiveView.swift` (the banner), `App/LiveModel.swift` (passing the alert config), `App/HeatLensApp.swift` (only to start `LiveAlertService`), `Tests/HeatLensCoreTests/AlertPolicyTests.swift` (new), `docs/v2/PLAN.md`
- Shared files (edit minimally, name in handoff): an `Alert` type, if you put it in `Sources/HeatLensCore/Model/` (new file)
- Must not touch: `Sources/HeatLensCore/Safety/`, `Sources/HeatLensCore/Docker/`, `Sources/HeatLensCore/History/HistoryStore.swift`, `Sources/HeatLensCore/Live/ConcurrencyRules.swift`, `App/ThermalAlertService.swift` (read it, don't change it), `Package.swift`, `project.yml`, `App/Info.plist`, `App/*.entitlements`

## Phase
This phase only: alert policies in Live. Safe actions (3d) and the audit trail (3e) are later briefs.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
scripts/with-timeout.sh 600 swift test --filter "AlertPolicy|ConcurrencyRules|Timeline|LiveMonitor" 2>&1 | tail -30
scripts/with-timeout.sh 600 swift test 2>&1 | tail -15
scripts/run-app.sh --build-only 2>&1 | tail -20
```
In the handoff, give the user a verification step: Settings → Alerts on, CPU threshold 60%. Live → Start, then load the CPU with `yes > /dev/null & yes > /dev/null & …` (one per core) for 3 minutes, then `killall yes`. Expect one notification, a timeline marker and the banner, and no second notification within 15 minutes.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
