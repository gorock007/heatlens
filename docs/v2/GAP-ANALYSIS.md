# HeatLens v2: audit and gap analysis (Phase 0)

Audited 2026-10-27 against [`docs/PRD-v2.md`](../PRD-v2.md), on the development Mac: MacBook Pro
M3 Pro (Mac15,6, 5 P + 6 E cores, 14-core GPU, 18 GB), macOS 27.0.1 (26A434), Xcode 26.6,
Swift 6.3.3. Starting point: v1.2.1 (commit `6b373ab`), 186 tests in 35 suites, all passing.

## 1. What HeatLens is today

| Area | Today (v1.2.1) | Where |
|---|---|---|
| App type | Native Swift 6 / SwiftUI menu-bar app (`LSUIElement`), movable status panel, no Dock icon. Unsandboxed, Developer ID signed and notarized, direct download. | `App/`, `project.yml`, `docs/FEASIBILITY.md` §7 |
| Engine | `HeatLensCore` Swift package, zero third-party dependencies. | `Sources/HeatLensCore/` |
| Collection model | **On demand only.** One bounded, cancellable 5/10/15 s scan the user starts. No timers, no polling, ~0 % idle CPU (measured). | `Coordinator/ScanCoordinator.swift`, `docs/PERFORMANCE.md` |
| Process sampler | libproc (`proc_listallpids`, `PROC_PIDTBSDINFO`, `PROC_PIDTASKINFO`, `proc_pid_rusage`, `KERN_PROCARGS2`, cwd) + read-only `/bin/ps` fallback for root processes. Identity is `(pid, start time)`. CPU from interval deltas, 100 % = one core. | `Sampling/Libproc.swift`, `PSTimeSampler.swift`, `CPUMath.swift` |
| System sampler | Host CPU ticks, VM stats, swap, swap-out delta, `kern.memorystatus_vm_pressure_level`, `ProcessInfo.thermalState`, `pmset -g therm` notes. | `Sampling/SystemSampling.swift` |
| Extra signals | Listening TCP ports per process; sleep-blocking power assertions. | `PortSampling.swift`, `PowerAssertionSampling.swift` |
| Attribution | Parent tree, app bundle, argv tokens, cwd → `ProcessGroup` with project, evidence and confidence. Knows Next.js, Vite, Astro, webpack, turbo, Vitest, Jest, `tsc --watch`, npm/pnpm/yarn/npx, bun, node scripts, Claude Code, OpenCode, Superset worktrees, app bundles, Apple services. | `Provenance/ProvenanceResolver.swift` |
| Findings | Deterministic rules: sustained CPU, memory pressure / swap, UI and `kernel_task`, thermal state, keeping awake, leftover candidates. Every finding has evidence, confidence, limitations, ranked impact-first. | `Rules/` |
| Safe actions | Per-process SIGTERM after confirmation with `(pid, start time)` revalidation, protected-process denylist, no SIGKILL, exclusion lists; batch stop of a project's rule-flagged leftovers with per-PID revalidation. | `Safety/`, `App/StopService.swift` |
| Comparison | "Since last scan" in memory only. | `Rules/ScanComparison.swift` |
| Alerts | Opt-in thermal alert: on a rise to serious/critical, one scan + notification, ≤ 1 per 30 min, no polling. | `App/ThermalAlertService.swift` |
| Export | Redacted text and JSON reports (home → `~`, username, argv beyond argv[0], secrets, tokens). | `Export/Redactor.swift` |
| CLI / agents | `heatlens scan|ports|awake [--json]` and a read-only stdio MCP server (`heatlens mcp`), bundled in the app. No network listener. | `Sources/HeatLensCLI/` |
| Distribution | `scripts/release.sh`, notarized DMG, GitHub releases, click-only update check, landing page on Vercel (`site/`, static only). | `docs/RELEASING.md` |

The architecture already matches PRD-v2 §5 in shape: a native, least-privilege, in-process
collector with the UI in the same process. There is no web UI, no localhost endpoint and no
companion app to secure. **The "hosted Vercel page cannot read hardware" concern does not apply:**
the Vercel site is marketing only and never talks to the app.

## 2. Requirement-by-requirement gap

Legend: ✅ have it · 🟡 partial, reuse and extend · ❌ missing · ⛔ deliberately not doing (with reason)

### Phase 0 — audit and spike

| Requirement | Status | Notes |
|---|---|---|
| Map implementation, hardware, screens, data | ✅ | This document; `docs/FEASIBILITY.md` covers process/system APIs in depth. |
| Benchmark idle CPU/memory and collection frequency | ✅ | §4 below (re-measured today). |
| Validate macmon temperature, power, fans on M3 Pro | ✅ | [ADR-0001](ADR-0001-hardware-sensors.md) §Evidence. |
| Record source, units, intervals, privileges, hardware, missing values | ✅ | [COMPATIBILITY.md](COMPATIBILITY.md). |
| Decide Swift vs Rust vs existing stack | ✅ | ADR-0001: native Swift SMC reader; macmon not bundled in Phase 1. |

### Phase 1 — reliable local monitoring (P0)

| Requirement | Status | Plan |
|---|---|---|
| CPU/GPU average temperature when supported | ❌ | 1a: native SMC provider (spike matched macmon to 0.1 °C). |
| Hotspot where available | ❌ | 1a: report the hottest CPU and GPU sensor read, labelled "hottest sensor", not a named die hotspot (key meanings are community-documented, not Apple-documented). |
| Fan RPM where available | ❌ | 1a: SMC `F<n>Ac` / `F<n>Mx`; "No fans reported" on fanless Macs. |
| CPU/GPU power | ❌ → "unavailable" | ADR-0001: on macOS 27 these need per-firmware CLPC IDs; Phase 1 shows **Unavailable (needs per-macOS power tables)**. System power (SMC `PSTR`) is shown instead. Bundling macmon for CPU/GPU power is a separate, later decision. |
| Battery / power context | 🟡 | Power assertions exist. 1a adds IOPowerSources (AC/battery, charge %, charging) and Low Power Mode, all public APIs. |
| `thermalState` | ✅ | Reuse. UI must keep it visually separate from private sensor readings (provenance badge). |
| CPU and memory pressure | ✅ | Reuse `SystemSample`. |
| "Unavailable" instead of zero | 🟡 | Model already does this for process detail (`DetailAccess`). 1a extends it with a per-reading `SensorAvailability`. |
| Top CPU and memory processes, PID, PPID, start, executable, command (redacted), elapsed | ✅ | Reuse `ProcessSample` and `Redactor`. |
| CPU and memory **trends** | ❌ | 1d: in-memory ring buffer in the live monitor. |
| Recursive process tree | 🟡 | Detail view shows the parent chain; 1c adds a children subtree. |
| Identify browsers, Node, Python, Java, Claude/OpenCode, dev tools | 🟡 | Node, Claude, OpenCode, JS dev tools ✅. Browsers, Python, Java, Docker CLI, Gemini CLI, Codex ❌ → 1c. |
| Configurable heuristics | ❌ | 1c: user-defined name/argv-token → label rules in Settings (data only, never executed). |
| Docker: opt-in detection, containers, image, status, labels, start, CPU/mem, ID | ❌ | 1b: read-only Engine API client over the local Unix socket. |
| Docker → process/project mapping | ❌ (Phase 1 shows evidence only) | 1b records Compose labels (`project`, `working_dir`, `service`); full project attribution is Phase 2. |
| Absent/stopped Docker, API permission failures | ❌ | 1b: explicit states; never starts Docker. |
| Live dashboard with refresh controls | ❌ | 1d: user-started live view, refresh interval, pause, stops when the panel closes. |
| Low-overhead sampling | 🟡 | **Found a hot spot**: `Redactor` recompiles regexes per path component, ~1.1 s CPU per report, two reports per app scan. 1c fixes it before any live mode. |
| Integration tests | 🟡 | Live-Mac sampler tests exist; 1a/1b add provider tests that skip cleanly when SMC or Docker is absent. |

### Phases 2–4 (not started, listed for planning)

| Requirement | Status | Notes |
|---|---|---|
| Project inference from cwd, executable, repo root | 🟡 | cwd/argv ✅; repo root walk (stat-only) ❌. |
| Compose labels, bind mounts, user mappings | ❌ | Needs 1b. |
| `(PID, start time)` identity | ✅ | Already the identity everywhere. |
| Per-project aggregation without double-counting the Docker VM | ❌ | Rule: container CPU is a *breakdown* of the VM process's CPU, never added to it. |
| Bounded local history, retention, deletion | ❌ | No persistence today, by design. Phase 2 decision: on-disk store (SQLite via the system `libsqlite3`, no dependency). |
| Timeline | ❌ | Needs history. |
| Concurrent expensive command detection | 🟡 | Tool classification exists; concurrency rule ❌. |
| Explanations with observations/confidence/uncertainty | ✅ | Reuse `DiagnosticFinding`. |
| Configurable alerts with hysteresis | 🟡 | Thermal alert only; others ❌. |
| Abandoned-process flags (age + activity + parent + owner + project state) | ✅ | Leftover rules already require more than age. |
| inspect → confirm → SIGTERM → separate force-quit confirmation | 🟡 | All but force quit, which v1 deliberately omitted. PRD-v2 allows it after a separate confirmation; decide in Phase 3. |
| Docker cleanup of selected containers only | ❌ | Would be the first write call to the Docker API. Phase 3, behind its own review. |
| Action audit trail, ignore lists | 🟡 | Exclusions ✅; persistent audit ❌. |
| LaunchAgent, adaptive sampling, notifications, watchlists, export, auto-update, logs | 🟡 | Notifications (thermal), export, update check ✅; the rest ❌. |
| Jarvis integration via authenticated local protocol | 🟡 | The stdio MCP server is local by construction (no socket, no port). Phase 4 extends it rather than adding a network protocol. |

## 3. Conflicts between PRD v1 and PRD v2, and how the plan resolves them

PRD v1's non-goals ruled out continuous monitoring and undocumented sensors. PRD v2 asks for
both, with guardrails. The plan keeps v1's guarantees as defaults and adds v2 features behind
explicit switches:

| v1 promise | v2 ask | Resolution |
|---|---|---|
| No polling, ~0 % idle CPU | Live dashboard, later a background service | Live sampling runs only while the live view is open and the user started it. Closing the panel stops it. Idle cost stays ~0. Background sampling waits for Phase 4 and its own budget. |
| No undocumented sensor scraping | Temperatures, fans, power via private interfaces | A Settings switch, "Hardware sensors (private macOS interfaces)", controls the SMC provider. It was off by default in Phase 1; the owner chose on by default for v2.0 (2026-10-27, ADR-0001 addendum). Read-only. Every reading carries its source. Failure means "Unavailable", never a crash or zero. |
| No network | Docker Engine API | Local Unix socket only, GET requests to an allowlist of paths, opt-in, off by default. No TCP, no `DOCKER_HOST` over the network. |
| Never auto-kill | Same | Unchanged. |

## 4. Baseline performance (re-measured 2026-10-27, v1.2.1)

Release build of the engine (`swift build -c release --product heatlens-probe`), about 810
processes on the Mac:

| Command | Wall | User CPU | Sys CPU | Peak footprint |
|---|---|---|---|---|
| `heatlens-probe --report --no-fixtures` (5 s scan + text report), 3 runs | 6.28–6.56 s | 1.20–1.22 s | 0.09 s | 15.1–15.7 MB |
| `heatlens-probe --no-fixtures --duration 1` (sampling only) | 1.13 s | 0.03 s | 0.11 s | — |
| `heatlens-probe --report --no-fixtures --duration 1` | 2.29 s | 1.21 s | 0.09 s | — |
| `/bin/ps -A -o pid=,time=,rss=` | 0.02 s | 0.00 s | 0.01 s | — |
| Port sampling (in probe) | 8.6 ms | | | |
| Power-assertion sampling (in probe) | 0.51 ms | | | |

**Finding:** sampling costs about 0.14 s CPU. The other ~1.1 s is the text report. `sample`
attributes it to `Sanitizer.looksLikeCredential` (`Redactor.swift:512`), where
`String.range(of:options: .regularExpression)` compiles a new Swift `Regex` on every call. The
app builds both a text and a JSON report after every scan (`App/ScanService.swift:26-29`), so a
scan in the app costs roughly 2 s of CPU it does not need to. Precompiling the patterns once
should remove nearly all of it. This is brief 1c's first task and the gate for live mode.

App idle cost (v1.2.1, `docs/PERFORMANCE.md` §1, unchanged since): 0.0 % CPU, no idle wakeups,
`top` MEM 18 MB, RSS 72–86 MB.

## 5. Hardware spike summary

Full evidence is in [ADR-0001](ADR-0001-hardware-sensors.md). In short:

- **macmon 0.10.0** (MIT, built from tag `v0.10.0` with `cargo build --release --locked`, no
  install) works without sudo on this M3 Pro: CPU 62.7–69.8 °C, GPU 58.7–63.7 °C, fans
  2279–2342 / 2481–2516 RPM (max 6800), CPU 2.5–4.2 W, GPU 2.3–3.2 W, system 18.4–26.9 W. It
  costs about 37 ms of CPU per sample, including process start.
- **A native Swift SMC reader** (scratch spike, about 120 lines, IOKit `AppleSMC` user client)
  read the same 77 CPU and 18 GPU temperature keys, the same fans and the same `PSTR` system
  power. Read side by side with macmon, the averages agreed to 0.1 °C each second. It costs
  10.5 ms once for key discovery (2422 keys), then 13–34 ms per full read, in-process.
- **CPU/GPU power through IOReport** is fragile on macOS 27. The enumerable `Energy Model`
  group reads 0 W. The working `CLPC / Energy Counters` channels are not enumerable. macmon
  builds them from per-firmware IDs that it extracts from Apple's kernelcaches for each macOS
  release (`src/clpc.rs`, `docs/clpc-discovery.md`). HeatLens should not own that process.

## 6. Docker spike summary

Docker Desktop 28.5.1, Engine API 1.51 (minimum 1.24), Linux VM kernel 6.10.14. The socket is
`~/.docker/run/docker.sock`, owned by the user (`srwxr-xr-x`), with `/var/run/docker.sock` a
symlink to it.

- `GET /_ping` → `OK`. `GET /v1.51/containers/json?all=1` → 1 container in 2 ms:
  `fda-db-1`, `postgres:17`, running, Compose labels including
  `com.docker.compose.project` and `com.docker.compose.project.working_dir`.
- `GET /containers/{id}/stats?stream=false&one-shot=true` → 12 ms, cumulative
  `cpu_usage.total_usage` (ns), `online_cpus` = 6 (the VM's CPUs, not the host's 11), memory
  usage and `inactive_file`. `precpu_stats` is empty in one-shot mode, so HeatLens takes two
  one-shot readings that bracket its own interval and divides by wall time. That gives the same
  convention as processes: 100 % = one core.
- Container CPU is **inside** the host's `com.apple.Virtualization.VirtualMachine` process CPU.
  Totals must never add the two (PRD-v2 Phase 2).
