# HeatLens v2: phased implementation plan

Source: [`docs/PRD-v2.md`](../PRD-v2.md). Audit: [GAP-ANALYSIS.md](GAP-ANALYSIS.md). Decisions:
[ADR-0001](ADR-0001-hardware-sensors.md) (sensors), [ADR-0002](ADR-0002-docker-adapter.md)
(Docker), [ADR-0003](ADR-0003-live-monitoring-and-transport.md) (live mode, no local server).

Each brief is small, ends with green `swift build && swift test` plus `scripts/run-app.sh
--build-only`, and can be reverted alone. New behaviour stays behind a Settings switch or a button
the user presses. The switches default to off, except hardware sensors (on from v2.0, owner
decision; see below).

## Phase 0 — audit and spike ✅

Exit: ADRs, compatibility matrix, sensor demo, no production dependency.

- [x] Gap analysis and baseline benchmark (GAP-ANALYSIS.md)
- [x] macmon validated on the M3 Pro; native Swift SMC spike matched it (ADR-0001)
- [x] Docker Engine API probed read-only (ADR-0002)
- [x] Transport and live-mode decision (ADR-0003)
- [x] Compatibility matrix (COMPATIBILITY.md)
- [x] Sensor demo: `heatlens-probe --sensors` (and `--docker`, `--live <s>`), the spike turned into the real provider

## Phase 1 — reliable local monitoring (P0) ✅

Results: [PHASE-1-REPORT.md](PHASE-1-REPORT.md).

Dependency order: 1a → (1b, 1c, 1d in any order) → 1e → 1f → 1g.

### 1a · Report cost fix (gate for live mode) ✅ 1.21 s → 0.11 s CPU per report
- **Do:** precompile `Redactor`'s regular expressions once (`NSRegularExpression` statics).
  Keep the patterns and behaviour byte-for-byte.
- **Accept:** every existing `RedactorTests` passes unchanged. `heatlens-probe --report --duration 1`
  user CPU drops from ~1.2 s to under 0.3 s on the dev Mac (measured, recorded in PERFORMANCE.md).
- **Rollback:** revert one file.

### 1b · Hardware and power-context provider ✅
- **Do:** `HardwareSample` model (nullable readings, each with `SensorAvailability` and `SensorSource`);
  `HardwareSensorProviding`; `SMCSensorProvider` (ADR-0001); `PowerContext` from IOPowerSources +
  Low Power Mode; `heatlens-probe --sensors [--samples n]` demo.
- **Accept:** `SMCKeyData` is 80 bytes (test). SMC value decoding (`flt`, `ui8`/`ui16`/`ui32`,
  `fpe2`, `sp78`) is tested with byte fixtures. The plausibility filter and averaging are tested.
  A disabled or failing provider gives `unavailable`, never 0 (test). A live test on this Mac reads
  CPU and GPU temperature in 10–150 °C and ≥ 1 fan, and is skipped when there is no SMC. The probe output agrees
  with `macmon pipe` within 1 °C.
- **Rollback:** additive files only. Nothing calls the provider until 1e/1f.

### 1c · Docker adapter ✅
- **Do:** `UnixSocketHTTPClient` (GET only, path allowlist, size caps, chunked decoding),
  `DockerEngineClient`, `ContainerSample`, `DockerAvailability`, `DockerSampler` (two one-shot
  stats bracketing an interval); `heatlens-probe --docker` demo.
- **Accept:** HTTP parsing tests (content-length, chunked, truncated, oversized, non-200). JSON
  fixture decoding, including Compose labels. Container ID validation rejects anything not
  hex. CPU math tests (100 % = one core, nil when backwards). State mapping for missing socket,
  ECONNREFUSED, EACCES, bad JSON and old API. A live test lists containers when the socket
  exists and is skipped otherwise. There is no code path that sends a verb other than GET (test on the
  request builder).
- **Rollback:** additive. Off by default.

### 1d · Process tree and heuristics ✅
- **Do:** recognise browsers (Safari, Chrome, Arc, Firefox, Edge, Brave and their helpers), Python,
  Java/JVM, Docker CLI / Compose, Gemini CLI and Codex CLI, alongside the existing tools. Recognition rules
  are data in `WorkloadHeuristics`. User rules in Settings map an argv token or process name to
  a label (data only, never executed). The process detail view gains a children subtree.
- **Accept:** a resolver test for each new kind. A user rule beats a built-in rule. A
  malformed user rule is ignored with a notice. Every existing resolver test still passes.
- **Rollback:** additive. User rules default to empty.

### 1e · Live monitor engine ✅ 1.0% of one core at 5 s (release engine)
- **Do:** `LiveMonitor` actor (ADR-0003). It produces a stream of ticks with system, processes (CPU
  deltas tick to tick), hardware and containers. It has a ring buffer for trends, an interval of
  2/5/10 s, pause/resume, refresh-now, a 15-min auto-pause, and skips a tick when overrunning.
- **Accept:** fake-sampler tests for: no work before start or after stop; cancellation leaves no
  task; deltas match `CPUMath`; PID reuse between ticks is a new process, not a CPU spike;
  the ring buffer stays bounded; an overrun skips a tick. A synthetic 1,000-process test
  stays under its time bound. A live test runs 3 ticks against this Mac. Overhead is measured
  (CPU per tick at 5 s, footprint growth over 15 min) and recorded against the ADR-0003 budget.
- **Rollback:** additive.

### 1f · Live dashboard UI and switches ✅
- **Do:** a "Live" mode in the existing panel, in the same visual style. Start/Pause/Refresh now,
  interval picker, top CPU and memory processes with sparklines, a hardware card (temperatures,
  fans, system power, CPU/GPU power "Unavailable", each with a source badge), a public-context
  card (thermal state, memory pressure, power source), and a Docker card. Settings switches:
  "Hardware sensors (private macOS interfaces)" and "Docker containers", both off. Live stops
  when the panel closes. Scan results also show the hardware and Docker cards when enabled.
- **Accept:** builds. A Debug fixture mode shows every availability state. A click-through
  (docs/CLICKTHROUGH.md) covers start, pause, close-stops and each switch. Idle cost after
  stopping is back to 0 % (measured).
- **Rollback:** the switches stay off; reverting the UI files restores v1.2.1.

### 1h · Per-process CPU energy; sensors on by default ✅
- **Do:** read `ri_energy_nj` with `proc_pid_rusage` v6 (public). `ProcessSample.cpuWatts` and
  `cpuEnergyNanojoules`, group and total figures averaged over the whole interval. Show it in
  Live (overview total, under each Top CPU figure), scan group rows, process detail, the
  high-CPU finding's evidence and both reports. Hardware sensors on by default; a "Show Docker
  containers" button in Live mode. ADR-0001 addendum.
- **Accept:** watts maths and never-zero rules; assembly windows (survivor, born mid-scan, ps,
  exited); totals don't overcount births; finding evidence and report text/JSON; old JSON still
  decodes; live tests on this Mac. Cross-checked against macmon. Overhead unchanged.
- **Rollback:** revert the commit; the sensor default is one line in `SettingsModel`.

### 1g · Phase 1 acceptance ✅
- **Do:** update LIMITATIONS.md, PERFORMANCE.md and COMPATIBILITY.md. Write a changelog entry and a
  Phase 2 brief.
- **Exit (PRD-v2):** a live dashboard with refresh controls, low-overhead sampling, accurate
  metrics, explicit source and availability indicators, and integration tests.

## Phase 2 — project-aware diagnostics and history (P0/P1) ✅

Results: [PHASE-2-REPORT.md](PHASE-2-REPORT.md).

### 2a · Project roots and container attribution ✅ (ADR-0004)
- **Did:** `ProjectRootLocator` (stat-only, protected folders skipped, cached), `ProjectMapping`
  ("Project folders" in Settings), `ProjectAttributor.attribute` for containers (user mapping,
  Compose `working_dir`, `config_files`, bind mounts into one project, else Unattributed with
  the reason). Bind mounts come from the container list: no new Docker endpoint.
- **Accepted:** tests per evidence type, the FDA container maps to `~/Developer/FDA`, live test
  against Docker and against this checkout's `.git`.

### 2b · Per-project aggregation ✅
- **Did:** `ProjectAttributor.breakdown`: rows per project, then Docker VM, then Unattributed.
  Container CPU moves from the VM row to its project; container memory is shown, never added.
  A Projects card in Live and scan results; process detail names the repository.
- **Accepted:** VM + containers test where the rows add up to the host total; over-attribution
  clamps at 0 with a notice; no VM → containers kept out of totals; Docker off; two VMs; 1,000
  processes under 50 ms. Live cost 1.15% of one core at 5 s.
- **Not yet driven in the app:** the Projects card (the screen was locked during the click-through).

### 2c · History store ✅ (ADR-0005)
- **Did:** `HistoryStore` (system SQLite, actor), `HistoryRecorder`, "Keep history" (off),
  retention 1/7/30 days, Delete history, size in Settings. Written only by `LiveMonitor`.
- **Accepted:** permissions and symlink refusal, round trip with bound values, minute rollups,
  retention, a 7-day size bound (6.5 MB worst case), delete, no writes outside a session.
### 2d · Timeline ✅
- **Did:** the session timeline in memory (`LiveTick.timeline`), saved ranges from the history,
  the Timeline card (CPU line, event markers, busiest moment with its projects and events),
  `TimelineAnalysis.peak`.

### 2e · Expensive commands ✅
- **Did:** `ExpensiveCommand` (installs, builds, test runs; outermost only), `TimelineDetector`
  (started, at once, repeated, containers, thermal), labelled as inference where it is one.
- **Accepted:** tests per command and event; 1,000 processes < 10 ms per tick (classification
  cached per process); a placeholder `npm ci` + `vitest` on this Mac produced both starts and the
  concurrency inference.

## Phase 3 — explanations, alerts, safe actions (P1)

- 3a Concurrency rules ("three Docker integration tests began within 10 s across two agent trees"). ✅
  **Did** (brief 3b): `ConcurrencyRules` → `Explanation` (observations, confidence, uncertainty,
  advice only) on `LiveTick.explanations` and the timeline; "What's going on" card in Live. FDA test passes.
- 3b Alert policies with hysteresis and cooldown (CPU, thermal, swap, memory, containers). ✅
  **Did** (brief 3c): `AlertEvaluator` → `LiveTick.alerts` and `.alertFired` timeline events, checked only
  while Live runs; Settings → Alerts (off by default), one notification per alert, a Live banner.
- 3c Force quit after a *separate* confirmation (v1 omitted it on purpose). **Designed** (brief 3d, 2026-10-28):
  [ADR-0006](ADR-0006-force-quit.md); builds are briefs 3d-1 (core) and 3d-2 (app) in the ADR.
- 3d Stop a selected container: the first non-GET Docker call. **Designed** (brief 3d, 2026-10-28):
  [ADR-0007](ADR-0007-docker-container-stop.md) and [SECURITY-REVIEW-3d](SECURITY-REVIEW-3d.md);
  builds are briefs 3d-3 (core) and 3d-4 (app) in the ADR, after 3d-1/3d-2.
- 3e Local action audit trail; ignore process/project.
- Exit: reproduce the FDA multi-worker Docker test scenario.

## Phase 4 — background service and polish (P1/P2)

LaunchAgent helper with XPC (new ADR), adaptive sampling, watchlists, incident export, structured
logs, crash recovery, Jarvis integration through the existing stdio MCP server.

## Owner decisions (2026-10-27)

1. **CPU/GPU power.** Don't bundle macmon. Per-process CPU energy from a public API instead
   (brief 1h); whole-chip CPU/GPU power stays "Unavailable". ADR-0001 addendum.
2. **Defaults.** Hardware sensors on by default from v2.0. Docker stays opt-in, one tap away in
   Live mode.
