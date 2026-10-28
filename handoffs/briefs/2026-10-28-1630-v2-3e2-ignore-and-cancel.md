# v2 3e-2: "Ignore this process / project" buttons, and log ignores and cancelled confirmations
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 12:50 · terminal: b242bbc9-59cc-45a1-b3d3-81eaa4a068af

## Goal
This finishes PRD-v2 Phase 3e: "allow 'ignore this process/project'", and the "suggested" half of the audit trail. The types already exist (`handoffs/merged/2026-10-28-1600-v2-3e1-action-log.md`, "3e-2 notes"):
- `ActionRecord.Action.ignored` / `.cancelled`
- the `offered:` field
- `Target.project(name:)`
- origins `findingCard` and `projectRow`
- the one ledger `ActionLog.shared.ledger`
- `ActionLogLine` wording

**Done when** `swift build` and `scripts/run-app.sh --build-only` pass with no new warnings in the touched files, and:
1. **Ignore this process.** In process detail (`App/ProcessDetailView.swift`), add an **Ignore this process** button next to the existing actions, and on finding cards (`App/FindingCard.swift`) where a process is named. It adds the process's name to Settings' excluded processes (`settings.excludedProcesses`, one name per line). Don't add it twice; compare case-insensitively, as `ExclusionFilter.excludes` does. After that the process shows "Excluded in Settings", as today. Hide the button when the process is already excluded.
2. **Ignore this project.** On a project row in the Projects card (`App/ProjectViews.swift`) and in process detail's project section, add **Ignore this project**. It adds the project's directory to Settings' excluded projects (`settings.excludedProjects`), written with `~` for the home directory, matching the existing guidance text in `App/SettingsView.swift` ("~/Projects/demo hides its children"). Don't add it twice.
   - Projects only. Not Unattributed, not the Docker VM row, and not in Live (Live stays read-only).
   - Hide it when the project is already excluded.
3. **No confirmation dialog** (it's reversible). Show a short inline note instead: "Ignored. Remove it in Settings → Exclusions to undo." The scan results update their hidden-by-exclusions note on the next scan, as today.
4. **Log every ignore** to `ActionLog.shared.ledger`:
   - `action: .ignored`, `outcome: "ignored"`
   - target `.process(pid:startTimeMicros:name:)` for a process, or `.project(name:)` for a project: **name only, never the directory**
   - origin `.processDetail`, `.findingCard` or `.projectRow`
   - `confirmedAt` = the click time
5. **Log cancelled confirmations** as `action: .cancelled`, `offered: <the action>`, `outcome: "cancelled"`, `signalSentAt: nil`:
   - the SIGTERM confirmation in `StopFlowView` (`App/ResultsView.swift`)
   - `ForceQuitFlowView`
   - `ContainerStopFlowView` (`App/ContainerStopFlowView.swift`)
   - the batch sheet's Cancel before anything was sent (`App/BatchStopFlowView.swift`): one record per selected process, origin `.batchStop`

   Count only an explicit **Cancel** (or Escape / dismissing the sheet) at the confirmation step, not a Done after an outcome. A flow that sent something and then closes is not a cancel.
6. Check the Settings "Recent actions" list in fixture mode or by reading the code: it already formats these ("Ignored · project my-app", "Cancelled force quit · … · nothing sent").

## Context
- Read first:
  - the 3e-1 handoff above
  - `App/HistoryService.swift` (`ActionLog`)
  - `App/ActionLogSection.swift` (`ActionLogLine`)
  - `Sources/HeatLensCore/Safety/StopLedger.swift` (`ActionRecord` init and caps)
  - `App/SettingsModel.swift` (`excludedProcesses`, `excludedProjects`)
  - `Sources/HeatLensCore/Rules/ExclusionFilter.swift`
  - `App/ProcessDetailView.swift`, `App/FindingCard.swift`, `App/ProjectViews.swift`, `App/ResultsView.swift` (`StopFlowView`, `ForceQuitFlowView`), `App/BatchStopFlowView.swift`, `App/ContainerStopFlowView.swift`
- Rulings:
  - Exclusion also suppresses stop (v1).
  - Live has no ignore or stop controls.
  - Names, not paths, in the log.
  - The log is saved only while Keep history is on; `ActionLog` already handles that.

## Scope
- May touch: `App/ProcessDetailView.swift`, `App/FindingCard.swift`, `App/ProjectViews.swift`, `App/ResultsView.swift`, `App/BatchStopFlowView.swift`, `App/ContainerStopFlowView.swift`, `App/ContainerDetailView.swift` (only if a container needs "Ignore this project"; optional), `App/SettingsModel.swift` (small helpers like `ignoreProcess(_:)`/`ignoreProject(_:)`), `docs/v2/PLAN.md` (mark 3e done)
- Must not touch: `Sources/`, `Tests/`, `App/LiveView.swift`, `App/HistoryService.swift`, `App/ActionLogSection.swift`, `Package.swift`, `project.yml`, `site/`. If a `Sources/` change is truly needed, ask in a blocked handoff.

## Phase
3e-2 only. This finishes Phase 3's build items.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
scripts/run-app.sh --build-only 2>&1 | tail -20
```
Give the user a click-through in the handoff. Ignore a process, then check Settings → excluded processes and Recent actions. Ignore a project, likewise. Cancel a Request stop and check that Recent actions shows "Cancelled stop … nothing sent".

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
