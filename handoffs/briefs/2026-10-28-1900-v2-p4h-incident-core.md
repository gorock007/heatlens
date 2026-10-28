# v2 Phase 4h: Incident and the redacted incident reports (core)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 14:06 · terminal: 75572d94-30cc-4bd9-9c73-06d5549226ba

## Goal
Brief **4h** in `docs/v2/PHASE-4-PLAN.md` ("Incident export (4h, 4i)" design section and the
"4h · Core" brief, lines ~336–396), built as specified: `Export/IncidentReport.swift` with
`Incident`, `IncidentBuilder`, `IncidentExportOptions(anonymizeProjects:)`, and
`Redactor.incidentMarkdown` / `Redactor.incidentJSON`, plus `IncidentReportTests.swift` with the
FDA-shaped fixture and every assertion listed there.

## Context
- Owner decision 5 (2026-10-28, final): keep project/process/container names, explanation text,
  alerts, the ±2 min timeline and that window's action records; drop PIDs (also inside text),
  start times, `affected`, container IDs, short IDs, any 12- or 64-hex token, every path, argv,
  environment. Optional "Project A, B…" anonymising, consistent across Markdown and JSON.
  Save-panel only — but that's 4i (app); this brief has no UI.
- Read first: that PHASE-4-PLAN section; `Sources/HeatLensCore/Export/Redactor.swift`
  (`awakeTextReport`/`awakeJSONReport`, `Sanitizer`); `Sources/HeatLensCore/Model/Explanation.swift`;
  `Sources/HeatLensCore/Rules/AlertPolicy.swift` (`Alert`); `Sources/HeatLensCore/Safety/StopLedger.swift`
  (`ActionRecord`); `Sources/HeatLensCore/History/` (`HistoryWindow`); `TimelineAnalysis.Peak`.
- Patterns to copy: `RedactorTests`; `ConcurrencyRulesTests` for the explanation fixture.
- Fixture data must be synthetic (made-up home like `/Users/example`, made-up names). Public repo.

## Scope
- May touch: `Sources/HeatLensCore/Export/IncidentReport.swift` (new),
  `Tests/HeatLensCoreTests/IncidentReportTests.swift` (new),
  `Sources/HeatLensCore/Export/Redactor.swift` (only `private struct Sanitizer` → `struct Sanitizer`).
- Must not touch: `Model/`, `Live/`, `Rules/`, `App/`, `Package.swift`, `project.yml`, docs.
  Another worker is editing `Live/LiveMonitor.swift` and `Rules/AlertPolicy.swift` right now — read
  them, don't edit them. If you need a public init or accessor that doesn't exist, build around it
  and name it in Notes for Jarvis.

## Phase
One phase: 4h only. The app's "Export incident…" (4i) is a later brief.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `swift test --filter "IncidentReport|Redactor" 2>&1 | tail -30`, three runs in a row
  (the RedactorTests "1,000 processes … under a second" timing test is a known load flake; report
  it if it trips, don't change it).
- Full suite once, only via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`.

## Questions first
The design is decided. If the spec is genuinely contradictory, put it in one first handoff
(`status: blocked`) and stop; otherwise build straight through.
