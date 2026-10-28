# v2 Phase 4i: "Export incident…" in the app (Save panel), plus the Redactor timing-test flake
worker: claude
model: sonnet
effort: medium
started: 2026-10-28 14:26 · terminal: c43d2251-ba2a-4a2c-a780-bb842b6f5478

## Goal
Brief **4i** in `docs/v2/PHASE-4-PLAN.md` ("4i · App: Export incident…", ~lines 397–423), built as
specified: `App/IncidentExportSheet.swift` (read-only preview, "Replace project names with
Project A, B…" toggle, Markdown/JSON picker, **Save…** via `NSSavePanel`, default name
`HeatLens incident <date> <time>.md|json`; nothing else writes), with entry points on each
explanation (`ExplanationsCard`), the Live alert banner (`LiveView`), and the busiest moment
(`TimelineView`, "Export this moment…"). Plus one small extra: de-flake one timing test.

## Context
- The core is merged: `handoffs/merged/2026-10-28-1900-v2-p4h-incident-core.md` — read its
  "Notes for Jarvis → For 4i" (how to call `IncidentBuilder.incident(from:…)`,
  `Redactor.incidentMarkdown/incidentJSON`, `Redactor.incidentLeftOut`).
- Owner decision 5: Save panel only — no clipboard, no automatic file; cancelling writes nothing.
- **Deviation from the plan:** `HeatLensLog` (4d) doesn't exist yet. Skip the log line; leave a
  `// 4d: HeatLensLog.notice(.export, format, anonymized)` comment where it goes.
- Actions: `ActionLog.shared.recent(includingSaved:retentionDays:)` (see `App/ActionLogSection.swift`
  for how it's called). Timeline: the session's or saved range's `HistoryWindow` (see how
  `TimelineView.swift` loads its window).
- Pattern to copy: `App/ContainerStopFlowView.swift` for the sheet structure. This is the app's
  first `NSSavePanel`; keep it inside the sheet file.
- The ExplanationsCard stays action-free: "Export…" is a plain secondary button/menu, not a
  stop/action button.

## Scope
- May touch: `App/IncidentExportSheet.swift` (new), `App/ExplanationsCard.swift`,
  `App/LiveView.swift`, `App/TimelineView.swift`, and (extra item only)
  `Tests/HeatLensCoreTests/RedactorTests.swift`.
- Must not touch: `Sources/`, other tests, `Package.swift`, `project.yml`, docs. Another worker
  (4a) is editing `Sources/HeatLensCore/Live/` and `Rules/AlertPolicy.swift`; if `LiveTick` gains
  fields mid-run, just rebuild.
- **Extra item:** in `RedactorTests.swift`, the test "Both reports for 1,000 processes with long
  argv take well under a second" fails under heavy load (1.1–2.1 s seen; 0.4–0.5 s idle). Raise its
  bound to 3 seconds and say in a comment that it guards against the old multi-second regression
  (uncompiled patterns), not a tight budget. Change nothing else in that file.

## Phase
One phase: 4i plus the extra item.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `swift test --filter "IncidentReport|Redactor" 2>&1 | tail -20`
- `scripts/run-app.sh --build-only 2>&1 | tail -20` — no new warnings.
- Click-through (`scripts/run-app.sh`): Settings → Alerts → "Alert me while Live is running" on;
  Start Live; fire a CPU alert with a few `yes > /dev/null` processes you start yourself (stop
  exactly those PIDs afterwards, by PID; no pkill/killall). Export from the banner as Markdown,
  then as JSON with anonymising on, saving into your scratch folder. `grep -nE "PID [0-9]|$HOME"`
  on both prints nothing; the anonymised one names no real project; cancelling the Save panel
  writes nothing. Driving tip from docs/CLICKTHROUGH.md: a CoreGraphics click on the status icon +
  System Events works where cua.getApp times out. Keep the exported files and any screenshots in
  scratch only — never commit them (public repo); in the handoff report pass/fail and counts, not
  file contents. If you can't drive the app, say so and list the steps for the user.

## Questions first
None expected. If one comes up, one first handoff (`status: blocked`) and stop.
