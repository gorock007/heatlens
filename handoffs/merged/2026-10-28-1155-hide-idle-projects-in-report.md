# Text report: leave out projects that show 0.0 cores
status: done
agent: opencode big-pickle
brief: handoffs/briefs/2026-10-28-1345-hide-idle-projects-in-report.md

## What the user asked
Hide the 0%/idle projects from the text report's Projects section. Rows with missing CPU or < 0.05 cores (cpuPercent nil or < 5, since 100 = one core) are filtered before applying textProjectLimit. Apply to project rows and Docker VM/Unattributed. Add "N idle projects not shown; Copy JSON for the full list" if any hidden; if all idle, omit Projects section entirely. JSON report unchanged.

## What changed
- Filtered idle project rows (cpuPercent nil or < 5) in the text Projects section before applying the limit; counted idle rows separately and appended idle summary. Docker VM/Unattributed follow same rule.
- Added tests for idle filtering and updated existing project tests to match new behavior (idle < 5 shown as hidden).
- JSON projects array still includes all rows.

## Files
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Tests/HeatLensCoreTests/RedactorTests.swift — modified

## Checks run
- export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 — Build complete! (7.24s)
- export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/with-timeout.sh 600 swift test --filter Redactor 2>&1 | tail -15 — Test run with 17 tests in 2 suites passed after 1.048 seconds.

## Processes left running
none

## Questions for the user
none

## Notes for Jarvis
Suggested commit message: "Hide idle projects in text report Projects section"
Touch only files in scope; JSON report unchanged as required.
