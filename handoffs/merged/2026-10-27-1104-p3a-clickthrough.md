# Phase 3a clickthrough blocked by native computer-use timeout
status: partial
agent: codex gpt-6-astra
brief: handoffs/briefs/2026-10-27-0000-p3a-clickthrough.md

## What the user asked
Drive the real menu-bar app through the ten clickthrough steps, document observed outcomes, and update scenario coverage for scenarios 6, 8, 9 and 11 without changing source code.

## What changed
No product or documentation changes. Built the app and launched a new instance, but the native computer-use tool could not return its UI state. Stopped that instance and reset the task's computer-use runtime before handing off.

The concrete blocker is native UI access: `cua.getApp()` returned `Computer Use server error -10005: timeoutReached` on three attempts (twice using the built app's absolute path, once using bundle ID `dev.heatlens.HeatLens`). `cua.getState()` could list apps, but no HeatLens accessibility tree or screenshot was obtained. The tool did not identify a missing permission, so **neither Screen Recording nor Accessibility denial is confirmed**. It would be inaccurate to attribute this timeout to either permission without further diagnosis. Neither `cua-driver` nor `peekaboo` is installed; nothing was installed or granted access.

## Files
- handoffs/2026-10-27-1104-p3a-clickthrough.md — created

## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/with-timeout.sh 600 zsh -o pipefail -c 'swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30'` — passed; 99 tests in 18 suites passed in 3.965 seconds.
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/with-timeout.sh 600 zsh -o pipefail -c 'scripts/run-app.sh --build-only 2>&1 | tail -20'` — passed.
- Before launch, `pgrep -x HeatLens` printed nothing. The tool launched this checkout's built app as PID 48227; `ps -p 48227 -o pid=,comm=` confirmed its executable. Sent SIGTERM only to that owned app PID for cleanup. No process discovered by a scan was signalled.
- After app cleanup and computer-use runtime reset, both `pgrep -fl HeatLens` and `pgrep -x HeatLens` printed nothing (exit 1).
- `git diff --stat` showed only pre-existing edits to `handoffs/JARVIS.md` and `handoffs/OPEN.md`; neither was touched by this worker. The brief was also already untracked at entry.
- No clickthrough step was completed: the app launched, but the thermometer and Scan now could not be accessed. Settings, exclusions and launch-at-login were not inspected or changed. Post-scan idle measurements and quit-during-scan behavior remain unchecked.
- `docs/CLICKTHROUGH.md` was not created and `docs/SCENARIOS.md` was not modified, following the brief's instruction to stop when computer use is unavailable. The two-document privacy check therefore has no new report to validate.

Manual verification command after access is restored: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh`. Click the thermometer, then **Scan now**, compare the result with Activity Monitor, and complete the ten ordered steps in the brief. Do not click **Send SIGTERM** or toggle launch at login.

## Processes left running
none

## Questions for the user
1. Can Jarvis restore native computer-use access to HeatLens and return this brief once its accessibility tree or screenshot is readable (checking Screen Recording and Accessibility permissions if needed)?

## Notes for Jarvis
- This is the single first blocked handoff; update this same file when the answer arrives.
- No source, shared configuration, product docs, login item or app settings were changed. No screenshots or real scan output were saved or published.
- The superset-computer skill was read. No missing permission was established; the stop follows this brief's computer-use availability rule. The built-in computer-use provider was available but its HeatLens access timed out.
- No commit or release action is needed yet. Resume the clickthrough after the access blocker is resolved.

## Answer (Jarvis, 2026-10-27)
Permissions are fine. From the same Superset host, System Events read the menu bar and found HeatLens's status item (`menu bar item 1 of menu bar 2 of process "HeatLens"`), and `screencapture -x` captured real screen content. The worker's terminal had closed, so the brief is respawned with a System Events / screencapture fallback: `handoffs/briefs/2026-10-27-1110-p3a2-clickthrough-fallback.md`.
