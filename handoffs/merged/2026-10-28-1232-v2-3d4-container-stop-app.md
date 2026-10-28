# v2 3d-4: app container stop: the switch, container detail, the confirmation, wording
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1530-v2-3d4-container-stop-app.md
## What the user asked
Build ADR-0007 §Build briefs "3d-4" in the app: the "Allow stopping a container" switch, a
container detail view reached from scan results, the confirmation sheet, the wording, and the
Docker-is-read-only doc lines. This finishes 3d. No questions were needed.
## What changed
- **Settings.** `containerStopEnabled` (key `containerStopEnabled`, default false) and
  `canStopContainers` (Docker on **and** the switch on). `ActionsSection` shows an indented
  "Allow stopping a container" toggle under Force Quit, only while "Docker containers" is on,
  with the ADR's caption. Turning Docker off hides the toggle and disables stopping, but keeps
  its value. The Docker caption's last sentence depends on the switch (decision 6).
  `CollectionOptions` is unchanged.
- **Services (`StopService.swift`).**
  - One `StopLedger` per app session, created in `AppDelegate`. `TerminatorStopService` now
    takes it in `init(ledger:forceQuitAllowed:)`, and `ContainerStopService` uses the same one.
  - `ContainerStopProviding` has `isEnabled` and `stopper()`. Both read Settings on the main
    actor when called.
  - `ContainerStopService.stopper()` builds `ContainerStopper(ledger:)` while the switch is on,
    else `DisabledContainerStopper(ledger:)`. While the switch is off, the type that can send a
    POST is never constructed.
  - `FixtureContainerStopService` and `FixtureContainerStopper` are for `-HeatLensFixtures` and
    previews. They apply the real `ContainerStopEligibility.evaluate` rules, never open a
    socket, and every eligible container "stops" after 0.5 s.
  - `ContainerSelection` holds the container, its `ContainerAttribution`, the Engine version,
    `isStopEnabled` and the stopper chosen when the detail opened. It builds the
    `ContainerStopTarget` with `init(container:project:exclusions:)` and the `ActionContext`
    (origin `.containerDetail`, project name, `confirmedAt`).
  - `ContainerStopWording` holds:
    - decision 2's sentence, with the signal and `t` from the preview;
    - the restart-policy line;
    - the Engine line;
    - a message for each of the 7 `ContainerStopOutcome` cases, including `.stillStopping`.
- **`ContainerDetailView`** (new) uses `ProcessDetailView`'s layout.
  - Detail grid: name, image, short ID, state and status, created, Compose project/service, CPU
    (with VM CPUs) and memory.
  - Project attribution, with the evidence source ("Compose working_dir label" and so on).
  - Actions: Copy ID (copies the full ID) and Open project. Then, depending on the stop state:
    - eligible: **Stop container…**;
    - `.excluded`: "Excluded in Settings";
    - `.denied(reason)`: no button, and "Stop unavailable: <reason>" under the buttons;
    - switch off: "Turn on 'Allow stopping a container' in Settings…" (it names "Docker
      containers" too if Docker is off).
- **`ContainerStopFlowView`** (new) is the sheet from `ResultsView`. It follows the
  `StopFlowView`/`ForceQuitFlowView` phase and guard structure:
  1. `checking`: runs the GET-only preview on open. Cancel works.
  2. `confirmation`: name, image, short ID, state and status, Compose project/service, project,
     Engine ("Docker Desktop · Engine 28.5.1, on this Mac"), the decision 2 text with
     `<StopSignal>` and `<T>`, and the restart-policy line if there is one. **Cancel** is the
     default; **Stop container** is destructive and has no shortcut.
  3. `stopping`: `interactiveDismissDisabled`, and a `guard case .confirmation` against a
     double click.
  4. `outcome`: the message, then Done and "Rescan to see the difference" (after `.stopped` or
     `.stillStopping`) or "Scan again". If the preview finds nothing can be sent (gone,
     identity changed, already stopped, denied), the sheet goes straight to an outcome titled
     "Can't stop this container".
- **Entry points.**
  - `DockerCard` rows become buttons with a trailing "Inspect", but only when an `onInspect`
    handler is passed. The badge drops "· read-only" when `canStop` is passed as true.
  - `ProjectsCard` container rows take the same optional `onInspectContainer`.
  - `ResultsView` passes both handlers.
  - `LiveView` passes neither (its `DockerCard` call now labels `onTurnOn:` explicitly), so
    Live rows stay plain and Live's badge still says read-only.
- **Fixture.** A running `desktop-extension-helper` container labelled
  `com.docker.desktop.extension.api.version`. Its detail shows the never-offered reason.
- **Docs.** In `README.md`'s Docker bullet and `docs/LIMITATIONS.md` item 12, Docker is now
  read-only "by default", and both name the switch. LIMITATIONS also says a `DOCKER_HOST` socket
  stays read-only. `site/` is untouched.

### One choice beyond the brief
`ContainerStopPlan`'s memberwise init is internal to HeatLensCore. That means the fixture
stopper can't return `.ready(plan)`, and this brief may not touch `Sources/`. So the app maps
the plan into its own `ContainerStopTerms` (same three fields), and the flow asks
`ContainerSelection.terms(exclusions:)`:
- For the real stopper and the disabled one, this calls `preview(_:)` and maps the result.
- Only `FixtureContainerStopper` is special-cased (`as?`), so fixture mode can show the
  confirmation.

**Follow-up for Jarvis:** a `public init` on `ContainerStopPlan` would remove the cast and the
copy type.
## Files
- App/SettingsModel.swift — modified
- App/SettingsView.swift — modified
- App/StopService.swift — modified
- App/ContainerDetailView.swift — created
- App/ContainerStopFlowView.swift — created
- App/HardwareViews.swift — modified
- App/LiveView.swift — modified
- App/ProjectViews.swift — modified
- App/ResultsView.swift — modified
- App/FixtureScanService.swift — modified
- App/HeatLensApp.swift — modified
- App/PopoverView.swift — modified
- README.md — modified (Docker bullet only)
- docs/LIMITATIONS.md — modified (item 12 only)
- handoffs/2026-10-28-1232-v2-3d4-container-stop-app.md — created
## Checks run
- `swift build`: Build complete. No `Sources/` or `Tests/` file changed.
- `scripts/run-app.sh --build-only`: built `HeatLens.app`.
- I touched every edited `App/` file and ran a non-quiet `xcodebuild`. It showed no Swift
  warnings or errors; the only warning is the existing appintents "Metadata extraction skipped".
- **Not run:**
  - `swift test`. No engine or test file changed. Jarvis runs the suite before merging.
- **Not checked by me:**
  - The UI itself: I didn't launch or click through the app.
  - A real container stop. Docker Desktop isn't running on this Mac (`docker version`: "Cannot
    connect to the Docker daemon"). The brief says not to start it, so no container was touched.
## Verification (the user's click-through)
1. `scripts/run-app.sh`. Settings → turn on **Docker containers**. Under Actions, **Allow
   stopping a container** appears, indented and off. Turn Docker off: it disappears. Turn Docker
   back on.
2. Start Docker Desktop. In Terminal:
   `docker run -d --rm --label heatlens.test=fixture alpine sleep 600`
3. **Scan now** → in the Docker card, click the alpine container (the row says "Inspect").
   - The detail shows its name, image, short ID, "running · Up …", and "Turn on 'Allow
     stopping a container' in Settings to stop it from here."
   - The badge says "Engine … · read-only".
4. Settings → turn on **Allow stopping a container**. The Docker caption now ends "…can stop a
   container you select, after a confirmation." Done → **Scan again** → the badge no longer
   says read-only.
5. Open the same container → **Stop container…**.
   - The sheet briefly shows "Checking the container with Docker…".
   - Then it names the container, image, ID, state, project and "Docker Desktop · Engine
     <version>, on this Mac". It says "Docker sends SIGTERM … after 10 s, force-kills it …".
   - **Cancel** is the default (Return cancels).
6. **Stop container**. The sheet waits; `sleep` as PID 1 ignores SIGTERM, so expect about 10 s.
   Then it says "Docker stopped <name>." → **Rescan to see the difference**. The container is
   gone, and `docker ps --filter label=heatlens.test=fixture` agrees.
7. If a Docker Desktop extension container is running, its detail shows "Stop unavailable: This
   container belongs to Docker Desktop itself…". In fixture mode (`-HeatLensFixtures YES`, Debug
   builds only), `desktop-extension-helper` shows the same line.
8. Excluded: add the container's name to "Excluded processes", rescan, and open it. It says
   "Excluded in Settings", with no button.
9. Live → **Show Docker containers**. The rows have no "Inspect" and aren't clickable.
10. A project drilldown (Projects card → disclosure) shows container rows with "Inspect" that
    open the same detail.

Only press Stop container on the throwaway container from step 2.
## Processes left running
none (`handoffs/bin/jarvis leftovers --mine`: nothing)
## Notes for Jarvis
- Shared files: none (`Sources/`, `Tests/`, `Package.swift`, `project.yml`, `site/` untouched).
- `TerminatorStopService.init` gained a `ledger:` parameter. `AppDelegate` is its only caller.
- Follow-up: make `ContainerStopPlan` have a `public init` (see "One choice beyond the brief").
- `handoffs/OPEN.md` and the brief file were already modified or untracked before I started. I
  didn't touch them.
- Suggested commit message:
  `feat(v2): Phase 3d-4 — container stop in the app: "Allow stopping a container" (off, Docker-only), container detail from scan results, docker-stop confirmation with signal/timeout from inspect, Live stays read-only`
