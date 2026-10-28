# v2 3d-3: core container stop: POST on UnixSocketHTTP, inspect, ContainerStopper, socket policy
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1500-v2-3d3-container-stop-core.md
## What the user asked
Build ADR-0007 §Build briefs "3d-3": the one POST on the socket client, inspect by full ID,
`ContainerStopper` with the socket policy, and ADR §Tests 1–12 (12 is live and env-gated).
Engine only, no UI.
## What changed
- **`UnixSocketHTTP`** has a `Method` enum (`get`, `post`). `request(method: = .get, path:)` writes
  `POST … Content-Length: 0` only for a path matching `isAllowedStopPath`
  (`^/v1\.\d{1,3}/containers/[0-9a-f]{64}/stop\?t=\d{1,3}$`). `post(path:socketPath:timeout:)`
  refuses every other path with `.invalidPath` before `connect`. `get` and the other signatures
  are unchanged; existing `request(path:)` calls still compile. The header comment now says "GET,
  and POST to one container-stop path only".
- **`DockerEngine.swift`**:
  - `DockerEndpoint.inspect(api:id:)` and `.stop(api:id:timeout:)`; `t` is clamped to 0…120.
  - `DockerContainerID.isFull` (64 characters). `path` stays a `String`, so existing callers
    are unchanged. A `.stop` built from a short ID gives a path that `isAllowedStopPath` refuses,
    and test 1 pins that.
  - `DockerTransport.post(_:timeout:)`.
  - `DockerContainerInspect` decodes only decision 3's fields. `createdSeconds` drops the
    nanoseconds and compares at whole seconds.
  - `DockerSocketLocator.stopPolicy(for:environment:home:lstat:realpath:currentUser:)`
    implements decision 4 with injected `lstat`/`realpath`. It refuses:
    - a path that came from `DOCKER_HOST`;
    - any path other than the two Docker Desktop paths;
    - a symlink that resolves anywhere else (`/private/var/run/docker.sock` and the realpath of
      the home socket count as the same place);
    - a socket that isn't owned by the current user (root included).

    `StopRefusal.reason` holds the ADR's two UI sentences.
- **`ContainerStopper.swift`** (new):
  - `ContainerStopping` protocol, `ContainerStopper` actor, `DisabledContainerStopper`.
  - `ContainerStopOutcome` with the brief's seven cases, plus `caseName` for the record.
  - `ContainerStopTarget`, `ContainerStopEligibility` with the rules as data
    (`neverOffered: [Rule]` holds the label-key, name and image prefixes).
  - The sequence: `/version` → inspect by full ID (404 → `.gone`) → `Id`/`Name`/`Created` must
    match (else `.identityChanged`) → `State.Status == running` (else `.alreadyStopped`) →
    eligibility again, on the inspect's labels → exactly one POST, with a deadline of `t + 5` s.
    Responses: 204 → `.stopped`, 304 → `.alreadyStopped`, 404 → `.gone`, else `.failed` with the
    Engine's message, redacted and capped at 200 characters. On the deadline: re-list, no retry.
  - Socket I/O runs on a dispatch queue, off the actor. That keeps the actor free, so a second
    `stop` really does see the in-flight flag and gets `.denied`.
  - Every attempt is recorded in the `StopLedger` (`action: .containerStop`), sent or refused.
    The disabled stopper records its refusals too.

## Choices beyond the ADR's wording (tell the 3d-4 builder)
1. **`preview(_:)` on the protocol** (GET only, not recorded) returns `.ready(ContainerStopPlan)`
   (`stopSignal`, `timeoutSeconds`, `restartPolicy`) or `.unavailable(outcome)`. Decision 2's
   confirmation must state `<StopSignal>`, `<T>` and the restart policy. Those come only from
   inspect, and 3d-4 may not touch `Sources/`, so without this it couldn't show them. 3d-4
   should call `preview` when the sheet opens. `stop` inspects again anyway.
2. **`stop(_:context:)`** takes the same optional `ActionContext` as 3d-1 (origin
   `.containerDetail`, `confirmedAt`, project name). An extension provides `stop(_:)` for nil.
   3d-4 should pass a context.
3. **`ContainerStopTarget` has three more fields than the brief lists:**
   - `image`: the audit record's `Target.container` needs it.
   - `projectDirectory`, `exclusions`: needed to re-check the exclusions at call time
     (decision 5).

   `init(container:project:exclusions:)` builds the target from a scan's `ContainerSample`.
   The directory is never recorded.
4. **`ContainerStopEligibility` has an `.excluded` case** next to `.eligible` and
   `.denied(reason:)`, so 3d-4 can show "Excluded in Settings" as `ProcessDetailView` does. At
   call time an exclusion becomes `.denied("This container is excluded in Settings, so nothing
   was sent.")`. If the socket policy refused, `ContainerStopper.eligibility` returns its reason,
   but only for a container that would otherwise be eligible.
5. **Deadline outcome.** After the deadline, the re-list decides: still listed as running →
   `.stillStopping`; listed as not running, or absent → `.stopped`, because it really has
   stopped. Either way it's one POST.
6. **A negative `StopTimeout`** (the container asked never to be force-killed) → `t=120`, the
   cap. The ADR rejects `t=-1`.
7. **Redaction** uses `ActionRecord.redacted`/`cap`, as 3d-1 did, because `Redactor.text` still
   doesn't exist. Same follow-up as 3d-1.
8. **The `DOCKER_HOST` check compares paths.** It refuses only when `DOCKER_HOST`'s unix path is
   the socket the reads use. If that socket is missing, `locate` falls back to Docker Desktop's
   socket for both reads and stops, so a stop still can't cross engines.

## Files
- Sources/HeatLensCore/Docker/UnixSocketHTTP.swift — modified
- Sources/HeatLensCore/Docker/DockerEngine.swift — modified
- Sources/HeatLensCore/Docker/ContainerStopper.swift — created
- Tests/HeatLensCoreTests/ContainerStopTests.swift — created
- Tests/HeatLensCoreTests/Fixtures/ContainerStopFixtures.swift — created
- Tests/HeatLensCoreTests/DockerEngineTests.swift — modified (FakeTransport gets a `post` that
  records an issue; the GET-only test now covers "GET, plus POST to the stop path only";
  the endpoint test covers inspect and stop)
- handoffs/2026-10-28-1225-v2-3d3-container-stop-core.md — created
## Checks run
- `swift build`: Build complete, no warnings. `swift build --build-tests`: no warnings in the
  touched files.
- `for i in 1 2 3; do scripts/with-timeout.sh 600 swift test --filter "ContainerStop|DockerEngine"; done`:
  34 tests in 2 suites passed, three runs in a row (about 1.8 s each). Tests 1–11 pass and
  test 12 is skipped.
- A mutation check, reverted afterwards: with the `Id` comparison disabled, test 2's Id case
  fails; with the in-flight flag disabled, test 10 fails (two POSTs).
- `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test`: 356 tests
  in 58 suites passed. The Redactor timing test didn't flake.
- `scripts/run-app.sh --build-only`: built `HeatLens.app` with no warnings or errors. No `App/`
  file changed.
- `grep -rn '"POST ' Sources/` prints one line: `Sources/HeatLensCore/Docker/UnixSocketHTTP.swift:55`.
  `grep -rn "ContainerStopper\|containerStop" Sources/HeatLensCLI Sources/heatlens` prints
  nothing. Test 11 pins both. It covers every non-Core target, `heatlens-probe` included, and
  also checks for `ContainerStopping`, `DisabledContainerStopper` and `.post(`.
- All existing Docker tests pass.
- **Test 12 was not run.** Docker Desktop isn't running on this Mac (`docker version`: "Cannot
  connect to the Docker daemon"), and the brief says not to start it, so there is no Engine
  version to record. It is skipped by default (`HEATLENS_LIVE_CONTAINER_STOP=1` plus the socket
  enable it). To run it once with Docker Desktop up:
  `HEATLENS_LIVE_CONTAINER_STOP=1 scripts/with-timeout.sh 600 swift test --filter "ContainerStopTests/liveStop"`.
  It starts `docker run -d --rm --label heatlens.test=fixture alpine sleep 300` and stops that
  container through `ContainerStopper` only. `sleep` as PID 1 ignores SIGTERM, so expect about
  10 s while the Engine waits out `t` and force-kills it. If the container is still there, a
  `defer` removes it, by its own ID only. `alpine` isn't pulled yet, so the first run pulls it.
  Check `docker ps --filter label=heatlens.test=fixture` before and after.
- Network traffic in the tests: only to `EngineStub` sockets the tests create under
  `NSTemporaryDirectory()`. No real Docker call was made.
## Processes left running
none (`handoffs/bin/jarvis leftovers --mine`: nothing)
## Notes for Jarvis
- No shared files touched (`Model/`, `Safety/`, `Package.swift`, `App/`, docs: unchanged).
- `DockerTransport` now requires `post`. The live sampler's `UnixSocketTransport` has it but never
  calls it, and the sampler's FakeTransport records an issue if it's ever called. The stopper
  builds its own transport instance from the policy-checked socket path.
- Suggested commit message:
  `feat(v2): Phase 3d-3 — ContainerStopper: inspect-by-ID then one POST /containers/{id}/stop, Docker Desktop–only socket policy, one "POST " site`
