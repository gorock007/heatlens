# Text report: leave out projects that show 0.0 cores
worker: opencode
model: <placeholder>
effort: low
started: 2026-10-28 11:47 · terminal: 76a646da-52a8-4c1f-a9ce-bea4f0baf412

## Goal
User ruling (2026-10-28): hide the 0% projects from the report. In `Sources/HeatLensCore/Export/Redactor.swift`, the text report's `Projects:` section (the function documented at ~line 157, "The \"Projects:\" section, names only…") lists every row, including ones that render as `0.0 cores (0%)`.

**Done when** `swift build` and `swift test --filter Redactor` pass, and the text report's Projects section leaves out every row whose CPU is missing or under 0.05 cores (`cpuPercent` nil or `< 5`, because `cpuPercent` uses 100 = one core). This applies to project rows **and** to the Docker VM / Unattributed rows.
- Filter *before* applying `textProjectLimit`, so the 8 shown are the 8 busiest non-idle rows, and "and N more projects" counts only the non-idle projects that didn't fit.
- If any rows were hidden for being idle, add one last line: `N idle projects not shown; Copy JSON for the full list`. Use "1 idle project" for one.
- If every row is idle, leave out the whole section, exactly as when there are no rows.
- **Leave the JSON report (`jsonReport`, `projects` array) unchanged:** it keeps every row.

## Context
- The section was added by `handoffs/merged/2026-10-28-1330-v2-projects-in-reports.md`. Read the current `Projects:` function in `Redactor.swift` and the suite "Redacted export: projects" in `Tests/HeatLensCoreTests/RedactorTests.swift` and follow their style.
- Add tests to that suite:
  1. a breakdown with one busy project and two idle ones (one at `cpuPercent` 2, one with nil) shows only the busy one plus "2 idle projects not shown; …"
  2. all idle → no `Projects:` line
  3. 9 busy + 3 idle → 8 lines, "and 1 more projects…", and "3 idle projects not shown…"
  4. the JSON still lists all rows

  Adjust any existing test in that suite that now expects a 0.0-core row.

## Scope
- May touch: `Sources/HeatLensCore/Export/Redactor.swift` (the Projects text section only), `Tests/HeatLensCoreTests/RedactorTests.swift`
- Must not touch: everything else. In particular, not `jsonReport`, `Sources/HeatLensCLI/`, `App/`, or any other test file. Don't run git commands.

## Phase
This phase only.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
scripts/with-timeout.sh 600 swift test --filter Redactor 2>&1 | tail -30
```
Write your handoff as a file at `handoffs/YYYY-MM-DD-HHMM-hide-idle-projects-in-report.md` (see `AGENTS.md`). Save it to disk; don't just print it.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
