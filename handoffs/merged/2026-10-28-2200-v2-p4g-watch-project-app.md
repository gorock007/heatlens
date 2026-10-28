# v2 Phase 4g: "Watch this project…" in the app
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-2200-v2-p4g-watch-project-app.md

## What the user asked
Build 4g from `docs/v2/PHASE-4-PLAN.md`:
- a "Watch this project…" / "Edit watch…" item on rows in Live's and scan results' Projects cards;
- `App/ProjectWatchSheet.swift`;
- `projectWatches` in `SettingsModel`, included in `alertConfiguration`;
- a "Watched projects" list with Remove in Alerts settings;
- the watch notification's identifier and body.

Then run the click-through.

I asked one scope question first: may I make a one-line edit to `App/LiveView.swift`? Jarvis said
yes, and approved my listed defaults.

## What changed
- **Project rows** (`ProjectsCard`), in Live and in scan results:
  - A small **"Watch this project…"** button inside the opened row. It reads **"Edit watch…"** once
    the project is watched.
  - Projects only: the Docker VM and Unattributed rows don't get it.
  - It sits beside "Ignore this project", which stays scan-results only.
  - New `ProjectsCard` parameter `watchSettings:` offers only the watch. Live passes it
    (`App/LiveView.swift:50`, the one approved line). Scan results already pass `settings:`, which
    now offers both buttons.
- **`ProjectWatchSheet`** (new), opened with `.sheet` from the row:
  - the project name, and its folder as `~/…`;
  - three pickers, CPU above / Memory above / Expensive commands at once, each Off or one of
    `ProjectWatch.choices`, labelled with `describe`;
  - a caption: "Alerts only… CPU and memory must hold for 2 minutes, commands for 30 seconds";
  - with Alerts off, "Alerts are off" and a **Turn on alerts** button (`setLiveAlerts(true)`);
  - **Cancel** (Escape) and **Save** (Return).
  - Save with every picker Off removes the watch, so it doubles as "remove". It's disabled for a new
    watch with everything Off.
  - Past 50 watches, Save shows an error and keeps the sheet open.
  - Width is 300 pt, the panel's own width.
- **`SettingsModel`:**
  - `projectWatches`, key `projectWatches`, read with `ProjectWatch.parse` and written with
    `ProjectWatch.encoded`;
  - `projectWatchesNotice`, the parse notice, cleared on the next change;
  - `watch(for:)`, `setWatch(_:)` and `removeWatch(projectID:)`;
  - `alertConfiguration` now passes `watches:`, so changes reach the running session through the
    existing `setAlerts` path, with no restart.
- **Alerts settings:** while Alerts is on, a "Watched projects" list under the rules.
  - Each row shows the name, a summary ("CPU above 200% · Memory above 4 GB · 2 or more commands at
    once") and **Remove**.
  - Empty, it reads "None. Open a project in Live or a scan result and choose “Watch this
    project…”."
  - The parse notice shows in orange.
- **`LiveAlertService`:**
  - The identifier for a watch alert is `dev.heatlens.live-alert.watch.<metric>.<projectHash>`;
    system rules are unchanged.
  - The body for a watch alert is the first two observations, then the suggestion, e.g. "CPU now:
    210% of one core · Threshold: 100%; clears below 75% · Its busiest processes are yes; see
    Projects."
  - The title already names the project. Names and figures only, never a path.
  - Rule alerts keep their old body.

## Files
- App/ProjectWatchSheet.swift — created
- App/ProjectViews.swift — modified
- App/SettingsModel.swift — modified
- App/AlertSettingsSection.swift — modified
- App/LiveAlertService.swift — modified
- App/LiveView.swift — modified (one line, approved)
- handoffs/2026-10-28-2200-v2-p4g-watch-project-app.md — created

## Checks run
- **`swift build`:** Build complete.
- **App build:** `scripts/run-app.sh --build-only` built the app, again after the final sheet-width
  edit.
- **Warnings:** I ran a full `xcodebuild` into a scratch derived-data folder and read its log. There
  are no warnings from App/. The only warnings are an existing deprecation in
  `Sources/HeatLensCore/Sampling/PortSampling.swift:138` and the usual appintents "Metadata
  extraction skipped".
- **Full suite:** `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift
  test`: **454 tests in 66 suites passed.** It ran before the last edit, which only changes the
  sheet's width; no test covers App/.
- **Click-through:** Debug app, screen unlocked, Alerts already on, driven with System Events and a
  CoreGraphics drag to detach the panel. Delivery was read from `usernoted` in the unified log.
  `pgrep -x HeatLens` showed no other worker's app before each launch.
  1. **Watch this checkout at CPU 100 %: pass.**
     - Live → opened this checkout's row → **Watch this project…**.
     - The sheet showed the name, `~/…` folder and three pickers set to Off. I chose 100 % and
       pressed Save.
     - The setting held one watch, `cpu: 100`. The row then read "Edit watch…".
  2. **Load: pass.** Two `yes > /dev/null &` jobs from the checkout folder, my own PIDs, each at
     100 % CPU.
  3. **Notifications: pass, both ways.**
     - **Panel open, Live at 5 s:** `dev.heatlens.live-alert.watch.cpu.<hash>` was delivered
       **2 min 0 s** after Start live. The banner read "<checkout> above 100% CPU for 2 minutes".
     - **Panel closed, Background on:** I turned Background on in Settings, quit, and relaunched.
       There was no panel; the tooltip read "HeatLens: watching in the background". The same
       identifier was delivered **2 min 8 s** after launch.
     - **Interrupted first attempt:** my first app instance received SIGTERM 34 s into the load,
       before any alert. runningboard: "termination reported by launchd (2, 15, 15)". It wasn't
       from my session (my commands only ran `osascript`/`log` then). Another worker's tooling may
       have sent it. I rebuilt, relaunched and repeated; the passes above are from the repeat.
  4. **Remove → no further alert: pass.**
     - To keep the 15-minute cooldown from hiding a repeat, I relaunched for fresh alert state.
       22 s after launch I pressed **Remove** in Settings → Watched projects. The setting became
       `[]` and the list read "None…".
     - With the two `yes` jobs still at 100 % for **4 min** afterwards, no watch notification was
       delivered. A system `live-alert.swap` was delivered in that window, so sampling was running.
- **Sheet layout:** a screenshot after the width fix shows it fits the panel, the folder
  middle-truncated as `~/…`, and Save disabled while every picker is Off.
- **Cleanup:**
  - `yes` jobs stopped by PID.
  - My HeatLens quit by its PID.
  - `defaults delete` of `keepWatchingInBackground` and `projectWatches`, the only keys I added.
    Alerts was on before I started and wasn't changed.
  - `handoffs/bin/jarvis leftovers --mine`: nothing running.
  - Screenshots are in scratch only.
- **Not checked:**
  - "Alerts are off" + **Turn on alerts** in the sheet: Alerts was already on, and I didn't change
    it.
  - The sheet from a **scan result's** Projects card. Same `ProjectRow` code path, with
    `watchSettings` defaulting to `settings`.
  - Memory and commands watches end to end. Their pickers list the presets.
  - "Edit watch…" changing an existing watch's values. I did see Save replace a watch, and Remove.
  - The parse notice with a malformed setting.
  - Escape closing the sheet. My key event went to the frontmost app, not the panel.

## Processes left running
none

## Questions for the user
None.

## Notes for Jarvis
- **Shared file:** `App/LiveView.swift`, one line, as approved: `watchSettings: model.settings` in
  the `ProjectsCard` call.
- **Unexplained SIGTERM:** something outside my session sent SIGTERM to my Debug HeatLens at
  15:28:22. Worth asking the other worker whether its click-through or cleanup quits HeatLens by
  name.
- **For CLICKTHROUGH (driving notes):**
  - In zsh, `log` is a builtin. Use `/usr/bin/log show`.
  - The Live tree changes under accessibility reads, so index-based presses miss. Find and press by
    name in one `osascript` run.
- **Suggested commit:** `feat(v2): Phase 4g — "Watch this project…" (row button in Live and scan
  Projects cards, ProjectWatchSheet with preset pickers and Turn on alerts, projectWatches setting
  in alertConfiguration, Watched projects list with Remove, watch notification id/body); 4g
  click-through passes`
