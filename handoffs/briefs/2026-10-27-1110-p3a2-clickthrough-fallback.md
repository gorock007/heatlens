# Phase 3a (retry): computer-use click-through of the menu-bar app (PRD §9 scenarios 6, 8, 9, 11 + the UI flows)
worker: codex
model: gpt-6-astra
effort: high
started: 2026-10-27 11:08 · terminal: 5ab29ed7-9304-4c1a-90a4-1ecdfccd8e7a

## Goal
Drive the real HeatLens menu-bar app on this Mac with computer use, then record what you saw. Done means `docs/CLICKTHROUGH.md` exists with one row per step below (pass / fail / couldn't do, plus a one-line observation). `docs/SCENARIOS.md` rows 6, 8, 9 and 11 are updated to cite it. No source code changes.

## Context
- Build and launch: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh`. The app is a thermometer icon in the menu bar.
- Click steps and the exact button labels come from `handoffs/merged/2026-10-26-1816-p2b-detail-stop-settings-ui.md` ("User verification", steps 1–5). Scenario wording comes from `docs/SCENARIOS.md`. The idle-measurement commands are in `docs/PERFORMANCE.md` section 1.
- The repo is **public**. Screenshots and anything else showing real process names, paths, usernames or argv from this Mac stay in your scratch folder and are never committed. `docs/CLICKTHROUGH.md` describes outcomes generically (for example "a root-owned process showed Not accessible"), with no real paths or command lines.

## Driving the UI (read first)
The first attempt (`handoffs/merged/2026-10-27-1104-p3a-clickthrough.md`) stopped because `cua.getApp()` timed out three times on HeatLens. It's a menu-bar-only `LSUIElement` app with no windows. **Permissions are fine.** Jarvis checked from this same host: System Events can see `menu bar item 1 of menu bar 2 of process "HeatLens"`, and `screencapture -x` captures the real screen.
- Try `getApp` at most once. Then use:
  - `osascript` System Events: `click menu bar item 1 of menu bar 2 of process "HeatLens"`, then query `UI elements` and `windows` of the process for the popover's buttons
  - `click at {x, y}` for coordinates
  - `screencapture -x <scratch>/s.png` to see the screen
- Jarvis's AXPress on the status item did not make the popover show up under `windows of process "HeatLens"`. If that happens, try a coordinate click on the status icon instead. It is the leftmost status icon, near the top right of the menu bar, so find it in a screenshot.
- If after about 15 minutes you still can't open the popover, write a `status: blocked` handoff saying what you tried, and stop.
- The user may be using this Mac at the same time. Keep coordinate clicks to the HeatLens popover and its sheets.

## Steps (in this order)
1. Launch the app. Click the thermometer, then **Scan now**, and wait for the results.
2. **Results layout:** check for at most 12 group rows, the `N idle groups` note, **Show all N groups**, then **Show fewer groups**.
3. **Detail:** expand a group, then open one member. Check for PID, parent chain, owner, uptime, executable, command, directory, CPU/memory, project basis and confidence, and evidence. Click **Copy PID**, then **Back**.
4. **Scenario 6:** open a root-owned or other restricted process. Record the "Not accessible"/unavailable wording.
5. **Scenario 11:** open `WindowServer` or `launchd` (or any Apple-path or denylisted process). Confirm **Request stop** is absent.
6. **Safe stop sheet:** on an eligible Potential leftovers card (if there is one), click **Request stop**. Check that the sheet shows PID, command, project, impact and the interruption warning, then click **Cancel**. **Never click Send SIGTERM. Never send any signal to any process except HeatLens itself.**
7. **Settings:** click the gear. Check that **10 s** is selected, then choose **5 s**, click **Done**, then **Scan now**. Progress should end at 5 s. Restore **10 s**. Add one excluded process name, check the `hidden by your exclusions` note, then remove it. Read the launch-at-login status, but **don't toggle it**.
8. **Scenario 8:** after a finished scan, leave the app idle. Run `ps -p <pid> -o %cpu=,rss=,time=` twice, 30 s apart. CPU time must not grow (beyond rounding).
9. **Scenario 9:** start **Scan now**, and during the scan click **Quit HeatLens** (or press ⌘Q). Then `pgrep -fl "HeatLens|/bin/ps|pmset"` must print nothing related to HeatLens. Record the exact output, with any path or argument from other apps reduced to the process name.
10. When you finish, the app is quit, settings are back to 10 s, and no exclusions are left.

## Scope
- May touch: `docs/CLICKTHROUGH.md` (create), `docs/SCENARIOS.md` (rows 6, 8, 9, 11 and the Gaps list only)
- Must not touch: `Sources/`, `App/`, `Tests/`, `Package.swift`, `project.yml`, any other doc, the login item, any process other than the HeatLens you launched
- If a step **fails**, record the failure with what you saw. Don't fix code. Jarvis writes the fix brief.

## Checks
- `pgrep -fl HeatLens` prints nothing at the end.
- `git diff --stat` touches only the two docs.
- `grep -nE "/Users/|gorock" docs/CLICKTHROUGH.md docs/SCENARIOS.md` prints nothing.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
