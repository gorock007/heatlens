# Security review, Phase 3d: force quit and container stop, before any code

- **Scope:** the two actions decided in [ADR-0006](ADR-0006-force-quit.md) (SIGKILL after a
  failed stop request) and [ADR-0007](ADR-0007-docker-container-stop.md) (stop one selected
  container). Each ADR carries its own threat table; this page holds what is common to both,
  the trust boundaries they move, and the proving-test matrix Jarvis checks before merging the
  build briefs.
- **Method:** reading, not probing. The v1 engine (`ProcessTerminator`, `BatchStop`), the Docker
  client (`DockerEngine`, `UnixSocketHTTP`), the app's stop flows, the v1 reviews (p2c, p2d), the
  Docker Engine API v1.51 spec and `moby/moby` `daemon/stop.go`. No signal was sent and no
  Docker call was made for this review.

## 1. What changes in the trust model

| Boundary | v1 / v2 so far | After 3d |
|---|---|---|
| Strongest signal HeatLens can send | SIGTERM, one per confirmed request | SIGKILL, one per *second* confirmation, only with a recorded SIGTERM to the same identity 5–60 s earlier, only with a Settings switch on |
| Docker Engine | GET to four paths | Plus `GET /containers/{64-hex}/json` and `POST /containers/{64-hex}/stop?t=N`, only with a second Settings switch on, only through a user-owned Docker Desktop socket |
| Who can trigger an action | The user, in a scan result's sheets | Unchanged: scan results only. Live, CLI and MCP gain nothing |
| Automatic behaviour | None | None. Neither action runs without two clicks in a modal flow |
| Defaults | Stop requests on; Docker off | Both new actions off; a default install behaves exactly as v2 does today |

## 2. Shared invariants (every brief must keep these)

1. **No action without a fresh identity check.** Process: pid + start time read from the
   kernel twice around the eligibility check and once more before `kill`. Container: inspect by
   full ID and compare `Id`, `Name`, `Created` before the POST.
2. **One request per decision.** One `kill(2)` per `forceQuit`; one POST per container stop;
   no retry loop anywhere; a timeout is reported, never retried.
3. **No fan-out.** No `killpg`, no children, no "all", no Compose-level stop, no multi-select.
4. **The path to the dangerous call is a type, not a string.** `SIGKILL` appears once in
   `Sources/`; `"POST "` appears once; request paths come from `DockerEndpoint` cases built from
   validated IDs and an `Int`.
5. **Off means absent.** With a switch off, the UI shows no control *and* the service refuses
   *and* (for Docker) the type that can POST is not constructed.
6. **Exclusion suppresses stop**, for containers as for processes (p2d ruling).
7. **Every attempt is recorded**, executed or refused, in the `StopLedger` with the fields in
   ADR-0006 §Audit record. The record has no argv, no environment, no paths.
8. **Tests signal only fixtures the test started**: ad-hoc-signed copies of `/bin/sleep` and
   `/bin/bash`, or a container the test ran itself under an env flag. Never a process or
   container the app found.

## 3. Cross-cutting threats

| # | Threat | Where handled | Residual |
|---|---|---|---|
| A | Stale UI state fires at the wrong target (a sheet left open, a second window) | Ledger expiry (60 s) for processes; inspect-then-POST for containers; both re-validate identity at call time | Microseconds between the last check and the call; the same window v1 documented |
| B | Another local process flips a switch in `UserDefaults` | Not a new boundary: it already has the user's rights (`kill -9`, the Docker socket). The switches protect against HeatLens's own UI and defaults | — |
| C | A confused user confirms the wrong thing | Both confirmations name the target (name, PID or short ID, project, uptime, image), make Cancel the default, give the destructive button no shortcut, and state the loss in plain words | User decision, by design |
| D | Secrets or paths leak through the new records or messages | Records carry names only; Engine error messages are capped at 200 chars and pass through `Redactor.text`; the `/bin/` and script-name rules from p2d still apply to anything shown from a process | — |
| E | Feature reachable through the MCP server by an agent | The MCP target doesn't link `forceQuit` or `ContainerStopper`; a grep test pins it. PRD-v2 §8: never expose the socket to a plugin or untrusted local process | — |
| F | A Docker runtime HeatLens hasn't tested | Stops allowed only through the two Docker Desktop paths, user-owned, `realpath`-checked; `DOCKER_HOST` sockets stay read-only | Users of Colima/OrbStack can't stop containers until tested (stated in the UI) |
| G | The Engine's own SIGKILL after `t` | Stated in the confirmation, with `t` read from the container itself; that *is* `docker stop` | Data not flushed inside the container |
| H | Test tooling kills the wrong thing | `FixtureChild` ends only its own `(pid, startTime)`; the container test runs its own fixture under an env flag and removes only that container; `scripts/with-timeout.sh` bounds the runs | — |

## 4. Proving-test matrix

Jarvis runs these once, through the lock, before merging each brief. "Pinned" means a test
asserts it, not a comment.

| Invariant | Brief | Test |
|---|---|---|
| One `SIGKILL` site, no `killpg` | 3d-1 | source grep test in `ForceQuitTests` |
| SIGKILL needs a recorded SIGTERM, 5 s grace, 60 s expiry | 3d-1 | `ForceQuitTests` 6, 7 |
| Impostor identity, exited target, root, denylisted → nothing sent | 3d-1 | `ForceQuitTests` 2–5 |
| `BatchStop` never escalates | 3d-1 | `BatchStopTests` (always-stillRunning stopper) |
| Switch off → `.denied`, engine not called | 3d-2 | code read of `TerminatorStopService` (no App test target); click-through |
| Live, CLI, MCP have no force quit | 3d-2 / 3d-1 | grep test over CLI targets; `LiveNoStopService` code read |
| One `"POST "` literal; POST only to the stop path regex | 3d-3 | `ContainerStopTests` 1, 11 |
| Inspect mismatch → no POST (Id, Name, Created, not running, 404) | 3d-3 | `ContainerStopTests` 2–3 against the request log |
| `t` from `StopTimeout`, default 10, cap 120 | 3d-3 | `ContainerStopTests` 5 |
| Deadline → one POST, `.stillStopping`, re-list | 3d-3 | `ContainerStopTests` 6 |
| Infra labels, exclusions, inspect-time labels | 3d-3 | `ContainerStopTests` 7 |
| Socket policy: `DOCKER_HOST`, root-owned, other-owned, symlink elsewhere refused | 3d-3 | `ContainerStopTests` 8 |
| Switch off → no socket opened | 3d-3 | `ContainerStopTests` 9 |
| CLI/MCP don't link the stopper | 3d-3 | `ContainerStopTests` 11 |
| Live rows not clickable; badge and captions truthful per switch | 3d-4 | click-through in the brief |

## 5. Documentation that becomes untrue when the switches exist

These lines say HeatLens never force-quits or that Docker is read-only without qualification.
They are outside this brief's scope; Jarvis updates them with the build briefs (the exact list
with line numbers is in the 3d handoff). The wording to use: "by default" plus the switch name.

## 6. Verdict

No finding blocks the design. Both actions keep v1's safety shape (consent, fresh identity,
one signal, denylist) and add a second gate (the Settings switch) and a second confirmation.
The two residuals, the microsecond race and the Engine's own escalation, are stated to the
user in the confirmation text and documented here.
