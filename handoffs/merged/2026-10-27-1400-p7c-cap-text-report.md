# Phase 7c: cap the processes the text report lists per finding, and long argv
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1345-p7c-cap-text-report.md
## What the user asked
Keep the text report (Copy report, `heatlens scan`, the MCP `scan` tool's default output) small. A finding that names hundreds of processes made it 60–78 KB.
## What changed
- `Redactor.textReport` now lists at most 5 of each finding's processes (`textFindingProcessLimit`), busiest first, in the same `byCPU` order: unmeasured last, ties by PID. They're merged with the top 15 by CPU and deduplicated as before.
- A finding that names more than 5 processes, not all of them listed, gets `  Processes: N of M listed; Copy JSON for the full list` under its Limitations line. N is how many of the finding's processes actually appear in the list. That's usually 5, and more when some are also in the top 15 or in another finding's top 5, so the line never undercounts. The final "N other processes omitted" line is still computed from the real list.
- An argv over 300 characters in the text report (`textArgvLimit`) is cut to 300 with `… (+N chars)` added. JSON, `portsJSONReport`, the ports text and the app UI are unchanged.
- Measured on this Mac: `swift run heatlens scan --seconds 3 | wc -c` gave **6675 bytes**: 18 processes listed, one finding at "5 of 38".
## Files
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Tests/HeatLensCoreTests/RedactorTests.swift — modified
## Checks run
- `swift build`: passes.
- `swift test`: 124 tests in 24 suites pass, including the new "Text lists at most 5 of a finding's processes, busiest first, and cuts long argv; JSON keeps everything". It covers 21 affected processes (one unmeasured), the "5 of 21" line, no line under a small finding, the omitted count (21), a 400-character argv cut to 300 + "… (+100 chars)", and JSON keeping the full argv and all 42 processes.
- `scripts/run-app.sh --build-only`: builds HeatLens.app.
- Golden `docs/samples/report.txt` doesn't change: it has two processes and no finding over 5. `SampleReportTests` doesn't compare against it.
- Not checked: the ~300-process finding from the earlier measurement didn't come up in this live scan (the biggest finding named 38). The synthetic test covers the cap.
## Processes left running
none
## Questions for the user
none
## Notes for Jarvis
- No shared files touched.
- Suggested commit: `feat(core): text report lists at most 5 processes per finding and cuts argv over 300 chars (Phase 7c)`
