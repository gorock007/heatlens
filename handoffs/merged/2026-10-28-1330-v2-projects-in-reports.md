# v2: per-project totals (names only) in the copied report, the JSON export, the CLI and the MCP scan tool
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1240-v2-projects-in-reports.md
## What the user asked
Put the Phase 2b project breakdown (names, never paths) into the text and JSON reports, `heatlens scan` and the MCP `scan` tool. Mid-task addition: record the user's two answers under "Open decisions for the owner" in `docs/v2/PHASE-2-REPORT.md`.
## What changed
- **Text report**: a `Projects:` section right after the System line, one line per row in breakdown order, e.g. `- my-app: 2.1 cores (19%), 1.5 GB + 400 MB in Docker, 12 processes, 2 containers`. The percentage is the share of all cores (`snapshot.system.coreCount`; left out when that's 0). Process and container counts are left out when zero. At most 8 projects (`Redactor.textProjectLimit`), then `and N more projects; Copy JSON for the full list`; the Docker VM and Unattributed rows always follow. No rows → no section. It's separate from the process cap (`textProcessLimit`), so neither one truncates the other.
- **JSON report**: a `projects` array (always there, empty when there are no rows) with `name`, `kind` (project / dockerVM / unattributed), `cpuPercent` (**100 = one core**, host plus container CPU, the same as the card's figure and each process's `cpuPercent`; null when nothing had a figure), `memoryBytes`, `containerMemoryBytes`, `processCount`, `containerCount`, `basis` (git repository / package.json / user mapping / working directory…; null for Docker VM / Unattributed), `confidence`. There's no directory or root field. It lists every row, uncapped.
- **Names**: each goes through the existing `Sanitizer.text` (the username becomes `<user>`, credentials are redacted). Any `/` is then replaced with `-`, since a Settings mapping name may contain one, and the name is cut to 80 characters.
- Both `textReport` and `jsonReport` take `projects: ProjectBreakdown = .empty`, so old call sites still compile. The app passes `ScanReport.projects` (`ScanService.swift` init; `FixtureScanService` now builds its report through that init so fixtures carry projects too).
- **CLI/MCP**: `LiveScan.reports(_:)` computes `ProjectAttributor.breakdown(... docker: nil, mappings: [], locator: ProjectRootLocator())` and passes it to both reports. The MCP `scan` description says projects are included by name and that Docker containers and custom project folders are only in the app.
- **Docs**: `PHASE-2-REPORT.md` marks the "Projects aren't in the copied reports…" bullet done and records both answers (Keep history stays off by default, revisit in Phase 4 with background sampling; project names go into reports and MCP).
## Files
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Sources/HeatLensCLI/LiveScan.swift — modified
- Sources/HeatLensCLI/MCPServer.swift — modified (scan tool description only)
- App/ScanService.swift — modified
- App/FixtureScanService.swift — modified
- Tests/HeatLensCoreTests/RedactorTests.swift — modified (new suite "Redacted export: projects")
- Tests/HeatLensCLITests/CLITests.swift — modified (new suite "heatlens scan reports")
- docs/v2/PHASE-2-REPORT.md — modified
- handoffs/2026-10-28-1330-v2-projects-in-reports.md — created
## Checks run
- `swift build`: Build complete. One earlier attempt failed with `Rules/AlertPolicy.swift: 'TimelineEvent.Kind' has no member 'alertFired'`. That's the alert-policy worker's in-progress file, not this change; it built cleanly on the retry.
- `swift test --filter "Redactor|SampleReport|CLI|heatlens"`: 28 tests in 7 suites passed.
- Full `swift test`: 309 tests in 54 suites passed. I ran it directly with `scripts/with-timeout.sh 600`; `handoffs/jarvis.conf` defines no lock class.
- `scripts/run-app.sh --build-only`: built HeatLens.app.
- `swift run heatlens scan --seconds 2`: the Projects section comes right after System, with 8 project rows, an "and 5 more projects" line and an Unattributed row (no Docker VM row, since the CLI doesn't read Docker). No `/` in any project line. Real names aren't pasted here.
- CLI test: it uses a synthetic process whose cwd is this checkout, run through `LiveScan.reports`, instead of a real scan. No live CLI tests exist to gate it like. It checks the row is named after the checkout folder with basis "git repository".
- Not checked: the copied report from the running app (I didn't launch it). `samples/` doesn't exist, and `SampleReportTests` didn't change, so no fixtures were regenerated.
- To verify: `scripts/run-app.sh`, click Scan now, Copy report; the Projects lines should match the Projects card's names and CPU.
## Processes left running
none
## Notes for Jarvis
- No shared files touched (`ProjectBreakdown.swift` unchanged).
- Breakdown `notices` (e.g. "Docker's VM process wasn't found…") aren't in the reports. Easy to add to the Notices line if wanted.
- Projects using under about 0.05 cores render as `0.0 cores (0%)`.
- Suggested commit: `feat(v2): project totals by name in text/JSON reports, heatlens scan and MCP scan`
