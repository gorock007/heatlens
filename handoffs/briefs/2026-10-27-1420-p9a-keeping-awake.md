# Phase 9a: what's keeping the Mac awake (power assertions) in the scan, UI, reports and CLI/MCP
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-27 14:17 · terminal: b15c7e38-eba4-4880-9eb8-2a1ad2fb9192

## Goal
People often want to know why their Mac won't sleep or why the display stays on. macOS records this as **power assertions** held by processes. Show them, tied to the process and project HeatLens already resolves, the same way ports work. Done means:
1. **Core sampling.** A new `Sources/HeatLensCore/Sampling/PowerAssertionSampling.swift` reads assertions once per scan with the public IOKit API `IOPMCopyAssertionsByProcess` (`IOKit/pwr_mgt/IOPMLib.h`), not `pmset`. For each assertion, record:
   - PID, mapped to the snapshot's `ProcessIdentity` (skip it if that PID isn't in the snapshot)
   - the raw type string
   - the name
   - the start time, when present
   - the timeout, when present

   Check the dictionary keys against the installed SDK header and against `pmset -g assertions` on this Mac.
   - Keep the types that actually block sleep: `PreventUserIdleSystemSleep`, `PreventSystemSleep`, `NoIdleSleepAssertion`, `PreventUserIdleDisplaySleep`, `NoDisplaySleepAssertion`, plus any other type the header says prevents sleep.
   - Drop transient `UserIsActive` and `BackgroundTask`, and say in the handoff what else you dropped.
   - Map types to plain words: "Prevents idle sleep", "Prevents sleep", "Keeps the display on".
   - Add a fast `sampler` protocol like `PortSampling`, so tests inject synthetic data.
2. **Model.** Add a `PowerAssertion` type to `Sources/HeatLensCore/Model/` plus `ScanSnapshot.powerAssertions`. Follow how `listeningPorts` was added: a defaulted init parameter and a `decodeIfPresent` in `init(from:)`, with old JSON decoding as empty (tested).
3. **Rules.** Add one new `FindingKind`, `preventingSleep`, with severity `info`, one finding per group that holds a sleep-blocking assertion.
   - Title: "Keeping your Mac awake: <group label>".
   - Explanation: which kind of sleep it blocks and for how long ("for 3 h 12 min").
   - Evidence: each assertion's type and name.
   - Limitations: "Apps keep the Mac awake on purpose while playing media, downloading or running a task; this is not a fault."
   - Actions: Inspect, plus Open project when the group has one.
   - It ranks **below** every existing finding (heat first, PRD §7 priority rule), and existing findings' IDs, order and severities don't change (tested).
   - When the holder is `caffeinate` and its parent is gone (PPID 1), or it was started by a dev tool or agent, say so in the explanation. Don't raise the severity.
4. **Export.** Add a "Keeping the Mac awake:" section to the text report (`- Prevents idle sleep — caffeinate, PID 123, since 14:02 (3 h 12 min), project my-app, name "…"`) and a `powerAssertions` field to the JSON. **Assertion names can hold personal text** (a track title, a URL, a file path), so:
   - pass them through the existing `Redactor` sanitizer
   - cut them to 80 characters
   - strip URLs to their host
5. **UI.**
   - `App/ResultsView.swift` gets a "Keeping your Mac awake" section right after the "Ports" section, built the same way: whole-row button that opens `ProcessDetailView`, collapsed past 6 rows, hidden when empty.
   - `App/ProcessDetailView.swift` gets a "Preventing sleep" row.
   - Add one fixture assertion to `App/FixtureScanService.swift` (e.g. `caffeinate` holding PreventUserIdleSystemSleep for 3 h).
6. **CLI/MCP.**
   - Add `heatlens awake [--json]`, a fast read like `heatlens ports` (no CPU sample).
   - Add an MCP tool `awake` (no arguments, `readOnlyHint: true`).
   - Give it a core entry point next to `ScanPipeline.ports()`, sharing the Redactor formatting with the scan report.
   - Add one line to README's agent section.
7. **Cost.** Add the time the assertion read takes on this Mac to `docs/PERFORMANCE.md`.

## Context
- Prior handoffs:
  - `handoffs/merged/2026-10-27-1327-p8a-listening-ports.md` (ports): copy its whole shape, including sampler, snapshot field, Redactor section, rules evidence, UI section and fixtures
  - `handoffs/merged/2026-10-27-1343-p7b-bundle-cli-connect.md`: `ScanPipeline.ports()`, `PortsSnapshot`, the `ports` CLI subcommand and MCP tool
  - `handoffs/merged/2026-10-27-1400-p7c-cap-text-report.md`: the text report caps
- Patterns to copy:
  - `Sources/HeatLensCore/Sampling/PortSampling.swift`
  - `Sources/HeatLensCore/Model/ListeningPort.swift`
  - the Ports section in `App/ResultsView.swift` (~line 143)
  - the `ports` cases in `Sources/HeatLensCLI/Arguments.swift` and `MCPServer.swift`
  - tests in `Tests/HeatLensCoreTests/PortSamplingTests.swift` and `Tests/HeatLensCLITests/CLITests.swift`
- Live test: create a real assertion in-process with `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, …, "HeatLens test")`, find it for `getpid()`, then release it with `IOPMAssertionRelease`, in a `defer`.
- IOKit linking: `import IOKit.pwr_mgt` should autolink. If SwiftPM or xcodegen needs an explicit link, add the smallest setting and name it.
- Privacy: never commit real assertion listings from this Mac. Fixtures and synthetic data only.

## Scope
- May touch:
  - `Sources/HeatLensCore/Sampling/` (new file)
  - `Sources/HeatLensCore/Coordinator/`
  - `Sources/HeatLensCore/Pipeline/ScanPipeline.swift`
  - `Sources/HeatLensCore/Export/Redactor.swift`
  - `Sources/HeatLensCore/Rules/RulesEngine.swift`
  - `Sources/HeatLensCLI/`
  - `Sources/heatlens-probe/main.swift`
  - `Tests/`
  - `App/ResultsView.swift`, `App/ProcessDetailView.swift`, `App/FixtureScanService.swift`, `App/FindingCard.swift` (only if the new kind needs a label)
  - `README.md`
  - `docs/PERFORMANCE.md`
- Must not touch: `App/StatusPanel.swift`, `App/HeatLensApp.swift`, `App/SettingsView.swift`, `Sources/HeatLensCore/Safety/`, `scripts/`, `site/`, `dist/`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/` (new `PowerAssertion` type, the snapshot field, the `FindingKind` case), `Package.swift` / `project.yml` only if IOKit linking needs it

## Done when
- Checks pass with new tests: synthetic parsing and filtering, the live in-process assertion, Codable backward compatibility, rules (the new finding ranks last, existing order unchanged), export redaction of names (URL → host, truncation, home path), and the `awake` CLI and MCP tool.
- With `caffeinate -i -t 300 &` running from your scratch folder:
  - `swift run heatlens awake` lists it
  - a Debug app scan (launched with `open -n`; `/Applications/HeatLens.app` may be running, don't touch it) shows the "Keeping your Mac awake" section and the finding
  - stop your `caffeinate` by PID afterwards
  - the handoff names a screenshot path in your scratch folder

## Phase
One phase.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`. Bound long runs with `scripts/with-timeout.sh 600`.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
