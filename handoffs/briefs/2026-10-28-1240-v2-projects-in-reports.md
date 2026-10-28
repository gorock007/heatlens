# v2: per-project totals (names only) in the copied report, the JSON export, the CLI and the MCP scan tool
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 11:36 · terminal: d8f4d913-2965-40cd-99b5-4d71d32fd6d7

## Goal
User ruling (2026-10-28): project **names** go into the copied report and the MCP output. Today the report only has each group's redacted project *directory* (`Redactor.swift` ~line 44), and the per-project breakdown from Phase 2b (`ProjectBreakdown`, what the Projects card shows) is missing from reports, the CLI and MCP (`docs/v2/PHASE-2-REPORT.md`, "Projects aren't in the copied reports or the CLI/MCP output yet").

**Done when** `swift build`, `swift test` (filtered and full) and `scripts/run-app.sh --build-only` pass, and:
1. **Text report** (`Redactor.textReport`) gains a `Projects` section after the System line. It has one line per project row, in breakdown order, at most 8 rows plus "and N more":
   - `- my-app: 2.1 cores (35%), 1.4 GB, 12 processes, 2 containers`
   - the Docker VM row and Unattributed as their own lines, when present
   - names only: the project's name (the folder's last component, as the Projects card shows it), never a path
   - when there are no projects, the section is omitted
2. **JSON report** (`Redactor.jsonReport`) gains a `projects` array with the same rows as fields: `name`, `kind` (project / dockerVM / unattributed), `cpuPercent` or cores (use whatever the breakdown has, and say which), `memoryBytes`, `processCount`, `containerCount`, `basis` (how it was attributed: git, mapping, compose…, as text). No `directory` field.
3. Both take the breakdown as a new parameter with a default of `nil`/`.empty`, so old call sites still compile. The app passes the scan's `ScanReport.projects` wherever the text/JSON report is built (find where `reportText`/`reportJSON` are made, in `App/ScanService.swift` or `App/PipelineScanService.swift`).
4. **CLI and MCP:** `Sources/HeatLensCLI/LiveScan.swift` computes `ProjectAttributor.breakdown(snapshot:groups:docker: nil, mappings: [], locator: ProjectRootLocator())`, following the app's call in `App/PipelineScanService.swift:22`, and passes it to both reports. That makes `heatlens scan` and the MCP `scan` tool carry projects. The CLI doesn't read Docker or the app's "Project folders" mappings (it's read-only and has its own defaults). Say so in one line of the MCP `scan` tool description in `MCPServer.swift`, e.g. "Projects come from Git roots; Docker containers and custom project folders are only in the app."
5. **Report cap:** the text report has a size cap (Phase 7c; see `Redactor.textProcessLimit` and the CLI tests). The Projects section must fit inside the existing cap logic and not be the first thing truncated.
6. **Tests:**
   - `RedactorTests`:
     - a breakdown with 2 projects + Docker VM + Unattributed renders the expected lines and JSON fields
     - **no `/` in any project line or JSON project field**, including when a project folder is under the home directory
     - more than 8 projects → "and N more"
     - an empty breakdown → no section
   - `CLITests`: `scan` output has a Projects section when run inside this checkout (it's a Git repo). Gate it like the existing live CLI tests, if they're gated.
   - Update any sample-report fixtures that change (`SampleReportTests`, `samples/`). Regenerate them only through the existing script or test path, and list them in the handoff.

## Context
- Read first: `Sources/HeatLensCore/Export/Redactor.swift` (textReport ~14, makeReport ~309, jsonReport ~135, the `Sanitizer`), `Sources/HeatLensCore/Projects/ProjectBreakdown.swift` (`ProjectUsage`, rows, the Docker VM and Unattributed rows), `Sources/HeatLensCore/Projects/ProjectAttributor.swift`, `Sources/HeatLensCLI/LiveScan.swift`, `Sources/HeatLensCLI/MCPServer.swift`, `App/PipelineScanService.swift`, `App/ScanService.swift`, `App/ProjectViews.swift` (how the card names and formats a row: match its wording).
- Rulings:
  - Names, not paths.
  - The CLI and MCP stay read-only.
  - Reports are redacted: run every name through the existing sanitizer, since a folder name could contain a user name.
  - No history data goes in reports (ADR-0005).

## Scope
- May touch: `Sources/HeatLensCore/Export/Redactor.swift`, `Sources/HeatLensCLI/LiveScan.swift`, `Sources/HeatLensCLI/MCPServer.swift` (the scan tool description only), `App/PipelineScanService.swift`, `App/ScanService.swift`, `App/FixtureScanService.swift`, `Tests/HeatLensCoreTests/RedactorTests.swift`, `Tests/HeatLensCoreTests/SampleReportTests.swift`, `Tests/HeatLensCLITests/CLITests.swift`, `samples/` (regenerated fixtures only), `docs/v2/PHASE-2-REPORT.md` (change the "Projects aren't in the copied reports…" bullet to say it's done)
- Must not touch: `Sources/HeatLensCore/Live/`, `Sources/HeatLensCore/Rules/`, `Sources/HeatLensCore/History/`, `App/LiveView.swift`, `App/SettingsView.swift`, `App/SettingsModel.swift`, `App/LiveModel.swift`, `App/HeatLensApp.swift` (another worker is building alert policies in those), `Package.swift`, `project.yml`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Projects/ProjectBreakdown.swift`, only if a small accessor is truly needed

## Phase
This phase only: projects in reports, CLI and MCP.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
scripts/with-timeout.sh 600 swift test --filter "Redactor|SampleReport|CLI" 2>&1 | tail -30
scripts/with-timeout.sh 600 swift test 2>&1 | tail -15
scripts/run-app.sh --build-only 2>&1 | tail -20
swift run heatlens scan --seconds 2 2>&1 | sed -n '1,25p' | sed -E 's#/Users/[^ ]+#<path>#g'
```
Don't paste real project names from this Mac into the handoff: describe them ("4 project rows").

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
