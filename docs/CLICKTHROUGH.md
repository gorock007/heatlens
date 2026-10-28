# Menu-bar app clickthrough

Observed on 2026-10-27 on the development Mac, using the Debug app built and
launched with:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh
```

These are manual UI observations, not automated regression tests. System Events
provided the accessibility tree; physical mouse events opened the status popover
when its accessibility press did not. Screenshots and raw accessibility/process
output remain in ignored local scratch storage and are not part of this report.

| Step | Check | Result | Observation |
|---|---|---|---|
| 1 | Launch, thermometer, Scan now, results | pass | The popover opened; clicking Scan now showed progress through 10 seconds and then populated results. |
| 2 | Group limit, idle note, show all/fewer | pass | The first completed scan had 12 collapsed group rows, “30 idle groups” and “Show all 58 groups”; expansion exposed 58 rows and “Show fewer groups” restored 12. |
| 3 | Group member detail, fields, Copy PID, Back | pass | Expanded a group and opened its member; PID, parent chain, owner, uptime, executable, command/directory availability and CPU/memory were present; Copy PID matched, and Back returned to results. A project worker's detail additionally showed “From cwd · High confidence” plus finding evidence and limitations. |
| 4 | Scenario 6: restricted process | pass | A process owned by another user showed “Not accessible” for Command and Directory, “via ps” for CPU/memory, and “Unknown project.” |
| 5 | Scenario 11: protected process controls | pass | The restricted Apple system process's full detail showed Copy PID, disabled Copy command and Activity Monitor; Request stop was absent. |
| 6 | Eligible leftover stop sheet, then Cancel | pass | Request stop opened a sheet containing PID, command, project, impact and the interruption warning; clicking Cancel removed the sheet. Send SIGTERM was never clicked. |
| 7 | Settings, 5-second scan, exclusions, login status | pass | Initially 10 s was selected and both exclusion lists were empty; 5 s produced progress ending at “5 of 5 seconds” and a “5-second sample”; 10 s was restored. Adding one exact process-name exclusion showed “1 finding hidden by your exclusions”; removing it cleared the note. Launch at login was unchecked and reported “Unavailable for this build”; it was not toggled. |
| 8 | Scenario 8: idle after a finished scan | pass | With the popover dismissed after a completed scan, two samples 30 seconds apart both reported 0.0% CPU and unchanged CPU time of 0:21.05; measurements below. |
| 9 | Scenario 9: quit during scan | pass | Clicked Quit HeatLens while progress read “6 of 10 seconds”; the app exited. No app or scan helper remained; the initial broad match contained only the computer-use runtime, which was then reset. |
| 10 | Cleanup | pass | Before quitting, settings read 10 s with both exclusion fields empty; after computer-use cleanup, both required pgrep commands produced no output. |

## Panel (Phase 6a)

Observed on 2026-10-27 with the Debug build. The status item was opened with a
System Events press on the app's menu-bar item (a menu-bar manager covered the
icon, so no physical click on it); everything else used CoreGraphics mouse and
key events. Sheet and copy checks used a local build wired to the fixture scan
and fixture stopper, which never signals.

| Step | Check | Result |
|---|---|---|
| P1 | Click the thermometer: the panel opens directly under it; click it again: the panel closes | pass |
| P2 | Drag the "HeatLens" title, or any empty part of the panel, to another spot | pass, moves anywhere, including the second display |
| P3 | Click another app: an unmoved panel closes, a moved one stays open and floats | pass |
| P4 | Escape closes the panel, moved or not; with the stop sheet up, Escape closes only the sheet | pass |
| P5 | After a close, the next open is under the icon and closes on a click elsewhere again | pass |
| P6 | Copy command / Copy PID show "Copied…", then revert about 2 seconds later | pass |
| P7 | Idle with the panel closed: `ps -p <pid> -o %cpu=,time=` 30 s apart | 0.0%, CPU time unchanged |

Dragging starts on the title and on empty background; other text and the
scrolling results take the press as before. Escape in the scanning view closes
the panel and leaves the scan running (reopen to see it); Cancel still stops it.

## Idle measurements

Command: `ps -p <launched-app-pid> -o %cpu=,rss=,time=`. Taken after the
5-second scan completed and the settings/exclusion checks were finished, with
the popover closed. The configured duration had already been restored to 10 s.

| Local time | %CPU | RSS (KB) | CPU time |
|---|---|---|---|
| 11:15:31 | 0.0 | 92,368 | 0:21.05 |
| 11:16:01 | 0.0 | 55,760 | 0:21.05 |

This establishes no CPU-time growth at the displayed resolution during this
30-second interval; it does not prove the absence of every possible wakeup.

## Quit and cleanup output

Immediately after the UI quit, `pgrep -fl "HeatLens|/bin/ps|pmset"` returned
the following, with unrelated paths and arguments reduced to process names:

```text
2705 node
2706 node
```

Both were this task's computer-use runtime, matching the repository name in
their working-directory arguments. The launched app PID was gone and
`pgrep -x HeatLens` returned no output. Resetting the computer-use runtime
removed both remaining matches. The final exact stdout for each command was
empty (exit status 1):

```sh
pgrep -fl "HeatLens|/bin/ps|pmset"
pgrep -fl HeatLens
```

## Limits and repeat verification

The native `getApp` call timed out once; the fallback completed the checks.
The popover occasionally closed between operations and was reopened before
continuing. Counts and resource measurements varied between scans.

No stop signal was requested through the app, no launch-at-login change was
made, and no source code was changed. Activity Monitor comparison, a successful
termination outcome, and launch-at-login registration were not tested here.

To repeat, run the launch command above, click the thermometer and **Scan now**,
compare sampled resource usage with Activity Monitor, and follow the ten rows.
Cancel the stop sheet, leave launch at login unchanged, restore 10 s and empty
exclusions, then quit during a scan and repeat the process checks.

## Live mode, hardware sensors, Docker (PRD-v2 Phase 1f)

Observed on 2026-10-27 with the Debug build (`scripts/run-app.sh`), on the M3 Pro, macOS
27.0.1, with Docker Desktop 28.5.1 running one container. The status item was opened with a
System Events press. The panel was detached with a CoreGraphics drag on its title, so it stays
open while it's driven. Buttons and switches were pressed with System Events accessibility
actions. Settings were restored afterwards with `defaults delete` of the two new keys.

| Step | Check | Result |
|---|---|---|
| L1 | Scan mode looks as before, with a Scan / Live switch above it | pass |
| L2 | Live before Start: explanation text, Start live, 2/5/10 s picker; app 0.0% CPU | pass |
| L3 | Start live: first update in about 1 s; overview (public badge), CPU-load sparkline, Top CPU and Top memory with sparklines; hardware and Docker cards say "Off" | pass (≈92 ms to collect) |
| L4 | App cost while live at 5 s: `ps -o time=` 30 s apart | 0.59 s CPU in 30 s, about 2.0% of one core (Debug build, includes SwiftUI) |
| L5 | Settings: "Hardware sensors (private macOS interfaces)" and "Docker containers" toggle and persist | pass |
| L6 | Live with both on: CPU 66 °C avg / 87 °C hottest, GPU 57/61 °C, two fans ≈2300/2500 RPM, system power 19.2 W, CPU/GPU power "Unavailable (needs per-macOS power tables)", orange "SMC · private interface" badge; Docker card lists `fda-db-1` with Compose project, memory and the VM note | pass |
| L7 | Live notices: root processes not sampled in live mode, processes exited since the last update | pass |
| L8 | Closing the panel stops Live: `ps -o time=` 30 s apart after close | 0:03.26 both times |
| L9 | Scan now with sensors on: results show the Hardware sensors card under Overview | pass |
| L10 | Quit HeatLens exits; no process left | pass |

Brief 1h, same method, Debug build, on battery, with no sensor or Docker key stored (a fresh
install):

| Step | Check | Result |
|---|---|---|
| L11 | Idle Live text names energy and sensors; Docker "if you turn it on" | pass |
| L12 | Sensors on by default: the hardware card shows CPU 51 °C avg / 64 °C hottest, fans, system power 6.6 W, with no setting stored | pass |
| L13 | Overview "CPU energy 0.8 W · your processes"; each Top CPU row shows watts under its CPU figure (`0.1 W`, `<0.1 W`) | pass |
| L14 | Docker card "Off" with "Show Docker containers": pressing it stores `dockerEnabled = 1`, restarts Live, and lists `fda-db-1` | pass |
| L15 | Scan now: group rows read "40% CPU (of one core) · 0.1 W · 28 processes" | pass |

`dockerEnabled` was deleted afterwards. Not driven: the process detail "CPU energy" row.

Phase 2 (Projects card, Timeline card, Keep history, Delete history): **not yet driven.** The
display was asleep or locked during the session. Covered by unit tests; on-screen check pending
(Phase 3 brief 3a).

Not driven by hand: the 15-minute auto-pause, Refresh now, the interval picker during a session
and Custom labels. Each is covered by a unit test (`LiveMonitorTests`, `WorkloadHeuristicsTests`).

## v2 Phase 2 (Live, projects, timeline, history)

Observed on 2026-10-28 with this checkout's Debug app, built with
`scripts/run-app.sh --build-only` and opened from its generated app bundle. The display
was awake. System Events opened the concentric-rings status item; the panel was detached
with a CoreGraphics drag, then driven through accessibility controls and mouse input.
Screenshots and raw UI output remain in ignored local scratch storage.

| Step | Check | Result | Observation |
|---|---|---|---|
| 1 | Launch, panel, initial history state | pass | Keep history was off, Keep for showed 7 days, and the size line read “Nothing saved”; Docker was off. |
| 2 | Live with Docker off; Projects and expansion | pass | At update 3, four repository-named rows appeared with “Show all 13 projects” and Unattributed, without Docker VM; expanding a repository showed Git attribution and process-group names with process counts. |
| 3 | Open process detail from Live; repository name | fail | Clicking a Top CPU process row left Live unchanged; project expansion exposed group summaries but no process-detail link, so a repository name in process detail could not be verified from Live. |
| 4 | Timeline, placeholder commands and inference | pass | The CPU line and busiest-moment projects were visible; within ten seconds the two harmless placeholders produced “npm ci started”, “vitest started” and “2 expensive commands at once”, with an orange “inference” label and a dashed event marker. |
| 5 | Enable Docker; project attribution and VM row | pass | Docker was already running; one container appeared inside its repository row with Compose working-directory evidence and separate container memory, alongside Docker VM and Unattributed rows. |
| 6 | Enable history, one-day retention, two minutes, delete | pass | Keep history on with 1 day selected showed 535 KB after 122 seconds of Live; confirming Delete history returned the size to “Nothing saved”, then Keep history was turned off. |
| 7 | Wording matches history behaviour | fail | “Settings are stored on this Mac. HeatLens keeps no scan history.” remained visible while Keep history was on and Live history occupied 535 KB; it does not explain the Scan/Live distinction. |
| 8 | Restore settings, stop Live and quit | pass | Live was paused, Docker and Keep history were off, retention was restored to 7 days, history was deleted and the app quit; `pgrep -fl HeatLens` printed nothing (exit 1). |

Both placeholder sleeps exited naturally; no process-stop or container-lifecycle control was
used. Launch at login and unrelated settings were unchanged. The two failures are recorded
for follow-up; no source code was changed. These observations supersede the earlier Phase 2
“not yet driven” note above. Counts and sizes describe this run, not fixed expectations.

To repeat, run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh`,
open the concentric-rings icon and follow steps 1–8. In Live, use a five-second interval and
keep the panel open; run the two 40-second placeholders from the checkout as specified in
the brief. Confirm the three timeline events and inference label, then history growth and
deletion. Restore settings and quit. Activity Monitor comparison and process-detail repository
attribution outside Live were not checked in this phase.
