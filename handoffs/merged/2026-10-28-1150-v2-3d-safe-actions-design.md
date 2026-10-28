# v2 Phase 3d (design): ADR-0006 force quit, ADR-0007 container stop, security review
status: done
agent: claude claude-fable-5-1
brief: handoffs/briefs/2026-10-28-1400-v2-3d-safe-actions-design.md
## What the user asked
Write the ADRs for the two Phase 3 actions v1 left out (force quit after a separate
confirmation; stopping one selected Docker container, the first non-GET Engine call), each with
a security review and the build briefs Jarvis writes next. No source changes.
## What changed
Three new docs under `docs/v2/`, and two lines in PLAN.md linking them. No code.
- **ADR-0006 (force quit).** SIGKILL exists in exactly one place and needs five things at once:
  the Settings switch "Offer Force Quit when a process ignores a stop request" (off), a
  `requestStop` that returned `.stillRunning` for the same pid + start time, a recorded SIGTERM
  for that identity in a new in-memory `StopLedger` (5 s minimum grace, 60 s expiry, both
  engine-enforced), a second confirmation with the data-loss text, and the full v1 revalidation
  again right before `kill(pid, SIGKILL)`. PID only, never `killpg` or children (reasoned in
  decision 6). Batch: per row after the run, never "force quit all". Nothing from Live, CLI, MCP.
- **ADR-0007 (container stop).** `POST /containers/{64-hex id}/stop?t=T`, `T` from the
  container's own `Config.StopTimeout` (10 when unset, cap 120), exactly `docker stop`; the
  confirmation says in words that Docker force-kills after `T` s, so there's no second step.
  Re-inspect by full ID and compare `Id`, `Name`, `Created` before the call. Stops only through
  a user-owned Docker Desktop socket (`realpath`-checked); `DOCKER_HOST` sockets stay read-only;
  contexts and TCP are never used. Never offered: not running, Docker Desktop's own containers
  (label prefixes), Kubernetes, buildx, excluded projects/names. Behind "Allow stopping a
  container" (off, shown only when Docker is on). One stop at a time, every attempt recorded.
- **SECURITY-REVIEW-3d.md.** The shared invariants, the boundary table (before/after), the
  cross-cutting threats and a proving-test matrix per brief. Verdict: nothing blocks the design;
  two stated residuals (the microsecond identity race, the Engine's own escalation).
- **Audit record for 3e** is defined in ADR-0006 §Audit record (no argv, no paths beyond the
  project name); ADR-0007 reuses it with `action: containerStop`.
- Facts cited from the Docker Engine API v1.51 spec and `moby/moby` `daemon/stop.go` (stop
  responses 204/304/404/500, `t`/`signal` params, `kill` defaults to SIGKILL, `StopTimeout`
  nullable, `context.WithoutCancel` in the Engine's stop). I downloaded both into my scratchpad;
  nothing in the repo.
## Files
- docs/v2/ADR-0006-force-quit.md — created
- docs/v2/ADR-0007-docker-container-stop.md — created
- docs/v2/SECURITY-REVIEW-3d.md — created
- docs/v2/PLAN.md — modified (the 3c and 3d lines under Phase 3 only)
- handoffs/2026-10-28-1150-v2-3d-safe-actions-design.md — created
## Checks run
- `git status --short docs/v2 handoffs/…` lists only the five files above.
- `grep -nE "/Users/|gorock"` over the three new docs: nothing.
- `handoffs/bin/jarvis leftovers --mine`: nothing running.
- Not run: `swift build` / `swift test` / `run-app.sh` (no code changed, per the brief).
- Not done: no signal sent, no Docker call made, nothing clicked. Everything is from reading
  code, docs and the Engine spec/source.
## Processes left running
none
## Notes for Jarvis
- **Build briefs to write next, in this order** (each ADR's "Build briefs" section has the
  files, pattern, done-condition, proving command, may/must-not touch, and a model suggestion):
  1. **3d-1** core force quit: `StopLedger` + `ProcessTerminator.forceQuit` + `ForceQuitTests`
     (opus, high).
  2. **3d-2** app force quit: the switch, the second confirmation, per-row force quit in the
     batch sheet (opus, medium).
  3. **3d-3** core container stop: POST on `UnixSocketHTTP`, inspect, `ContainerStopper`,
     socket policy, `ContainerStopTests` (opus, high). Its live test is off unless
     `HEATLENS_LIVE_CONTAINER_STOP=1`.
  4. **3d-4** app container stop: the switch, `ContainerDetailView`, `ContainerStopFlowView`,
     clickable container rows in results only (opus, medium).
  3e (audit trail, ignore) then persists the ledger; its record shape is already fixed.
- **Shared-file heads-up for the builders:** none of the four briefs needs `Model/`,
  `Package.swift` or `project.yml`. `ActionRecord` deliberately lives in `Safety/StopLedger.swift`;
  3e may move it into `Model/` when it persists it.
- **Docs that become untrue once the switches ship** (outside my scope; "by default" plus the
  switch name is the fix): `README.md:4,46,97,107` ("read-only", "SIGTERM only"),
  `site/index.html:7,21,29,493,497` ("read-only"; "No force-quit, no bulk kill"),
  `docs/LIMITATIONS.md:29` ("only reads Docker Desktop's local socket"). The CLI/MCP lines
  (`README.md:46,67`, `site/index.html:374,397`) stay true. Suggest doing them with 3d-2 and 3d-4.
- **One deviation from the brief's wording:** the brief lists "Compose projects" under
  exclusions. I did not exclude Compose containers (they are exactly the FDA test containers the
  owner wants to stop); the confirmation instead says other services keep running and
  `compose up` recreates it. Easy to flip in ADR-0007 decision 5 if the owner meant otherwise.
- **Suggested commit message:**
  `docs(v2): ADR-0006 force quit, ADR-0007 container stop, Phase 3d security review and build briefs`
