# v2 Phase 4i: "Export incident…" in the app, plus the Redactor timing-test de-flake
status: partial  # click-through still open: screen was locked
agent: claude claude-sonnet-5-5
brief: handoffs/briefs/2026-10-28-1930-v2-p4i-incident-export-app.md

## What the user asked
Build brief 4i: an incident export sheet (preview, anonymise toggle, Markdown/JSON picker, Save… via
`NSSavePanel`) with entry points on explanations, the Live alert banner and the busiest moment; and
raise the Redactor timing test's bound to 3 s.

## What changed
- **`IncidentExportSheet`** (new): shows the redacted preview. It has a Markdown/JSON picker and a
  "Replace project names with Project A, B…" toggle. **Save…** opens an `NSSavePanel` with the
  default name `HeatLens incident yyyy-MM-dd HH.mm.md|json`. Colons are replaced by a dot in the
  time, as macOS file names dislike them. Nothing else writes: there's no clipboard and no
  automatic file, and cancelling returns without touching the disk. A failed write shows an inline
  error. Actions come from `ActionLog.shared.recent(includingSaved:retentionDays:)`. The request
  (`IncidentExportRequest`) is captured at the click. The 4d log call is a comment:
  `// 4d: HeatLensLog.notice(.export, format, anonymized)`.
- **Entry points:**
  - `ExplanationsCard` has an "Export…" button inside each explanation's disclosure. It is a
    plain secondary button, and the card stays action-free. The callback is optional.
  - The alert banner has an "Export…" link, which exports the newest alert.
  - The Timeline's busiest-moment summary has "Export this moment…". It uses the window on screen
    (session, 1 hour or 24 hours).
  - `LiveView` owns the sheet. The alert and explanation exports use the session timeline and the
    banner's recent alerts.
- **RedactorTests:** the "1,000 processes" bound goes from 1 s to 3 s, with a comment that it guards
  against the old multi-second regression. The test name still says "well under a second", because
  the brief said to change nothing else in that file.

## Files
- App/IncidentExportSheet.swift — created
- App/ExplanationsCard.swift — modified
- App/LiveView.swift — modified
- App/TimelineView.swift — modified
- Tests/HeatLensCoreTests/RedactorTests.swift — modified
- handoffs/2026-10-28-1930-v2-p4i-incident-export-app.md — created

## Checks run
- `swift build`: Build complete.
- `swift test --filter "IncidentReport|Redactor"`: 33 tests passed (the timing test took 0.43 s).
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`, with no
  warnings (I touched the new file and grepped the output).
- Full suite via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`: 401 tests in 61 suites passed.
- **Click-through attempted, blocked:** I launched the Debug app (it started, status item present), but the Mac's screen is locked (`CGSSessionScreenIsLocked` true; screenshots are black; System Events sees no windows). Nothing could be clicked, so no `yes` processes were started and nothing was exported. I quit the app I launched, by its PID. Nothing left running.
- **Not run:** the click-through, so  the Save panel, the grep for `PID [0-9]|$HOME`,
  the anonymised file and the cancel-writes-nothing check are all unverified.

## Steps for the click-through
1. `scripts/run-app.sh`. In Settings → Alerts, turn on "Alert me while Live is running", then Start live.
2. Start a few `yes > /dev/null &` yourself and fire a CPU alert. Stop exactly those PIDs afterwards.
3. In the banner, click Export…, choose Markdown and save into a scratch folder. Repeat as JSON with
   the toggle on.
4. `grep -nE "PID [0-9]|$HOME"` on both files should print nothing. The anonymised one should name
   no real project.
5. Click Export…, then Save… and Cancel in the panel. No file should appear.

## Processes left running
none

## Notes for Jarvis
- The sheet's `preview` is rebuilt on every body pass. The report is small, so this is fine, but
  it's a candidate if the sheet feels slow with a 24-hour window.
- Suggested commit: `feat(v2): Phase 4i — Export incident… sheet (Save panel only) from explanations, the alert banner and the busiest moment; relax the Redactor timing bound to 3 s`
- **The one real risk is still untested:** whether the menu-bar panel closes when `NSSavePanel` takes focus
  (that would dismiss the sheet and stop Live). If it does, fix it in `IncidentExportSheet.swift` (e.g.
  `beginSheetModal` on the sheet's window). I made no speculative change.
