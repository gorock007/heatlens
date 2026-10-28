# v2 Phase 3d (design): ADRs and a security review for force quit and for stopping one selected Docker container
worker: claude
model: fable
effort: high
started: 2026-10-28 11:48 · terminal: 21ca30ac-68bf-4a54-9738-a7635c8d8b8a

## Goal
PRD-v2 Phase 3 (`docs/PRD-v2.md` ~lines 98–107) adds two actions that v1 deliberately left out:
- "optional force quit only after separate confirmation", after the graceful SIGTERM flow
- "Docker cleanup must be restricted to explicitly selected containers, never blanket prune. No automatic termination by default."

`docs/v2/PLAN.md` says both need new ADRs and a security review **before** any code. This phase writes them. **No source code changes.**

**Done when** these three docs exist and the handoff lists the build briefs Jarvis should write next:
1. `docs/v2/ADR-0006-force-quit.md`
2. `docs/v2/ADR-0007-docker-container-stop.md`
3. a security review section in each ADR, or `docs/v2/SECURITY-REVIEW-3d.md`

## What each ADR must decide (match the shape of ADR-0002 and ADR-0005)
- **Force quit (SIGKILL):**
  - **When it's offered:** only after a graceful stop was sent and the process is still alive after the wait, and only for a process that passed v1 eligibility.
  - **Re-checks before the signal:** re-validate PID + start time immediately before the signal (FR-09; see `Sources/HeatLensCore/Safety/ProcessTerminator.swift` and the v1 review `handoffs/merged/2026-10-26-1935-p2c-security-review-safe-stop.md`).
  - **Confirmation:** a *separate* confirmation, with the wording that warns about data loss.
  - **Scope:**
    - batch stop (`BatchStop.swift`, the 10b leftover flow): force quit per process, never "force quit all"
    - never from Live (3a-fixes ruling)
    - what the CLI/MCP may do: nothing, since they stay read-only
  - **Timing:** a timeout or cooldown between SIGTERM and offering SIGKILL.
  - **Groups:** what happens to child processes and process groups (signal the PID only, or `killpg`?), with the reasoning.
  - **Tests:** what proves it is safe, including PID reuse, the process exiting between the check and the signal, a root-owned process, and a denylisted or Apple process.
- **Container stop:**
  - **The call:** the first non-GET call to the Docker Engine API. `POST /containers/{id}/stop` with a timeout? Never `kill`, `rm` or `prune`?
  - **Selection:** how a container is chosen. Exactly one, selected explicitly in the UI, with its name, image, project and uptime shown in the confirmation.
  - **Re-validation:** re-read the container by ID and compare its created time / name before the call, the container analogue of PID + start time.
  - **Attack surface:**
    - which socket paths are allowed (ADR-0002's discovery)
    - refusing a socket that isn't owned by the user, or is a symlink to somewhere unexpected
    - what happens with a remote `DOCKER_HOST` (refuse?)
    - Docker contexts
  - **Exclusions:** Compose projects; containers the user excluded; anything labelled as infra (e.g. Docker Desktop's own containers) is never offered.
  - **Rollout:** behind Docker being enabled, plus its own Settings switch? Decide, keeping the plan's "new behaviour off by default" rule.
  - **Audit hook:** each executed or refused action must be recordable by 3e (a local audit trail of suggested and executed actions). Define the record's fields here (no argv, no paths beyond project name) so 3e can build it.
- **Each ADR ends with:**
  - "Options considered"
  - "Build briefs": one brief per phase, each with exact files, the pattern to copy, done + its proving command, and may/must-not-touch, so Jarvis can paste them into briefs

## Context
- Read first:
  - `docs/PRD-v2.md` (§Phase 3, §8 security/privacy if present)
  - `docs/v2/PLAN.md`
  - `docs/v2/ADR-0002-docker-adapter.md`
  - `docs/v2/ADR-0005-history-store.md` (format)
  - `Sources/HeatLensCore/Safety/ProcessTerminator.swift`, `Sources/HeatLensCore/Safety/BatchStop.swift`
  - `Sources/HeatLensCore/Docker/DockerEngine.swift`, `Sources/HeatLensCore/Docker/UnixSocketHTTP.swift`
  - `App/StopService.swift`, `App/BatchStopFlowView.swift`
  - the v1 safety reviews in `handoffs/merged/2026-10-26-1935-p2c-security-review-safe-stop.md` and `handoffs/merged/2026-10-26-1944-p2d-security-fixes.md`
- Rulings in force:
  - Explain + propose typed actions only; no free-form command execution.
  - The CLI/MCP are read-only.
  - Exclusion also suppresses stop.
  - No automatic termination.
  - New behaviour defaults to off.
  - Live doesn't stop processes.
- If the design shows a product decision the user must make (e.g. "should container stop exist at all in the first release?"), put it as a question in a `status: blocked` first handoff, with your recommendation.

## Scope
- May touch: `docs/v2/ADR-0006-force-quit.md` (new), `docs/v2/ADR-0007-docker-container-stop.md` (new), `docs/v2/SECURITY-REVIEW-3d.md` (new, optional), `docs/v2/PLAN.md` (link the ADRs under Phase 3 only)
- Must not touch: `Sources/`, `App/`, `Tests/`, `Package.swift`, `project.yml`, every other doc
- Don't send any signal or make any Docker call to probe behaviour. Reading code and docs only. If you need a fact from the Docker API docs, cite it.

## Phase
Design only. The builds are later briefs, written from your "Build briefs" sections.

## Checks
- `git diff --stat` shows only the docs above (other workers may have changes in the tree; list only yours).
- `grep -nE "/Users/|gorock" docs/v2/ADR-0006-force-quit.md docs/v2/ADR-0007-docker-container-stop.md` prints nothing.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
