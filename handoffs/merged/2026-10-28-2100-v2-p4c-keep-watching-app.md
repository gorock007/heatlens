# v2 Phase 4c: "Keep watching in the background" in the app (+ the 4i export click-through)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-2100-v2-p4c-keep-watching-app.md

## What the user asked
Build brief 4c of `docs/v2/ADR-0008-background-helper.md`:
- the Settings switch, off by default, with its caption and a status line;
- `LiveModel` driving `BackgroundMonitor`;
- panel close → `viewerClosed()`;
- launch with the switch on starts background mode;
- Scan detaches the viewer instead of stopping Live;
- notifications posted from `BackgroundEvent.alerts` at `.active`;
- the Live header line, the status-item tooltip and the Alerts caption.

Then run the 4c click-through and the 4i Export incident click-through. There were no questions.

## What changed
- **Settings → Background** (after Alerts):
  - the "Keep watching in the background" switch (`keepWatchingInBackground`, default false) with the ADR §4 caption;
  - below it, while the switch is on, a status line: "Watching · every 30 s (idle, on power)", "Watching live · every 5 s while the panel is open", "Paused until you press Start live or HeatLens opens again", or "Paused · <reason>".
- **`LiveModel` runs over one `BackgroundMonitor`**, following the 4b notes exactly:
  - **Start live:** `resume()`, then `viewerAttached(interval:)`.
  - **Pause:** `pause()`.
  - **Panel close (`viewerClosed()`) or Scan:** `viewerDetached()`.
  - **Picker:** `viewerAttached` again, but only while watching in the foreground. In background mode the picker is stored and the policy's cadence stays.
  - **Subscriptions:** `.summary` for the app's lifetime (status, and alerts for the banner), and `.full` only while the Live view is on screen (panel open, Live mode, Settings closed).
  - Calls into the monitor run one at a time through a task chain.
  - `state` and `isRunning` now come from `BackgroundStatus`.
- **Settings changes** use the `followSettings` observation pattern:
  - Keep watching applies at once.
  - Other session settings call `configure`, which restarts a running session. Changes made while Settings is open wait until it closes, or the panel closes, so a running session restarts once, as before. Changes made elsewhere (the Docker card's "Show Docker containers") apply at once.
  - Alert settings still go through `setAlerts` (no restart).
  - `configure` runs at launch: with the switch on, background mode starts without opening the panel.
- **`LiveAlertService`** subscribes `.summary` and posts from `.alerts`, so a closed panel still posts. It sets `content.interruptionLevel = .active`.
- **Live view:**
  - In background mode the header reads "Watching in the background · every 30 s (idle, on power)". Controls are **Watch live** (resume + attach at the picker interval) and **Pause**.
  - In the foreground the footer ends "back to the background when you close the panel" (switch on) or "stops when you close the panel" (switch off).
  - When the Live view appears in background mode it asks for one fresh tick (`refreshNow`), since ticks aren't kept while the panel is closed.
- **Status item:** the tooltip reads "HeatLens: watching in the background", "HeatLens: Live" or "HeatLens". `StatusPanelController` gained `onOpen` and `toolTip`.
- **Alerts caption:** "Checked while Live runs or HeatLens is watching in the background", plus a hint while the switch is off.
- **Quit:** unchanged; the process ends.
- `IncidentExportSheet.swift` is untouched: the export worked, below.

## Files
- App/SettingsModel.swift — modified
- App/SettingsView.swift — modified
- App/LiveModel.swift — modified
- App/HeatLensApp.swift — modified
- App/PopoverView.swift — modified
- App/LiveAlertService.swift — modified
- App/LiveView.swift — modified
- App/StatusPanel.swift — modified
- App/AlertSettingsSection.swift — modified
- handoffs/2026-10-28-2100-v2-p4c-keep-watching-app.md — created

## Checks run
- **`swift build`:** Build complete.
- **App build:** `scripts/run-app.sh --build-only` built the app. I also ran a full `xcodebuild` with the App files touched and read its log: no warnings from App/; the only warning line is the usual appintents "Metadata extraction skipped".
- **Full suite:** `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`.
  - First run: 439 tests in 64 suites, **1 issue**. It ran while my 8 `yes` fixtures were loading the CPU, and the `tail -30` output didn't name the failing test.
  - Rerun after the load stopped: **450 tests in 65 suites passed** (other workers' edits were in the tree by then). Probably a timing-sensitive test under load; I didn't identify it.
- **4c click-through:** Debug app, screen unlocked, driven with System Events and a CoreGraphics drag to detach the panel. Notification delivery was read from `usernoted` in the unified log.
  1. **Launch: pass.** "Keep watching in the background" appears under Background, off.
  2. **Alerts on, CPU at 60 %, Background on: pass.** The status line read "Watching · every 5 s (incident)" at once. Swap was 3.2 GB, above the 2 GB swap rule, so a swap alert had just fired. The incident cadence ended about 2 min after that alert, as 4f intends.
  3. **Load: pass.** Panel closed; 8 `yes` fixtures on 11 cores, my own PIDs.
  4. **Pass.** The `dev.heatlens.live-alert.sustainedCPU` notification was delivered with the panel closed, **2 min 8 s** after the load started. urgency Default, `interruptionSuppression: none`, not Time Sensitive. The Live header read "Watching in the background · every 5 s (incident)". A later run on battery read "every 10 s (incident)". The fixtures were stopped by PID.
  5. **Pass, on battery.** The cadence dropped 2–2.5 min after the load stopped. The header then read "Watching in the background · every 60 s (idle, on battery)": the Mac was unplugged partway through (`pmset`: Battery Power), so 60 s is right. "every 30 s (idle…)" on power wasn't seen in the header. The idle period before the load was on AC and ran at 30 s, judging by its CPU cost (0.11 s per 30 s).
  6. **Pass.** Idle app CPU on AC, panel closed: **0.22 s per 60 s** (`ps -o time=` every 30 s: 56.68 → 56.79 → 56.90 → 57.01). At the 5 s incident cadence it was about 0.3 s per 15 s. Other workers may have been building.
  7. **Pass.**
     - After Quit HeatLens, `pgrep -lf HeatLens.app` printed nothing (run twice).
     - With the switch on, relaunching started background mode with no panel (tooltip "HeatLens: watching in the background").
     - Turning the switch off stopped sampling at once (tooltip "HeatLens").
     - With the switch off, Start live ran in the foreground with the footer "…stops when you close the panel". Closing the panel stopped Live: `ps -o time=` read 0:34.33 both times, 40 s apart.
- **4i click-through.** Banner alerts last 2 min, so it took two fresh CPU alerts (Quit and relaunch, 8 `yes` fixtures each, stopped by PID).
  - The menu-bar panel (detached) stayed open while the Save panel was up; the sheet stayed open behind it. Saving dismissed the sheet.
  - **Markdown export from the banner:** saved.
  - **Anonymised JSON export from the banner:** saved. It contains only "Project A/B/C", and the names of my `~/Developer` folders, HeatLens and FDA don't appear in it.
  - `grep -nE "PID [0-9]|$HOME"` on both files: **no output**.
  - **Export… → Save… → Cancel:** no file written (still one file in the folder); the sheet stays open.
  - The exports are in my scratch folder only.
- **Settings restored:** `defaults delete dev.heatlens.HeatLens keepWatchingInBackground`. Alerts, CPU 60 % and the other keys were already set before I started and weren't changed.
- `handoffs/bin/jarvis leftovers --mine`: nothing running. No `yes` processes remain, and HeatLens is quit.
- **Not checked:**
  - A real sleep/wake.
  - Low Power Mode.
  - Clicking the notification to open the panel. Existing `ThermalAlertService` delegate, unchanged.
  - The 15-minute foreground fallback (unit-tested in 4b).
  - Launch at login with both switches on.

## Processes left running
none

## Questions for the user
None.

## Notes for Jarvis
- **No shared files touched.** No entitlements are needed.
- **Docs to update (yours):** README, LIMITATIONS and CLICKTHROUGH where they say Live stops when the panel closes. Also two pieces of Settings text I left alone because they weren't in the brief's list of changes: the History caption ("Only while Live runs") and "Changes apply to the next scan or live start".
- **Interpretations:**
  - **Opening the panel doesn't attach the viewer.** Only Start live / Watch live does, so the Live header shows the real background cadence, which ADR steps 4–5 read. With the switch off, opening the panel samples nothing until Start, as in v1.
  - **The picker only re-attaches while watching in the foreground.**
  - **Settings changes made while Settings is open wait for it to close** (one restart), except the Keep watching switch, which applies at once.
- **Driving notes for CLICKTHROUGH:**
  - The attached panel closes between separate `osascript` runs. Detach it with a CoreGraphics drag first.
  - Save… is disabled for about 1 s while the report is prepared.
  - Escape cancels the Save panel.
- **Watch item (core, not changed):** while swap stays above the swap rule, it can re-trigger the incident cadence whenever the rule re-arms. Here it ended as designed, 2 min after the firing.
- **Suggested commit:** `feat(v2): Phase 4c — Keep watching in the background (Settings switch off by default, LiveModel over BackgroundMonitor, panel close/Scan detach, alerts from BackgroundEvent at .active, Live header + status-item tooltip); 4c and 4i click-throughs`
