# v2 3d-3: core container stop: POST on UnixSocketHTTP, inspect, ContainerStopper, socket policy
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 12:16 · terminal: 443a3f8c-e311-4e31-9a13-f20050fd5292

## Goal
Build exactly what `docs/v2/ADR-0007-docker-container-stop.md` §Build briefs **"3d-3"** specifies: its Do, its pattern to copy, its done condition (tests 1–11 three runs in a row; test 12 skipped by default; the two greps) and its may/must-not-touch lists. Read the whole ADR and `docs/v2/SECURITY-REVIEW-3d.md` first.

`StopLedger`/`ActionRecord` exist now (`Sources/HeatLensCore/Safety/StopLedger.swift`, merged in `handoffs/merged/2026-10-28-1215-v2-3d1-force-quit-core.md`). Record each container stop attempt with `action: containerStop`, as ADR-0007 says. `ActionContext` is optional and nil-safe. Read `StopLedger.swift`, but don't change it. If you truly need a change there, put it as a question.

**Done when:**
- tests 1–11 pass three runs in a row under `scripts/with-timeout.sh 600`
- `grep -rn '"POST ' Sources/` prints one line, in `UnixSocketHTTP.swift`
- `grep -rn "ContainerStopper\|containerStop" Sources/HeatLensCLI Sources/heatlens` prints nothing
- every existing Docker test passes
- test 12 is skipped by default

## Test 12 (live), allowed once
You may run test 12 once with `HEATLENS_LIVE_CONTAINER_STOP=1`, **only** if Docker Desktop is already running. Don't start Docker. It may only touch the fixture container it starts itself (`docker run -d --rm --label heatlens.test=fixture alpine sleep 300`). Before and after, confirm with `docker ps --filter label=heatlens.test=fixture` that nothing of yours is left. Never stop, kill or remove any other container. The user's FDA containers may be running. Record the Engine version in the handoff. If Docker isn't running, skip test 12 and say so.

## Context
- User rulings (2026-10-28):
  - Container stop ships in v2, behind "Allow stopping a container" (off; the switch is built in 3d-4).
  - It is exactly `docker stop` (`POST /containers/{id}/stop?t=…`).
  - From scan results only, never Live.
  - The CLI/MCP stay read-only.
- Compose containers stay stoppable (ADR-0007 decision 5).

## Scope
- May touch: `Sources/HeatLensCore/Docker/UnixSocketHTTP.swift`, `Sources/HeatLensCore/Docker/DockerEngine.swift`, `Sources/HeatLensCore/Docker/ContainerStopper.swift` (new), `Tests/HeatLensCoreTests/ContainerStopTests.swift` (new), `Tests/HeatLensCoreTests/DockerEngineTests.swift`, `Tests/HeatLensCoreTests/Fixtures/`
- Must not touch: `Sources/HeatLensCore/Model/ContainerSample.swift`, `Sources/HeatLensCore/Safety/` (read only), `App/` (another worker is building force quit's UI there at the same time), CLI targets, `Package.swift`, docs

## Phase
3d-3 only. The app side is 3d-4.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
for i in 1 2 3; do scripts/with-timeout.sh 600 swift test --filter "ContainerStop|DockerEngine" 2>&1 | tail -4; done
handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -15
grep -rn '"POST ' Sources/ ; grep -rn "ContainerStopper\|containerStop" Sources/HeatLensCLI Sources/heatlens
```
The Redactor test "1,000 processes … under a second" flakes under heavy CPU load. If it's the only failure, rerun it and say so.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
