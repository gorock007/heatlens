# v2 3d-4: app container stop: the switch, container detail, the confirmation, wording
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-28 12:27 · terminal: bfaad00f-2148-423d-8842-5da58899322c

## Goal
Build exactly what `docs/v2/ADR-0007-docker-container-stop.md` §Build briefs **"3d-4"** specifies: its Do, its pattern to copy, its done condition / verification and its may/must-not-touch lists. Read the whole ADR first, because decisions 2 and 5 hold the confirmation wording and the never-offered rules.

The engine is done (`handoffs/merged/2026-10-28-1225-v2-3d3-container-stop-core.md`). Read that handoff's **"Choices beyond the ADR's wording"** and use them:
- Call `ContainerStopping.preview(_:)` when the confirmation opens. It is GET only, and it supplies the stop signal, `t` and the restart policy the confirmation must state.
- Pass an `ActionContext` to `stop(_:context:)`: origin `.containerDetail`, `confirmedAt`, project name.
- Build targets with `ContainerStopTarget(container:project:exclusions:)` from the scan's `ContainerSample`.
- Show `ContainerStopEligibility.excluded` as "Excluded in Settings", following `ProcessDetailView`'s wording.
- Handle every `ContainerStopOutcome` case, including `.stillStopping`.
- When the setting is off, use `DisabledContainerStopper`.

**Also follow the force-quit app pattern just merged** (`handoffs/merged/2026-10-28-1225-v2-3d2-force-quit-app.md`): the `ActionsSection` in `App/SettingsView.swift`, where "Allow stopping a container" belongs, shown only when "Docker containers" is on; and the `ForceQuitFlowView` phase/guard structure for `ContainerStopFlowView`.

**Done when:** `swift build` and `scripts/run-app.sh --build-only` pass with no new warnings in the touched files, and the handoff holds the ADR's verification steps as the user's click-through. If Docker Desktop is running, you may drive the verification yourself, but **only** against a throwaway container you start (`docker run -d --rm --label heatlens.test=fixture alpine sleep 600`). Never press Stop container on any other container: the user's FDA containers may be running. If Docker isn't running, don't start it; just build.

## Context
- User rulings (2026-10-28):
  - Container stop sits behind "Allow stopping a container" (off by default; shown only when Docker is on).
  - It is exactly `docker stop`.
  - **From scan results only, never Live**: Live's Docker card rows and Live process detail get no stop control.
  - Compose containers stay stoppable, and the confirmation says other services keep running and that `compose up` recreates the container.

## Scope
- May touch: the ADR's list: `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/StopService.swift`, `App/ContainerDetailView.swift` (new), `App/ContainerStopFlowView.swift` (new), `App/HardwareViews.swift`, `App/LiveView.swift` (only to make sure Live offers nothing), `App/ProjectViews.swift`, `App/ResultsView.swift`, `App/FixtureScanService.swift`, `App/HeatLensApp.swift`, `App/PopoverView.swift`. Plus these docs, **only** their Docker-is-read-only lines: `README.md` (lines saying HeatLens only reads Docker / never changes containers) and `docs/LIMITATIONS.md` item 12 (~line 29). Make them say "by default", and name the switch.
- Must not touch: `Sources/`, `Tests/`, `Package.swift`, `project.yml`, `site/` (it describes the released 1.2.2)

## Phase
3d-4 only. This finishes 3d.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
scripts/run-app.sh --build-only 2>&1 | tail -20
```

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
