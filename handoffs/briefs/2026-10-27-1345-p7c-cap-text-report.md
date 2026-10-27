# Phase 7c: cap the processes the text report lists per finding, and long argv
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-27 13:45 · terminal: 8648efb6-bbd8-4c9d-9c30-7344700a46a5

## Goal
`Redactor.textReport` (`Sources/HeatLensCore/Export/Redactor.swift:8-58`) lists the top `processLimit` (15) processes by CPU **plus every process any finding names**. One finding named ~300 processes on this Mac, so the text was 60–78 KB. That text is what "Copy report" copies and what the MCP `scan` tool returns by default, so it must stay small. Done means:
1. From each finding's `affectedProcesses`, the text report lists at most **5** processes, the highest CPU first (unmeasured last, ties by PID, the same ordering as `byCPU`). They're still merged with the top-15-by-CPU set and deduplicated as today.
2. Under each finding that names more than 5, add one line: `  Processes: 5 of 312 listed; Copy JSON for the full list`. The existing final "N other processes omitted" line stays correct.
3. An argv longer than 300 characters in the text report is cut to 300 characters with `… (+N chars)` added. JSON is unchanged: it keeps everything.
4. The JSON report (`jsonReport`, `portsJSONReport`) and the app's UI are unchanged.
5. On this Mac, `swift run heatlens scan --seconds 3 | wc -c` comes out under ~20 KB. Put the number in the handoff, not the output.

## Context
- Prior handoff: `handoffs/merged/2026-10-27-1343-p7b-bundle-cli-connect.md` (Notes for Jarvis, the last bullet, is this task).
- Pattern to copy: the existing omitted-count line at the end of `textReport`. Tests extend `Tests/HeatLensCoreTests/RedactorTests.swift` (swift-testing). Build a synthetic finding with ~20 affected processes and check the per-finding cap, the "5 of 20" line, the omitted count and argv truncation. Use synthetic data only.
- Check whether `Tests/HeatLensCoreTests/SampleReportTests.swift` or `docs/samples/` hold a golden text report. If a golden changes, update it, and say so.

## Scope
- May touch: `Sources/HeatLensCore/Export/Redactor.swift`, `Tests/HeatLensCoreTests/RedactorTests.swift`, `Tests/HeatLensCoreTests/SampleReportTests.swift`, `docs/samples/` (only if a golden text sample changes)
- Must not touch: everything else (`App/`, `Sources/HeatLensCLI/`, `Rules/`, `Model/`, `project.yml`, `Package.swift`)
- Shared files: none

## Done when
Checks pass, with the new tests. The handoff has the `wc -c` figure from point 5.

## Phase
One phase.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
