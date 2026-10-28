# v2 Phase 4d: HeatLensLog (os.Logger, names .private) and its call sites
status: done
agent: claude claude-sonnet-5-5
brief: handoffs/briefs/2026-10-28-2200-v2-p4d-structured-logs.md

## What the user asked
`HeatLensLog` with a typed `Value` enum (only `.name` carries a String, always `.private`), a test sink, log lines at the listed call sites, `HeatLensLogTests`, plus two extras: the export log call and two stale Settings strings.

## What changed
- **`HeatLensLog`** (subsystem `dev.heatlens`): `notice`/`error`/`debug` take a category, a static event and typed values.
  - It renders numbers, flags and static words into one public text and names into a separate private text, so a saved log shows `<private>` for names.
  - The test sink is a `@TaskLocal`, so parallel suites don't see each other's lines.
- **Call sites** (log lines only):
  - `LiveMonitor`: session started/stopped/auto-paused/failed. The failure message is not logged because it can carry a path. Each alert logs its rule, plus the project name as `.name` for a watch.
  - `BackgroundMonitor`: mode changes with a reason. Interval/reason changes within a mode are a notice at most once per 10 min and debug otherwise.
  - `HistoryStore`: open failure, write and maintenance failures logged once until a write succeeds again (then one "recovered" line), delete success and failure.
  - `DockerEngineSampler`: availability changes only, compared by case.
  - `ActionLog.added`: action and outcome as words, target as `.name`. The detail text is never logged.
  - `IncidentExportSheet`: export saved with format as a word and anonymised as a flag.
- **Settings strings**: History caption and "Changes apply to the next scan, and to Live when you close Settings."

## Files
- Sources/HeatLensCore/Logging/HeatLensLog.swift — created
- Tests/HeatLensCoreTests/HeatLensLogTests.swift — created
- Sources/HeatLensCore/Live/LiveMonitor.swift — modified
- Sources/HeatLensCore/Background/BackgroundMonitor.swift — modified
- Sources/HeatLensCore/History/HistoryStore.swift — modified
- Sources/HeatLensCore/Docker/DockerEngine.swift — modified
- App/HistoryService.swift — modified
- App/IncidentExportSheet.swift — modified
- App/SettingsView.swift — modified
- handoffs/2026-10-28-2230-v2-p4d-structured-logs.md — created

(`handoffs/OPEN.md`, the 4g files and other App/ changes in the tree are not mine.)

## Checks run
- `swift build`: complete.
- `swift test --filter HeatLensLog` ×3: 4 tests pass each time (name is private, 100-tick steady idle session emits at most one background notice, `Logger(` only in `HeatLensLog.swift`, every `privacy: .public` is the one line in that file, only `.name` carries a String).
- Full suite once via the lock: passed (the lock reported a pass on the identical tree afterwards).
- `scripts/run-app.sh --build-only`: built. I did not read the full xcodebuild log for warnings.
- **`log stream` check** (Debug app, screen unlocked, no other HeatLens was running, panel Live; I Paused and restarted Live): "session started", "session stopped" and "mode changed" lines appear (paused/user, then foreground/viewer attached, 5.0 s). Every line ends in an empty `<private>` and none contains a process or project name. Live had already been running for a couple of minutes before the stream began, so those earlier lines weren't captured. No alert fired during the capture, so the alert line wasn't seen live.
- Not checked: Docker availability, history failure and action-record lines in the live app (unit-level only through the sink for the name rule).

## Processes left running
none (the app was quit by PID and `log stream` stopped by PID; `jarvis leftovers --mine` is clean).

## Questions for the user
None.

## Notes for Jarvis
- **Deviation:** the alert line logs `held` as the rule's configured `sustain`, not the measured hold. `Alert` carries no numeric held value, and `Rules/AlertPolicy.swift` is outside my list.
- The grep test allows exactly one form of `privacy: .public` (the event plus the pre-rendered text). That text is built only from numbers, flags and static words, so no String is public.
- Docs for you: add `log show --last 1h --info --predicate 'subsystem == "dev.heatlens"'` to LIMITATIONS/README.
- No shared files touched.
- Suggested commit: `feat(v2): Phase 4d — HeatLensLog (os.Logger, names .private) with call sites in Live, Background, History, Docker, actions and export; Settings caption fixes`
