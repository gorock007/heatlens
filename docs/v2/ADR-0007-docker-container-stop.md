# ADR-0007: Stop one explicitly selected container with `POST /containers/{id}/stop`, re-inspected by ID, behind its own switch

- **Status:** Accepted for Phase 3 (2026-10-28; owner rulings of the same day in
  `handoffs/2026-10-28-1150-v2-3d-safe-actions-design.md`)
- **Context:** PRD-v2 §6 Phase 3 ("Docker cleanup must be restricted to explicitly selected
  containers, never blanket prune. No automatic termination by default."), §8 ("Docker socket can
  effectively grant host-level control"; "no shell injection through … container IDs");
  ADR-0002 (GET-only client, path allowlist, socket discovery; its "Revisit when" names this
  ADR); the Docker Engine API v1.51 spec (`/containers/{id}/stop`, `/containers/{id}/json`) and
  the Engine's `daemon/stop.go`, both read for this decision.

This is the first non-GET request HeatLens makes to the Docker Engine. ADR-0002's "there is no
other verb in the code" becomes "there is exactly one other request, to one path, that one type
can build". Everything else in ADR-0002 stands.

## Decision

1. **The call is `docker stop`, exactly.** `POST /v1.<n>/containers/<id>/stop?t=<T>` with an
   empty body. `<id>` is the container's **full 64-hex ID** (the Engine also resolves name and
   ID prefixes; HeatLens never sends either). `T` is the container's own `Config.StopTimeout`
   from the inspect call in decision 3, or **10** when it is null (the Engine's default), capped
   at 120. No `signal` parameter: the container's `StopSignal` applies (SIGTERM unless the image
   sets another). The Engine sends that signal and, if the container is still running after `T`
   seconds, SIGKILL (`daemon/stop.go`: "sends a stop signal, waits, sends a kill signal"). This
   escalation happens inside the Engine, so HeatLens has no second "force" step for containers:
   the one confirmation says it in words (decision 2). HeatLens never calls `kill`, `restart`,
   `pause`, `rm`, `prune`, `update` or `exec`, and never anything on `/images`, `/volumes`,
   `/networks` or `/system`.
   - Responses (API v1.51): **204** stopped; **304** "container already stopped" (nothing was
     sent); **404** "no such container" (gone between the list and the call); **500** server
     error (message shown, truncated to 200 characters and passed through `Redactor.text`).
   - The request's own deadline is **T + 5 s** (so 15 s by default), on a transport instance
     separate from the 2 s sampling one. If the deadline passes, the outcome is `.stillStopping`:
     "Docker is still stopping it", and HeatLens re-lists the containers. In current Engines the
     stop continues after the client disconnects (`stop.go` wraps the request in
     `context.WithoutCancel`: "Cancelling the request should not cancel the stop"); older Engines
     (before 25.0) may stop waiting as well, but the stop signal has already been delivered either
     way, and the next read shows the true state.
2. **Exactly one container, chosen in the UI, with a confirmation that names it.** The action
   lives in a new container detail view, reached from a scan result's Docker card row or a
   Projects drilldown container row. There is no multi-select, no "stop all of project X", no
   Compose-level stop, and no stop from Live (owner ruling 4, the same as processes). The
   confirmation (`ContainerStopFlowView`) shows: name, image, short ID, state and uptime
   ("Up 3 days"), Compose project and service if any, the attributed project, and the Engine
   ("Docker Desktop 28.5.1 on this Mac"). Its text:
   *"Docker sends `<StopSignal>` to the container's main process and, if it is still running
   after `<T>` s, force-kills it (the same as `docker stop`). Data the container hasn't written
   yet can be lost. It stays stopped until something starts it again (`docker start`, `docker
   compose up`); other containers in the same Compose project keep running."*
   Buttons: **Cancel** (default) and **Stop container** (destructive). A double-click guard and
   `interactiveDismissDisabled` while in flight, as in `StopFlowView`.
3. **Re-validation by ID right before the call** (the analogue of pid + start time):
   `GET /v1.<n>/containers/<id>/json`, then compare `Id` to the selected 64-hex ID, `Name`
   (minus the leading `/`) to the listed name, and `Created` (RFC 3339 with nanoseconds in
   inspect; Unix seconds in the list) to the listed `createdAt` at second precision. Any
   mismatch → `.identityChanged`, nothing is sent. `State.Status` must be `running`, otherwise
   `.alreadyStopped` with no call. The inspect also supplies `Config.StopTimeout`,
   `Config.StopSignal`, `Config.Labels` (exclusions are re-checked on these, not on the list's
   labels) and `HostConfig.RestartPolicy` (shown as a line: "restart policy: always; it stays
   stopped after an explicit stop"). Container IDs are 256-bit random values, so ID reuse is not
   a practical threat; a container *name* is reused every `docker compose down && up`, which is
   why nothing is ever addressed by name.
4. **Socket policy for a stop is stricter than for reads.**
   - A stop is sent only through a socket the locator found at `$HOME/.docker/run/docker.sock`
     or `/var/run/docker.sock`. A path that came from `DOCKER_HOST=unix://…` stays read-only
     until Colima, OrbStack or Podman have been tested (ADR-0002 "Revisit when"); the button then
     reads "Stopping is only supported through Docker Desktop's socket for now".
   - The path is `lstat`ed; a symlink is resolved with `realpath`, and the target must again be
     one of the two paths above (Docker Desktop's `/var/run/docker.sock` is a symlink to the home
     one, which is fine). A symlink elsewhere → refused.
   - The resolved socket must be **owned by the current user** (reads also accept root, ADR-0002
     item 3). A root-owned socket means a system daemon HeatLens hasn't tested; refused with
     "HeatLens only stops containers through a Docker socket you own".
   - `DOCKER_HOST` with `tcp://`, `ssh://` or anything but `unix://` is ignored, as today. There
     is no TCP code path. Docker *contexts* (`~/.docker/contexts`, `currentContext` in
     `~/.docker/config.json`) are not read: HeatLens addresses the local Engine it lists from,
     whatever the `docker` CLI's current context is, and says which Engine in the confirmation.
     IDs come from that same Engine's list, so a stop can't cross engines.
5. **Never offered** (the button is absent, with the reason under it):
   - a container that isn't `running`;
   - Docker Desktop's own containers: any label key starting with `com.docker.desktop.` or
     `io.docker.desktop.` (extensions carry `com.docker.desktop.extension`), Dev Environments
     (`com.docker.dev-environments.`), Kubernetes pods (label prefix `io.kubernetes.`, or name
     prefix `k8s_`), buildx builders (name prefix `buildx_buildkit_` or image starting with
     `moby/buildkit`);
   - a container whose attributed project directory, or Compose `working_dir`, matches an
     "Excluded projects" prefix in Settings, or whose name equals a line in "Excluded processes"
     (case-insensitive). The ruling "exclusion also suppresses stop" applies to containers; 3e's
     per-item ignore adds a one-click way to do it.
   The rules are data in a pure `ContainerStopEligibility` and are re-evaluated on the inspect
   response before the call, so a label added since the scan still protects the container.
6. **Rollout: Docker on, plus its own switch, both off by default.** Settings → "Docker
   containers" (existing) → indented "Allow stopping a container" (`UserDefaults` key
   `containerStopEnabled`, default false), shown only while Docker is on. While it is off, the
   type that can send a POST is never constructed; the Docker card badge keeps saying
   "read-only". When it is on, the badge drops "read-only" and the Settings caption says
   "…and can stop a container you select, after a confirmation." Turning Docker off hides the
   switch and disables stopping without resetting the switch.
7. **Nothing else may use it.** The CLI and the MCP server never link `ContainerStopper`
   (a test greps for it). Live shows containers but passes no inspect or stop handler. There is
   no "stop" in any MCP tool, report action or deep link.
8. **One stop at a time.** `ContainerStopper` is an actor with an in-flight flag; a second
   request while one runs is `.denied("another container is being stopped")`. Every attempt,
   executed or refused, is recorded in the `StopLedger` (ADR-0006 §Audit record) with
   `action: .containerStop`.

## Options considered

| Option | Against |
|---|---|
| Two steps like processes: `POST /containers/{id}/kill?signal=SIGTERM`, then a separate confirmation for `stop?t=0` | Puts the `kill` endpoint, whose *default* signal is SIGKILL, into the codebase, and invents a flow no Docker user expects. `docker stop` is already "graceful, then force after a stated timeout", and the owner chose it (ruling 3). |
| `stop` without `t` | Identical behaviour, but HeatLens wouldn't know the bound for its own wait or be able to state it in the confirmation. Reading `StopTimeout` from the inspect HeatLens makes anyway costs nothing. |
| `stop?t=-1` (wait forever, no SIGKILL) | Blocks the Engine's request indefinitely for a container that ignores SIGTERM; the user gets no result. |
| The `docker` CLI (`docker stop <id>`) as a child process | ADR-0002's reasons, plus it honours the user's current context, which could be a remote engine. |
| Stopping a Compose project (`docker compose stop`) or several selected containers | PRD-v2: "explicitly selected containers, never blanket". One container per confirmation keeps the identity check per target; a project-wide stop would be a batch flow with its own ADR. |
| Also `rm` after stop, or `prune` | Destroys state; out of scope for ever under this PRD. |
| Stop from Live's Docker card | Ruling 4: Live rows change under the pointer; stops come from a scan result. |
| Allow stops over a `DOCKER_HOST` socket | Untested runtimes own their sockets differently (Colima runs its daemon as the user, Podman machines vary). Reads are harmless; a stop deserves a tested path first. |

## Security review

**Threats and what stops them**

| # | Threat | Mitigation | Proof |
|---|---|---|---|
| 1 | Path injection through an ID, name or label | Only `DockerContainerID` (hex, now 64 chars for a stop) and an `Int` reach the path; `UnixSocketHTTP.isAllowedPath` still refuses spaces, CR, LF and non-ASCII; no string from the UI or from labels is ever interpolated | Request-builder test; fuzz of the allowed character set |
| 2 | A second verb or path creeping in | One `Method` enum with `.get` and `.post`; `post` accepts only a path matching `^/v1\.\d{1,3}/containers/[0-9a-f]{64}/stop\?t=\d{1,3}$`; no body, no custom headers | Test: every other path, a 12-char ID, a negative or non-numeric `t`, and `/containers/<id>/kill` are refused before connect |
| 3 | Wrong container: name reused by Compose, or the list is stale | Addressed by full ID; inspect compares `Id`, `Name`, `Created` right before the call | Tests with a mocked Engine (`TestSocketServer`) for each mismatch → no POST in the request log |
| 4 | Container already gone or stopped | 304 / 404 handled as outcomes, nothing sent; `State.Status != running` → no call | Tests for 304, 404 and a non-running inspect |
| 5 | Infra or excluded container | Pure eligibility on inspect-time labels, names and project; evaluated twice (offer and call) | Tests per rule; label added between list and inspect → `.denied` |
| 6 | Wrong engine: remote `DOCKER_HOST`, a context pointing at a server, a planted socket | Unix socket only; stop only through the two Docker Desktop paths after `realpath`; user-owned; `DOCKER_HOST` sockets read-only | Locator tests: env socket, root-owned, other-owned, symlink to `/tmp/x.sock` all refused |
| 7 | The Engine escalates to SIGKILL (data loss inside the container) | That is `docker stop`; the confirmation states the signal, the timeout and the loss risk; Cancel is default | Click-through |
| 8 | HeatLens's wait expires while the Engine is still stopping | `.stillStopping` outcome, re-list, no retry, no second POST | Test: a server that answers after the deadline → one request only |
| 9 | Reachable from Live, CLI or MCP | No handler passed from Live; a grep test over the CLI targets | `grep -rn "ContainerStopper\|containerStop" Sources/HeatLensCLI Sources/heatlens` is empty |
| 10 | Switch off but a code path still POSTs | `DisabledContainerStopper` has no transport; the POST type isn't constructed | Test: with the switch off the request log stays empty for a stop attempt |
| 11 | The response is huge or malformed | ADR-0002's 4 MB cap, `JSONDecoder` into fixed types; inspect decodes only the fields in decision 3 | Existing parser tests apply; one new fixture for inspect |
| 12 | Double dispatch | Flow phase guard plus the actor's in-flight flag | Test for the flag; code review for the guard |

**What the socket grants, restated.** The Docker socket is root on the VM and, through bind
mounts, the user's files. This ADR adds one write capability, "stop this running container",
to a client that still cannot create, start, exec into, remove or mount anything. Nothing in
HeatLens can turn a stop into a different request: the path is built from an enum case, the
method from another, and the test suite pins both.

**Privacy.** The audit record carries the short ID, container name, image, Compose project
name and project name. Not the bind-mount paths, not `working_dir`, not labels in full.

**Residual risk.** The window between the inspect and the POST is the same shape as pid reuse,
with a 256-bit ID instead of a 16-bit pid; a container recreated with the same name in that
window has a different ID and is not touched. A stop of a database container mid-write loses
what the database hadn't flushed; that is what the user confirms.

## Evidence

- Docker Engine API v1.51 spec (`docs.docker.com/reference/api/engine/version/v1.51.yaml`):
  `POST /containers/{id}/stop` takes `signal` (string) and `t` (integer, "Number of seconds to
  wait before killing the container"); responses 204 "no error", 304 "container already
  stopped", 404 "no such container", 500. `POST /containers/{id}/kill` defaults `signal` to
  `SIGKILL` (why it is not used). `GET /containers/{id}/json` returns `Id`, `Name`, `Created`
  (RFC 3339 with nanoseconds), `State.Status`, `State.StartedAt`, `Config.StopTimeout`
  (nullable integer, "If omitted, the daemon-wide default is used"), `Config.StopSignal`,
  `Config.Labels`, `HostConfig.RestartPolicy`.
- `moby/moby` `daemon/stop.go` (read 2026-10-28): `ContainerStop` returns `NotModified` (304)
  for a non-running container; `containerStop` uses `context.WithoutCancel`, sends the stop
  signal, waits `StopTimeout` (the container's `Config.StopTimeout` if set, else the daemon
  default), then `daemon.kill`. A negative timeout means never kill.
- ADR-0002 evidence: Docker Desktop 28.5.1, API 1.51, socket `~/.docker/run/docker.sock` owned
  by the user, `/var/run/docker.sock` a symlink to it.

## Tests (what proves it is safe)

Unit tests run against `TestSocketServer` from `DockerEngineTests.swift`, which logs every
request line, so "nothing was sent" is an assertion on the log, not an absence of errors.

1. Request builder: the only POST HeatLens can form is the stop path; 64-hex ID required; `t`
   in 0…120; any other path or verb throws before `connect`.
2. Inspect mismatch, each separately: different `Id`, different `Name`, `Created` off by one
   second → `.identityChanged`, no POST.
3. Inspect says not running → `.alreadyStopped`, no POST. Inspect 404 → `.gone`, no POST.
4. Stop responses: 204 → `.stopped`; 304 → `.alreadyStopped`; 404 → `.gone`; 500 → `.failed`
   with a redacted, capped message.
5. `t` comes from `Config.StopTimeout` (fixture 25 → `t=25`), null → `t=10`, 600 → `t=120`.
6. Deadline: a server that sleeps past `T + 5` → `.stillStopping`, exactly one POST, and a
   following list call is made.
7. Eligibility (pure): each infra rule, each exclusion rule, not running; a label that appears
   only in the inspect response still denies.
8. Socket policy: `DOCKER_HOST` unix socket → stop refused, reads fine; root-owned, other-owned,
   symlink to an unexpected target → refused; the two Docker Desktop paths → allowed.
9. Switch off: `DisabledContainerStopper` leaves the request log empty.
10. In-flight flag: a second stop while one is blocked → `.denied`, one POST.
11. CLI/MCP grep test (threat 9) and a grep that `UnixSocketHTTP` has exactly one `"POST "`
    literal.
12. Live test on this Mac, **skipped unless `HEATLENS_LIVE_CONTAINER_STOP=1` and the socket
    exists**: the test starts its own fixture container through the `docker` CLI
    (`docker run -d --rm --label heatlens.test=fixture alpine sleep 300`), stops it through
    `ContainerStopper` only, asserts it is gone from the list, and removes it in a `defer` if it
    is still there. The test never touches a container it didn't start, and the app code under
    test never runs the CLI.

## Revisit when

- Colima, OrbStack or Podman are tested: extend the stop socket allowlist per runtime, with
  the ownership rule re-checked for each.
- Phase 3e adds per-container ignore and persists the ledger.
- A batch "stop these leftovers' containers" is wanted: a new ADR, modelled on 10b's batch,
  one inspect-then-stop per container, never a project-wide call.
- Docker Desktop changes its infra labels: the rules are data; add a fixture and a test.

## Build briefs

Two briefs, after ADR-0006's. Each ends green on
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build && swift test`
and `scripts/run-app.sh --build-only`. Neither makes a Docker call outside test 12, and test 12
is off unless the env flag is set.

### 3d-3 · Core: POST on the socket client, inspect, `ContainerStopper`, socket policy (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Docker/UnixSocketHTTP.swift`: a `Method` enum (`get`, `post`);
    `request(method:path:)` writes `POST … Content-Length: 0`; `post(path:socketPath:timeout:)`
    accepts only a path matching the regex in threat 2 (a static `isAllowedStopPath`); keep
    `get` and every existing signature unchanged. Update the header comment ("no way to send any
    verb but GET" → "GET, and POST to one container-stop path").
  - `Sources/HeatLensCore/Docker/DockerEngine.swift`: `DockerEndpoint.inspect(api:id:)` and
    `.stop(api:id:timeout:)`; `DockerContainerID` gains `isFull` (64 chars) and `.stop` requires
    it; `DockerTransport` gains `post(_:timeout:)`; `DockerContainerInspect: Decodable` with
    `Id`, `Name`, `Created` (String), `State.Status`, `State.StartedAt`, `Config.StopTimeout`,
    `Config.StopSignal`, `Config.Labels`, `HostConfig.RestartPolicy.Name`;
    `DockerSocketLocator.stopPolicy(for path:…) -> Result<String, StopRefusal>` implementing
    decision 4 (inject `lstat`/`realpath` like `locate` injects `stat`).
  - `Sources/HeatLensCore/Docker/ContainerStopper.swift` (new): `public protocol ContainerStopping`
    (`eligibility(of: ContainerSample, project: Project?, exclusions: ExclusionFilter) ->
    ContainerStopEligibility`, `stop(_ target: ContainerStopTarget) async -> ContainerStopOutcome`);
    `public actor ContainerStopper: ContainerStopping` (transport, ledger, in-flight flag,
    decisions 1, 3, 5, 8); `public struct DisabledContainerStopper` (never opens the socket);
    `public enum ContainerStopOutcome` (`stopped`, `stillStopping`, `alreadyStopped`, `gone`,
    `identityChanged`, `denied(reason:)`, `failed(message:)`); `public struct ContainerStopTarget`
    (`containerID`, `name`, `createdAt`, `composeProject`, `projectName`); pure
    `ContainerStopEligibility` rules as data (label prefixes, name prefixes, image prefixes).
  - Tests: `Tests/HeatLensCoreTests/ContainerStopTests.swift` (new), tests 1–12 of §Tests, with
    inspect and stop fixtures under `Tests/HeatLensCoreTests/Fixtures/`. Extend the existing
    "Requests are GET only" test in `DockerEngineTests.swift` to "GET, plus POST to the stop
    path only".
- **Pattern to copy:** `DockerEngineSampler.reading()` for the version negotiation and
  decoding; `DockerSocketLocator.locate` for injectable file status; `TestSocketServer` and
  `PathLog` in `DockerEngineTests.swift` for request logging; `ProcessTerminator.requestStop`
  for the shape of "validate, last check, one call, outcome".
- **Done when:** tests 1–11 pass three runs in a row; test 12 is skipped by default and passes
  once with `HEATLENS_LIVE_CONTAINER_STOP=1` on a Mac with Docker Desktop running (record the
  Engine version in the handoff); `grep -rn '"POST ' Sources/` prints one line in
  `UnixSocketHTTP.swift`; `grep -rn "ContainerStopper\|containerStop" Sources/HeatLensCLI
  Sources/heatlens` prints nothing; every existing Docker test passes.
- **May touch:** `Sources/HeatLensCore/Docker/UnixSocketHTTP.swift`,
  `Sources/HeatLensCore/Docker/DockerEngine.swift`,
  `Sources/HeatLensCore/Docker/ContainerStopper.swift` (new),
  `Tests/HeatLensCoreTests/ContainerStopTests.swift` (new),
  `Tests/HeatLensCoreTests/DockerEngineTests.swift`, `Tests/HeatLensCoreTests/Fixtures/`.
- **Must not touch:** `Model/ContainerSample.swift` (the target struct lives in the new file),
  `Safety/` except reading `StopLedger`'s API, `App/`, CLI targets, `Package.swift`, docs.

### 3d-4 · App: the switch, container detail, the confirmation, wording (claude, opus, medium)

- **Do:**
  - `App/SettingsModel.swift`: `containerStopEnabled` (key `containerStopEnabled`, default
    false); `CollectionOptions` is unchanged (sampling stays read-only). `App/SettingsView.swift`:
    in `MonitoringSourcesSection`, under the Docker toggle and only when `dockerEnabled`, an
    indented toggle "Allow stopping a container" with the caption "Adds a Stop button to a
    container's detail in scan results. Docker stops it the way `docker stop` does: a stop
    signal, then force after the container's timeout. Off: HeatLens only reads from Docker."
    The Docker caption's last sentence becomes conditional (decision 6).
  - `App/StopService.swift`: `ContainerStopService` wrapping `ContainerStopper` (built from the
    locator's path and the ledger shared with `TerminatorStopService`) or
    `DisabledContainerStopper` when the switch is off, chosen at call time from settings;
    `FixtureContainerStopService` for previews; `ContainerStopWording`.
  - `App/ContainerDetailView.swift` (new): the `ProcessDetailView` layout for a container:
    detail grid (name, image, short ID, state and status, created, Compose project/service,
    CPU and memory), the project section with the attribution evidence source, actions (Copy
    ID, Open project, "Stop container…" or the eligibility reason / "Excluded in Settings" /
    "Turn on 'Allow stopping a container' in Settings").
  - `App/ContainerStopFlowView.swift` (new): decision 2's confirmation, in-flight and result
    phases, `.sheet(item:)` from `ResultsView`; "Rescan to see the difference" on success.
  - `App/HardwareViews.swift` (`DockerCard`): rows become buttons when an `onInspect` handler
    is passed; the badge text drops "read-only" when the switch is on. `App/LiveView.swift`
    passes no handler (Live rows stay plain). `App/ProjectViews.swift`: container rows in a
    project drilldown take the same optional handler. `App/ResultsView.swift`: a
    `selectedContainer` state like `selectedProcess`, and the sheet.
  - `App/FixtureScanService.swift`: give one fixture container a Docker Desktop label so the
    preview shows the "never offered" line.
- **Pattern to copy:** `ProcessDetailView` and its action section (p2d's "Excluded in
  Settings" branch); `StopFlowView` phases; the `onInspect` buttons in the Ports/Awake rows and
  Live's Top rows (3a fixes); the `dockerEnabled` toggle.
- **Done when:** `scripts/run-app.sh --build-only` builds with no new warnings. Verification:
  `scripts/run-app.sh`; Settings → Docker containers on → "Allow stopping a container" appears,
  off; Scan now → click a container in the Docker card → detail shows "Turn on … in Settings";
  turn it on; rescan; the detail shows **Stop container…**; for a Docker Desktop extension
  container (if any) the line says why it is never offered; start a throwaway
  `docker run -d --rm alpine sleep 600` in Terminal, rescan, open it → Stop container… → the
  confirmation names it, Cancel is default → Stop container → "stopped" → rescan: gone, and
  `docker ps` agrees. Live → Show Docker containers: rows are not clickable.
- **May touch:** `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/StopService.swift`,
  `App/ContainerDetailView.swift` (new), `App/ContainerStopFlowView.swift` (new),
  `App/HardwareViews.swift`, `App/LiveView.swift`, `App/ProjectViews.swift`,
  `App/ResultsView.swift`, `App/FixtureScanService.swift`, `App/HeatLensApp.swift`,
  `App/PopoverView.swift` (passing the service).
- **Must not touch:** `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs (Jarvis updates
  the README, LIMITATIONS and site lines that say Docker is read-only; the list is in the 3d
  handoff).
