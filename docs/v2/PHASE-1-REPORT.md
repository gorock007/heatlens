# HeatLens v2 — Phase 0 and Phase 1 report

Date 2026-10-27. Machine: MacBook Pro M3 Pro (Mac15,6), macOS 27.0.1 (26A434), Xcode 26.6,
Swift 6.3.3, Docker Desktop 28.5.1. Plan: [PLAN.md](PLAN.md).

## Changelog

**Phase 0 (docs only, no dependency added)**

- [GAP-ANALYSIS.md](GAP-ANALYSIS.md): audit of v1.2.1 against PRD-v2, baseline benchmark, v1/v2 conflicts and their resolution.
- [ADR-0001](ADR-0001-hardware-sensors.md): native Swift SMC reader, not bundled macmon; CPU/GPU power unavailable.
- [ADR-0002](ADR-0002-docker-adapter.md): read-only Docker Engine API over the local Unix socket.
- [ADR-0003](ADR-0003-live-monitoring-and-transport.md): in-process live mode, no localhost server.
- [COMPATIBILITY.md](COMPATIBILITY.md): sources, units, privileges and verification status per reading.

**Phase 1**

- **1a, report cost:** `Redactor` compiled its regular expressions on every call. Each app scan
  spent about 2 s of CPU on two reports. They are now compiled once (`RedactionPatterns`).
  The report's CPU dropped from 1.21 s to 0.11 s, and a full 5 s scan from 6.3 s to 5.2 s wall.
- **1b, hardware:** `HardwareSample`, `SensorReading` (value, availability, source),
  `SMCSensorProvider` (CPU/GPU temperature average and hottest sensor, fans, system power;
  read commands only), `PowerContext` (AC/battery, charge, Low Power Mode, public APIs).
  `heatlens-probe --sensors` is the demo.
- **1c, Docker:** `UnixSocketHTTP` (GET only, path allowlist, size and time caps, chunked
  decoding), `DockerEngineSampler` (socket discovery with owner checks, API negotiation ≥ 1.41,
  one-shot stats for up to 20 running containers within 3 s), `DockerAssembly` (CPU delta, 100 =
  one core; memory without page cache), `ContainerSample` and `DockerAvailability`.
  `heatlens-probe --docker` is the demo.
- **1d, heuristics:** new workload kinds: browser, Python script, pytest, Java (`-jar`, Gradle
  and Kotlin daemons, main class), Docker CLI (subcommand), Gemini CLI, Codex CLI. Agents now
  include Gemini and Codex. Custom labels (`token = Label`, data only, never for root or
  protected processes). `ProcessTree` for children.
- **1e, live engine:** `LiveMonitor` actor. It reuses `ScanAssembly`, so it uses the same CPU
  maths, PID-reuse rule and birth rule as a scan. It never runs `ps`, `pmset`, ports or
  assertions. Intervals are 2, 5 or 10 s, with refresh-now and a 15-minute auto-pause. It
  never queues ticks, and dropping the stream stops the session. `LiveHistory` is a bounded
  ring (Float/KiB). `heatlens-probe --live <s>` drives it.
- **1f, UI:** a Scan | Live switch in the panel and the Live view (start/pause, refresh, interval,
  overview with a public badge, Top CPU and Top memory with sparklines, hardware card with an orange
  "SMC · private interface" badge, Docker card). Settings gain "Hardware sensors (private macOS
  interfaces)" and "Docker containers" (both off) and Custom labels. Scan results show the
  hardware and Docker cards when they're on. Process detail shows children. Closing the panel or
  switching to Scan stops Live.
- **Bug fix found on the way:** `ProvenanceResolver.resolve` trapped (`Duplicate values for key`)
  on a snapshot where a PID was reused during the interval. That snapshot holds the exited
  process and its successor. The resolver now keeps the running one. This was latent in
  v1.2.1 scans; live mode would have hit it within minutes.

Nothing was added to `Package.swift` dependencies. No entitlement, helper, network listener or
privilege was added. The CLI and MCP server are unchanged and don't expose Docker or sensors.

## Tests

`swift build && swift test`: **249 tests in 39 suites, all passing** (186 in 35 before), run 3×
in a row green after 1d. One earlier full run had a single transient miss in the pre-existing
live `yes`-fixture test (67% < 80% under parallel load). It passed 3/3 alone and in every later
full run. `scripts/run-app.sh --build-only`: builds.

| Suite (new) | Tests | Covers |
|---|---|---|
| Hardware sensors | 16 | 80-byte struct layout and offsets, read-only commands, SMC type decoding, key discovery, never-zero availability, fanless, power-source parsing, Codable, live SMC on this Mac |
| Docker Engine adapter | 18 | GET-only request building, ID and path allowlists, API version parsing, HTTP parsing (Content-Length, chunked, truncated, oversized), a real `AF_UNIX` server (chunked writes, timeout, ENOENT), socket locator owner checks, interval CPU and memory, failure states, 20-container cap, live Docker |
| Workload heuristics | 12 | each new kind, agent grouping, browser counts as active work, python detached worker, rule parsing and precedence, protected processes, process tree bounds |
| Live monitor | 16 | no work outside a session, tick deltas, PID reuse, live notices, providers off, top lists and trends, history bound, auto-pause, failure, refresh-now, dropping the stream, restart, interval clamp, 1,000 processes, live Mac |
| Redacted export (+2) | | patterns compile; 1,000-process reports under 1 s |
| Provenance resolver (+1) | | reused PID doesn't crash |

## Validation on Apple Silicon (this M3 Pro)

| Check | Result |
|---|---|
| SMC temperatures vs macmon 0.10.0, side by side | identical averages (CPU 58.4/58.5/55.6 °C, GPU 48.8/49.0/48.7 °C), fans within 1.5%, system power identical |
| Docker vs `docker stats` | `fda-db-1`: 0.0% / 139.6 MB in both |
| Live overhead, release engine, 5 s interval, sensors and Docker on, 60 s | 0.65 s CPU in 64 s = **1.0% of one core**, ~90 ms per tick, 10.7 MB peak footprint |
| Live overhead, Debug app with UI, 30 s | 0.59 s CPU = 2.0% of one core |
| Idle after closing the panel | CPU time unchanged over 30 s |
| 15-minute session, release engine | 9.11 s CPU in 900.9 s = **1.0% of one core**; 174 ticks, median 93 ms; peak footprint 19.4 MB (≈ 9 MB growth over the 1-minute run); auto-paused at 900 s |

## Acceptance against PRD-v2 Phase 1 exit

| Exit criterion | Status |
|---|---|
| Live dashboard with refresh controls | ✅ Start/Pause, Refresh now, 2/5/10 s |
| Low-overhead sampling | ✅ 1.0% engine / 2.0% Debug app at 5 s; 0 when closed |
| Accurate metrics | ✅ cross-checked against macmon, `docker stats`, and v1's verified CPU maths (reused) |
| Explicit source and availability indicators | ✅ private/public badges; every missing reading says why |
| Integration tests | ✅ live tests against SMC, Docker, libproc; a real Unix-socket server |

## Known limitations

See [docs/LIMITATIONS.md](../LIMITATIONS.md) items 4 and 9–15. In short: CPU/GPU power are
unavailable; sensors are verified on one M3 Pro only; live mode doesn't sample root
processes; containers aren't attributed to projects yet; Safari's WebKit processes don't group
with Safari.

## Open decisions for the owner

1. **CPU/GPU power:** keep "Unavailable", or bundle a pinned macmon build (Rust in `release.sh`,
   a third-party binary in the notarized app). ADR-0001.
2. **Defaults:** hardware sensors and Docker are off by default. Should they be on in v2.0?
3. **Release:** this work isn't released or committed. Version bump and release are Jarvis or the owner's call.

## Next: Phase 2 brief

**Goal:** a CPU spike leads to a named repository, its process tree and the timeline evidence
(PRD-v2 Phase 2 exit).

1. **2a Project roots and container attribution.** A stat-only walk from cwd to the nearest
   `.git` or `package.json` (no file reads). Compose `working_dir` → project, and bind mounts
   from `GET /containers/{id}/json` (a new allowlisted GET). User mappings in Settings. An
   explicit "Unattributed" bucket.
   *Accept:* resolver tests per evidence type; the FDA container maps to `~/Developer/FDA`.
2. **2b Per-project aggregation.** CPU and memory per project. Container CPU is a breakdown of
   the Docker VM process, never added to it.
   *Accept:* a test with VM + containers where the totals don't double.
3. **2c History store.** System `libsqlite3`, no dependency. A 1-hour high-resolution window
   plus 7-day rollups, retention setting, "Delete history". Written only from live ticks.
   *Accept:* bounded size test; deletion test; no writes while Live is off.
4. **2d Timeline view.** Thermal state, CPU, swap, container starts, test-runner starts.
5. **2e Concurrent expensive commands** (`npm ci`, `vitest`, `next build`, `docker build`),
   labelled as inference, with timestamps.

Dependencies: 2a → 2b; 2c → 2d; 2e needs 2a. Rollback: each behind the existing switches, plus a
"Keep history" switch (off by default) for 2c. Security review before 2a's new Docker endpoint
and before 2c writes to disk.
