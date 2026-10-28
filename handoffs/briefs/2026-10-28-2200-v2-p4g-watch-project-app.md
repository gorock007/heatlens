# v2 Phase 4g: "Watch this project…" in the app
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 15:18 · terminal: b117c873-e342-4f3d-b73f-d1e829720f3a

## Goal
Brief **4g** in `docs/v2/PHASE-4-PLAN.md` ("4g · App: Watch this project…", ~lines 312–335), built as
specified: a "Watch this project…" / "Edit watch…" row menu item in Live's and scan results'
Projects cards; `App/ProjectWatchSheet.swift` (name, folder as `~/…`, three pickers Off/presets,
Save/Cancel, "Alerts are off" + **Turn on alerts**); `projectWatches` in `SettingsModel` included in
`alertConfiguration`; a "Watched projects" list with Remove in `AlertSettingsSection`; the watch
notification identifier and body in `LiveAlertService`.

## Done when
- `swift build` and `scripts/run-app.sh --build-only` succeed with no new warnings; full suite passes
  once under the lock.
- Click-through (plan's 4g steps): watch this checkout at CPU 100 %; from the checkout folder start
  two `yes > /dev/null &` jobs (your own fixtures, stopped by PID); within ~2.5 min a notification
  names the project, once with the panel open and once closed with Background on; remove the watch in
  Settings → no further alert. Handoff records pass/fail per step (or "screen locked" + steps).

## Context
- Core merged: `handoffs/merged/2026-10-28-2000-v2-p4f-watchlists-core.md` — read its "For 4g" notes:
  read with `ProjectWatch.parse(UserDefaults…data(forKey: "projectWatches"))` and show its `notice`;
  write with `ProjectWatch.encoded(_:)`; pickers from `ProjectWatch.choices(metric)` + `describe`;
  identifier `dev.heatlens.live-alert.watch.<metric>.<projectHash>` from `alert.watch`.
- App side of background watching merged: `handoffs/merged/2026-10-28-2100-v2-p4c-keep-watching-app.md`
  (how `LiveAlertService` now subscribes `.summary` and posts from `.alerts`; alert settings reach the
  monitor via `setAlerts`, no restart; its driving notes: detach the panel with a CoreGraphics drag
  first; Escape cancels panels).
- Owner decision 6 (final): presets only, alert-only, from a Projects-card row. A watch is a setting,
  so it's allowed in read-only Live (no action buttons).
- Patterns: `ContainerDetailView`'s sheet layout; the `projectMappingsText` setting; the "Ignore this
  project" menu item in `ProjectViews`.
- Restore any settings you change for the click-through (`defaults delete` only keys you added).

## Scope
- May touch: `App/ProjectViews.swift`, `App/ProjectWatchSheet.swift` (new), `App/SettingsModel.swift`,
  `App/AlertSettingsSection.swift`, `App/LiveAlertService.swift`.
- Must not touch: `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs, and the App files another
  worker (4d) is editing now: `App/HistoryService.swift`, `App/IncidentExportSheet.swift`,
  `App/SettingsView.swift`. If you truly need SettingsView, name the exact line in Notes instead.

## Phase
One phase: 4g.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/run-app.sh --build-only 2>&1 | tail -20`
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`
- The click-through above (`scripts/run-app.sh`). Screenshots/notes in scratch only; no real paths or
  names in the handoff (public repo).

## Questions first
None expected. Genuine contradictions only: one blocked handoff, then stop.
