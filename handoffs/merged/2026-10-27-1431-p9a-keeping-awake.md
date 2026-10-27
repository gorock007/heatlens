# Phase 9a: what's keeping the Mac awake (power assertions) in the scan, UI, reports and CLI/MCP
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1420-p9a-keeping-awake.md

## What the user asked
Show which processes hold power assertions that keep the Mac (or its display) awake, tied to the
process, group and project HeatLens already resolves, the same way ports work. This covers the
scan, a new info finding, both exports, the results and detail views, a `heatlens awake` command,
an MCP `awake` tool, and the cost of the read.

## What changed
- **Sampling.** `IOKitPowerAssertionSampler` (new `Sampling/PowerAssertionSampling.swift`) makes
  one `IOPMCopyAssertionsByProcess` call at the end of every scan, right after the port read, on
  the second process reading. The pure `PowerAssertionParsing` keeps an assertion only when:
  - its PID is in the reading,
  - its level isn't 0 (off),
  - and its type blocks sleep.

  `PowerAssertionSampling` is the protocol tests inject.
  - Keys I checked against the SDK's `IOPMLib.h` and against a real assertion on this Mac
    (`pmset -g assertions` matched):
    - `AssertType`, `AssertName`, `TimeoutSeconds` and `AssertLevel` are in the header.
    - `AssertStartWhen` (a date) and `AssertionOnBehalfOfPID` are what the call actually returns.
  - **Kept, with their plain words:**
    - "Prevents idle sleep": `PreventUserIdleSystemSleep`, `NoIdleSleepAssertion`
    - "Prevents sleep": `PreventSystemSleep`, plus **`NetworkClientActive`**. The header says that
      one "will keep the computer awake".
    - "Keeps the display on": `PreventUserIdleDisplaySleep`, `NoDisplaySleepAssertion`
  - **Dropped:**
    - the transient types `UserIsActive` and `BackgroundTask`
    - `PreventDiskIdle` (the header says the system may still sleep)
    - `ExternalMedia`, `SystemIsActive`, `ApplePushServiceTask`, `SoftwareUpdateTask`,
      `PreventSystemSleepSecurityIndicator` and `InternalPreventDisplaySleep` (not in the public
      header, or they don't block sleep)
    - any assertion at level 0
  - **Three attribution rules the brief didn't spell out:**
    1. An assertion created on another process's behalf belongs to that process, if it's in the
       reading. For example, coreaudiod holds the assertions for audio playback, and they show
       as "Created for PID: N" in `pmset`. `createdByPID` records the creator. If the beneficiary
       isn't in the reading, the creator keeps the assertion.
    2. **powerd's own assertions are dropped.** One is "Powerd - Prevent sleep while display is
       on". It mirrors the display state rather than causing it, and would otherwise be a
       permanent finding.
    3. An assertion that started more than 1 s before its process did is dropped. It belonged to
       an earlier process with the same (reused) PID.
- **Model** (shared dir, new `Model/PowerAssertion.swift`):
  - types: `SleepEffect` (label and wording), `PowerAssertion` (type, name, startedAt,
    timeoutSeconds, createdByPID), `ProcessPowerAssertions`, and `PowerAssertionListing` (one
    row per assertion with its group, oldest first, used by the UI and the Redactor)
  - helpers: `PowerAssertion.durationText` ("3 h 12 min") and `snapshot.assertions(for:)`
  - `ScanSnapshot.powerAssertions` follows the `listingPorts` pattern: a defaulted init
    parameter, and `decodeIfPresent`, so older JSON decodes as empty
  - `FindingKind.preventingSleep`
- **Coordinator and pipeline.**
  - `ScanCoordinator.init` takes `assertionSampler:` (defaulted).
  - `ScanAssembly.snapshot` takes `assertions:`. It drops holders that exited. A failed read
    becomes one notice: "What's keeping the Mac awake is unavailable (…)".
  - `ScanCoordinator.awake()` / `ScanAssembly.awakeSnapshot` / `ScanPipeline.awake()` →
    `AwakeSnapshot` sit next to `ports()`: one process reading, no host or CPU sampling.
    `portsSnapshot` now shares two small helpers with it. Its behaviour is unchanged.
- **Rules.** There is one `preventingSleep` finding per group that holds an assertion:
  - severity `info`, confidence high
  - title "Keeping your Mac awake: <group label>"
  - explanation, one holder: "caffeinate (PID 123) has been preventing idle sleep for 3 h 12 min."
  - explanation, several: "2 processes in this group are keeping the display on and preventing
    idle sleep, the longest for 20 min."
  - evidence: one line per assertion (label = raw type, value = name), a "Created for PID N by"
    line when another process created it, and "Held for".
  - limitation: the brief's sentence
  - actions: Inspect (the first holder), plus Open project when the group has one
  - `affectedProcesses` lists the holders only, not the whole group
  - It ranks **after every other finding** (impact −1; all other impacts are ≥ 0).
  - Caffeinate notes, with the severity left at info:
    - "It was left running after the process that started it exited (PPID 1)." Several such
      caffeinates in one group share one sentence.
    - "It was started by claude.exe (PID 86152), an AI agent." / "…, a dev tool." This uses
      the nearest ancestor (up to 12 levels) whose name is in a short agent list (claude, codex,
      opencode, gemini, aider, cursor-agent) or dev-tool list (node, npm, pnpm, yarn, bun,
      python, make, cargo, …).
- **Export.**
  - The text report gets a "Keeping the Mac awake:" section after "Listening ports", for example:
    `- Prevents idle sleep — caffeinate, PID 123, since 14:02 (3 h 12 min), timeout 5 min, project my-app, name "caffeinate command-line tool"`
    - `since` uses local time and adds the date when it isn't the same day.
    - "timeout …" and "created by coreaudiod (PID 77)" appear only when present.
    - It shows `- none` when empty.
  - The JSON gets `powerAssertions` rows: pid, processName, groupLabel, projectDirectory, type,
    effect, name, startedAt, heldSeconds, timeoutSeconds, createdByPID, createdByName.
  - **Names** are cleaned in this order:
    1. every `scheme://…` URL becomes its host (user:password@ removed), or `<file URL>` when
       there is no host
    2. the existing `Sanitizer` runs (home → `~`, username, secrets)
    3. the result is cut to 80 characters, ending in "…"

    The finding's assertion evidence gets the same cleaning in both exports. The app shows the
    raw name.
- **UI.**
  - `ResultsView` has a "Keeping your Mac awake" section right after "Ports", built like it:
    - the whole row is a button with an accent "Inspect" label, and opens `ProcessDetailView`
    - a cup icon, or a display icon for "keeps the display on"
    - two lines per row: `name · PID`, then `effect · duration · group · project`
    - the tooltip is the assertion name
    - it shows 6 rows, then "Show all N", and is hidden when empty
  - `ProcessDetailView` has a "Preventing sleep" row, e.g.
    `Prevents idle sleep for 3 h 0 min (“caffeinate command-line tool”)`.
  - The fixture has `caffeinate` PID 4120, a child of opencode, holding
    PreventUserIdleSystemSleep for 3 h, plus its hand-written finding.
  - `FindingCard` didn't need changes.
- **CLI/MCP.**
  - `heatlens awake [--json]` (help text updated, and "mcp" now says three tools).
  - The MCP tool `awake` takes no arguments (`additionalProperties: false`,
    `readOnlyHint: true`) and returns the text.
  - `Redactor.awakeTextReport` gives a header, the notices, then the **same** lines as the scan
    report. `awakeJSONReport` gives `{readAt, notices, powerAssertions}` with the same rows.
  - README has the command and one tool line.
- **Probe** prints the assertions (type only, no names) and a timing line.
- **Cost:** 0.44–0.59 ms per read (about 700 processes, release, 4 runs), 0.57–0.58 ms in
  debug. This is recorded in `docs/PERFORMANCE.md` §2 item 6.

## Files
- Sources/HeatLensCore/Model/PowerAssertion.swift — created (shared Model dir)
- Sources/HeatLensCore/Model/SystemSample.swift — modified (shared: `ScanSnapshot.powerAssertions` + Codable)
- Sources/HeatLensCore/Model/Findings.swift — modified (shared: `FindingKind.preventingSleep`)
- Sources/HeatLensCore/Sampling/PowerAssertionSampling.swift — created
- Sources/HeatLensCore/Coordinator/ScanCoordinator.swift — modified
- Sources/HeatLensCore/Coordinator/ScanAssembly.swift — modified
- Sources/HeatLensCore/Pipeline/ScanPipeline.swift — modified
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Sources/HeatLensCore/Rules/RulesEngine.swift — modified
- Sources/HeatLensCLI/Arguments.swift — modified
- Sources/HeatLensCLI/LiveScan.swift — modified
- Sources/HeatLensCLI/MCPServer.swift — modified
- Sources/heatlens/main.swift — modified (**outside the brief's list**, see Notes)
- Sources/heatlens-probe/main.swift — modified
- Tests/HeatLensCoreTests/PowerAssertionTests.swift — created
- Tests/HeatLensCLITests/CLITests.swift — modified
- App/ResultsView.swift — modified
- App/ProcessDetailView.swift — modified
- App/FixtureScanService.swift — modified
- README.md — modified
- docs/PERFORMANCE.md — modified
- handoffs/2026-10-27-1431-p9a-keeping-awake.md — created

(`handoffs/OPEN.md` and the brief were already modified/untracked before I started. They aren't mine.)

## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build && swift test`:
  build complete, **143 tests in 29 suites passed**. The new ones:
  - `PowerAssertionTests.swift` (16 tests):
    - type mapping and dropped types
    - duration text
    - parsing: off-level, unknown-PID and zero-timeout cases
    - attribution: on-behalf, powerd and reused PID
    - **live:** an assertion created with `IOPMAssertionCreateWithName` is found for `getpid()`,
      then released in a `defer`
    - coordinator wiring, the failure notice, and `awake()` reading once with no host sampling
    - Codable backward compatibility
    - rules: ranks last, while existing IDs, order and severities stay unchanged on a snapshot
      with high CPU, detached worker, swap and thermal findings; plus group combining, the
      agent-started note, the shared PPID-1 sentence, and no assertions → no finding
    - the text section, exactly
    - JSON rows and name cleaning: URL → host, `file://` → `<file URL>`, user:pw removed, home →
      `~`, cut to 80
    - cleaned evidence in both exports
    - the awake reports share their lines and rows
    - **live:** `ScanPipeline().awake()` finds a display assertion in under 1 s
  - `CLITests`: `awake` parsing, the tool in `tools/list`, and `awake` calls (no arguments,
    arguments rejected, failure → tool error).
- `scripts/run-app.sh --build-only`: built. IOKit autolinked in SwiftPM and xcodegen, so there
  are **no `Package.swift` / `project.yml` changes**.
- `git diff --check`: clean. I grepped the new and changed files for usernames and real paths;
  only the synthetic `/Users/someone` turned up.
- Live, with `caffeinate -i -t 300 &` (later `-t 600`) started from my scratch folder:
  - `swift run heatlens awake` listed it (`Prevents idle sleep — caffeinate, PID 12276, since 14:24 (under 1 min), timeout 5 min, …`).
  - I launched a Debug app instance with `open -n` and drove it through System Events: Scan now
    showed the "Keeping your Mac awake" section after Ports, and the findings. One said that my
    caffeinate "was left running after the process that started it exited (PPID 1)", because
    my subshell had exited. Another worker's caffeinate showed "It was started by claude.exe
    (PID …), an AI agent". A coreaudiod-style on-behalf assertion was attributed to
    RemindersWidgetExtension.
  - Clicking a row opened the detail view with "Preventing sleep".
  - While navigating I clicked the gear once by mistake and closed Settings with Done. Nothing
    was changed.
  - Screenshots (local only; they show real process names, PIDs and my scratch path, **don't commit them**):
    - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/69570abe-0e89-4d95-9719-b682b59fd8ab/scratchpad/p9a-results-awake2.png (section after Ports)
    - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/69570abe-0e89-4d95-9719-b682b59fd8ab/scratchpad/p9a-findings-left.png (finding with the PPID 1 note, final wording)
    - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/69570abe-0e89-4d95-9719-b682b59fd8ab/scratchpad/p9a-findings.png (agent-started caffeinate finding)
    - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/69570abe-0e89-4d95-9719-b682b59fd8ab/scratchpad/p9a-detail.png (detail view with "Preventing sleep")
  - I stopped both caffeinates and both of my app instances by PID.
- **Not checked:**
  - the SwiftUI preview canvas (the fixture compiles, but I didn't render it)
  - "Show all N" with more than 6 assertions in the live app
  - an MCP session against the built helper (only the unit tests)
  - a `NetworkClientActive` or display assertion in the live app (the display one is covered
    by the live pipeline test)
  - Copy report / Copy JSON in the live app (I didn't want to clobber the clipboard; the
    Redactor tests cover the text)
  - Activity Monitor: it has no assertions view, and `pmset -g assertions` was used instead
- **For the user to verify:**
  1. Run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh --build-only`,
     then `open -n .build/xcode/Build/Products/Debug/HeatLens.app`.
  2. Run `caffeinate -i -t 300 &` in a terminal.
  3. Click Scan now and scroll to **Keeping your Mac awake**, right after Ports. Click the row to
     see **Preventing sleep**.
  4. Compare with `pmset -g assertions`. Also run
     `.build/xcode/Build/Products/Debug/HeatLens.app/Contents/Helpers/heatlens awake`.

## Processes left running
none. `jarvis leftovers --mine` reports nothing. PID 26715 is a Debug HeatLens that was already
running from this checkout. I didn't start it and left it alone. Its bundle was rebuilt
underneath it, so relaunch it to see the new section.

## Notes for Jarvis
- **Outside the brief's may-touch list:** `Sources/heatlens/main.swift` (+8 lines). The
  `heatlens awake` subcommand needs a case in its exhaustive `switch`, and `MCPServer.init` now
  takes `awake:`. It's the same shape as the `ports` case.
- Shared-file edits:
  - `Sources/HeatLensCore/Model/SystemSample.swift`: the field, `CodingKeys` and `init(from:)`
  - `Sources/HeatLensCore/Model/Findings.swift`: one enum case
  - the new `Sources/HeatLensCore/Model/PowerAssertion.swift`
  - no `Package.swift` / `project.yml` changes
- **Judgement calls to confirm with the user if they care:**
  1. on-behalf assertions are attributed to the beneficiary
  2. powerd's own assertions are dropped
  3. `NetworkClientActive` counts as "Prevents sleep"
  4. the finding's Inspect targets the holder, not the group root
- `MCPServer.init` gained a required `awake:` parameter (public API of the `HeatLensCLI` library).
- Suggested commit message: `feat(core,app,cli): what's keeping the Mac awake (power assertions) in scan, finding, reports, results, detail, heatlens awake and MCP tool (Phase 9a)`
