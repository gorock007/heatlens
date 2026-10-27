# HeatLens — Product Requirements Document

**Version:** 1.0 | **Date:** 27 October 2026 | **Status:** Proposed implementation plan

## 1. Product vision
HeatLens is a local-first macOS diagnostic assistant for developers. It explains **why a Mac is under load**, identifies the responsible apps, processes, development projects, Docker containers and coding agents, and offers safe, understandable actions. It is **not** a generic temperature dashboard or a cloud telemetry product.

### Primary user story
“When my Mac gets hot or slow while I have several coding agents and development projects running, show me which workload is responsible, why it is running, whether it is likely useful, and what I can safely do.”

### Real-world acceptance scenario
Multiple coding agents independently execute Docker integration tests. HeatLens groups the related containers and test processes under the correct repository, reports concurrent installs, and recommends coordinating test execution. It must not falsely claim to measure how much heat each process generates.

## 2. Before implementation: audit the existing project
1. Inspect current HeatLens repository, application type (web/native/hybrid), collectors, data models, UI, deployment, permissions and tests.
2. Reuse existing capabilities and preserve the current visual identity and functioning features.
3. Produce a gap analysis against this PRD, then create small implementation briefs. Do not replace architecture blindly.
4. Confirm target macOS versions and Apple Silicon chip support; test on the actual M3 Pro development Mac.
5. Evaluate third-party licensing, APIs, release maturity, maintenance and packaging before choosing dependencies.

## 3. Users and success criteria
**Primary:** Mac-based software developers using Docker, local servers and AI coding agents. **Secondary:** technical power users seeking actionable diagnostics.

**MVP success:**
- Detect sustained high CPU and thermal pressure; display sensor availability and provenance.
- Identify top CPU consumers, parent/child trees, Docker containers, and associated projects.
- Explain the most likely cause with evidence, confidence and uncertainty.
- Never kill, prune, or alter a workload without explicit user confirmation.
- Continue functioning if private hardware APIs break or Docker is absent.
- Remain responsive with minimal monitoring overhead; measure and set budgets during baseline profiling.

## 4. Open-source and official integration candidates
These are **evaluation candidates**, not automatic dependencies. Pin versions after a compatibility and license audit.

| Candidate | URL | Role / caveat |
|---|---|---|
| macmon | https://github.com/vladkens/macmon | Preferred initial Apple Silicon sensor proof-of-concept; Rust library, JSON and localhost metrics; uses private macOS APIs, so compatibility is not guaranteed. |
| MacMonitor | https://github.com/ryyansafar/MacMonitor | Reference implementation for SMC, IOReport, fan and hotspot sensors. Some readings use a privileged helper; **do not copy its privilege approach without a security review**. |
| MacMonitor sensor reference | https://github.com/ryyansafar/MacMonitor/blob/main/SENSORS.md | Hardware-specific SMC keys and validation notes; not a universal sensor contract. |
| Rust libproc | https://github.com/andrewdavidmackenzie/libproc-rs | macOS process inspection candidate; validate current maintenance, APIs and macOS permissions. |
| sysinfo | https://github.com/GuillaumeGomez/sysinfo | Cross-platform CPU, memory and process sampling fallback/candidate. |
| Docker Engine API | https://docs.docker.com/reference/api/engine/ | Official container inventory, inspect, stats and events. Docker socket access is highly privileged: keep local and read-only by application policy. |
| Apple ProcessInfo thermalState | https://developer.apple.com/documentation/foundation/processinfo/thermalstate | Public thermal pressure signal; not an exact temperature sensor. |
| Apple Endpoint Security | https://developer.apple.com/documentation/endpointsecurity | Optional future advanced process-event visibility; entitlement and distribution restrictions apply. Not MVP. |
| Apple launchd | https://www.launchd.info/ | Background agent operational reference; prefer Apple's launchd documentation for final packaging decisions. |
| Apple developer documentation | https://developer.apple.com/documentation/ | Public Mach, IOKit, power and OS integration references. |

**Decision gate:** Prototype macmon on target Macs first. Prefer a native library adapter if stable and feasible; a bundled executable emitting JSON is an acceptable first integration. Do not require users to install Homebrew or run an untrusted installer. Do not expose macmon's metrics server on a public interface. Hardware sensors must be optional and isolated behind a provider interface.

## 5. Architecture

```text
HeatLens native macOS collector (local, least privilege)
  ├─ hardware adapter (macmon / supported fallback)
  ├─ process sampler (Mach/libproc/sysinfo)
  ├─ Docker adapter (Engine API, optional)
  ├─ project attribution engine (process tree, cwd, repo roots, labels)
  ├─ local event/history store (bounded retention)
  ├─ rules and explanation engine (evidence + confidence)
  └─ explicit-action service (preview → confirm → execute → audit)
            ↓ local authenticated IPC / localhost transport
HeatLens UI (existing web/hybrid/native UI, adapted to actual repository)
```

A remotely hosted Vercel page **cannot directly read Mac hardware**. If the existing product is web-first, provide a signed/notarized local companion app and a secure local communication path. Prefer local-only processing and storage. No cloud sync or account required for core monitoring. Protect against arbitrary websites invoking privileged localhost endpoints (origin checks, authentication, CSRF protections and binding to loopback only); prefer native IPC when feasible.

## 6. Functional requirements and phased delivery

### Phase 0 — Existing-app audit and technical spike
- Map current implementation, supported hardware, UI screens and data collection.
- Benchmark current idle CPU/memory and collection frequency.
- Validate macmon temperature, power and fan outputs on M3 Pro; compare with trusted system tools where possible.
- Record sensor source, units, sampling intervals, privileges, supported hardware and missing values.
- Decide Swift/SwiftUI vs Rust companion vs existing stack integration based on the codebase, not preference alone.

**Exit:** written architecture decision record, compatibility matrix and small sensor demo. No production dependency until verified.

### Phase 1 — Reliable local monitoring (P0)
**Hardware:** CPU/GPU average temperature when supported; hotspot and fan RPM only where available; CPU/GPU power; battery/power context; thermalState; CPU and memory pressure. Display “unavailable” rather than zero for unsupported sensors. Distinguish private sensor readings from public thermal state.

**Processes:** top CPU and memory processes; PID, PPID, start time, executable, command (redacted where sensitive), elapsed time, CPU and memory trends; recursive process tree; identify browsers, Node, Python, Java, Claude/OpenCode and common dev tools via configurable heuristics.

**Docker:** opt-in detection of Docker Desktop; list containers, image, status, labels, start time, CPU/memory, container ID; map container workload to process/project where evidence permits. Handle absent/stopped Docker and API permission failures gracefully. Never automatically enable the Docker daemon.

**Exit:** live dashboard with refresh controls, low-overhead sampling, accurate metrics, explicit source/availability indicators and integration tests.

### Phase 2 — Project-aware diagnostics and history (P0/P1)
- Infer project by process cwd, executable path, repo root, Docker Compose labels, container bind mounts and optional user-defined mappings.
- Attribute subprocesses to the correct project; identify unknown/unattributed workloads instead of guessing.
- Track process identity as `(PID, process start time)` to avoid PID-reuse errors.
- Aggregate CPU/memory per project and display process/container drilldowns; avoid double-counting host Docker VM CPU and per-container CPU as separate totals.
- Maintain local bounded time series (e.g., short high-resolution window plus rolled-up history), with configurable retention and deletion.
- Timeline: temperature/thermal pressure, CPU, swap, container starts, test runs and notable process changes.
- Detect simultaneous expensive commands (`npm ci`, `vitest`, `next build`, Docker builds) and likely repeated runs; label as inference, not certainty.

**Exit:** a user can navigate from a CPU spike to a named repository, contributing process tree and supporting timeline evidence.

### Phase 3 — Explanations, alerts and safe actions (P1)
- Rules first, not an opaque LLM dependency. Examples: “Three Docker integration tests began within 10 seconds across two agent trees.”
- Every explanation includes observations, confidence, timestamps and uncertainty; do not claim exact per-process heat contribution.
- Configurable sustained CPU, thermal pressure, swap, memory and container concurrency alerts with cooldown/hysteresis to avoid alert spam.
- Flag potentially abandoned dev servers/agent processes using age **plus** activity, parent status, owner identity and project state. Age alone is insufficient.
- Action flow: inspect → show affected processes and dependencies → warn about data loss → explicit confirmation → graceful termination → optional force quit only after separate confirmation.
- Docker cleanup must be restricted to explicitly selected containers, never blanket prune. No automatic termination by default.
- Record a local audit trail of suggested and executed actions; allow “ignore this process/project”.

**Exit:** reproduce the FDA multiple-worker Docker test scenario and receive a useful explanation and non-destructive recommendation.

### Phase 4 — Background service, polish and policy (P1/P2)
- Signed macOS background helper/LaunchAgent, opt-in launch at login, clear pause/quit/uninstall behaviour.
- Adaptive sampling (slow when idle, faster during an incident) with measurable overhead budgets and battery-aware defaults.
- Menu bar status and native notifications; notification frequency controls.
- Per-project watchlists and user-defined CPU/memory/concurrency warning policies. Start with alerts; enforcement is future/opt-in.
- Export privacy-redacted diagnostics and shareable incident reports.
- Auto-update, crash recovery, structured local logs, compatibility tests on macOS updates.
- Optional Jarvis integration via an explicitly enabled, authenticated local protocol; HeatLens should remain useful without Jarvis.

**Exit:** stable daily-driver release with controlled resource overhead and a reversible installer/uninstaller.

## 7. Data model (minimum)
- `HardwareSample`: timestamp, chip/model, cpu/gpu temperature nullable, fan RPM nullable, power nullable, thermalState, source, error/availability.
- `ProcessSample`: pid, startTime, ppid, executable, redactedCommand, cpuPercent, rssBytes, sampleTimestamp.
- `ContainerSample`: containerId, name, labels, image, state, cpuPercent, memoryBytes, timestamp.
- `Project`: id, name, repositoryRoot, userOverrides, attributionEvidence.
- `Incident`: id, start/end, severity, observations, inferredCause, confidence, linked processes/projects, actions.
- `ActionAudit`: timestamp, target identity, preview, user confirmation, outcome.

Store sensitive command-line arguments only if necessary, and redact secrets, tokens, environment variables and personal paths in exports.

## 8. Safety, privacy and trust boundaries
- Local-first and offline-capable; no telemetry upload without explicit consent.
- Do not require root for ordinary monitoring. Privileged helpers, if unavoidable for optional sensors, must be narrowly scoped, separately reviewed and securely installed.
- Treat private Apple APIs as unstable. Feature-detect, version-test and degrade gracefully.
- Docker socket can effectively grant host-level control; do not expose it to a remote service, web page, plugin or untrusted local process.
- No shell injection through process names, commands, repo paths or container IDs. Prefer structured APIs over shell calls.
- Do not execute cleanup based only on stale PID or a guessed project match.
- Never automatically kill a coding agent or development server; ask and explain consequences.
- No unverified claims about sensor accuracy or direct causal heat contribution.

## 9. Performance and quality gates
- Establish baseline idle CPU/memory/battery overhead and define explicit budgets before release.
- Limit sampling frequency and history size; avoid polling every process at high frequency.
- Simulate 1,000+ processes, many short-lived PIDs, unavailable sensors and Docker daemon restarts.
- Validate CPU percentage normalization across multicore hosts and containers.
- Test Docker container churn, interrupted test runs, PID reuse, sleeping/waking, network disconnection, app restart and OS upgrade.
- Verify local API cannot be accessed by unrelated web origins.
- Test that no alert or automated action terminates an active agent without consent.
- Test M3 Pro first; expand model compatibility only after hardware validation.

## 10. Prioritization / not in MVP
**Build first:** dependable collection, attribution, evidence-rich diagnosis, Docker awareness, clear UI.

**Defer:** automatic AI agents that kill processes, remote fleet monitoring, cross-device sync, fan control, kernel extensions, Apple Endpoint Security entitlement workflows, GPU-per-process accounting where unavailable, proprietary cloud inference, advanced predictive models.

## 11. Implementation workflow for the existing project
1. Read this PRD and inspect the entire relevant repository before writing code.
2. Produce a gap analysis and ADR for the native collector and UI transport.
3. Split each phase into small briefs with acceptance criteria, dependencies and rollback instructions.
4. Implement Phase 0 and Phase 1 first; validate on real hardware.
5. Keep features behind flags and preserve existing UI/functionality.
6. Run lightweight tests per change; serialize expensive integration suites rather than launching them from multiple agents.
7. Review security/privacy implications before enabling Docker access or privileged helpers.
8. Record limitations and supported hardware explicitly in the UI.
9. Demo the FDA Docker-test incident before calling Phase 3 complete.
10. Provide a final changelog, tests, known limitations and next-step brief after each phase.

## 12. Suggested instruction to the coding agent
> Read `HeatLens_PRD.md` in full. Audit the current HeatLens codebase first; do not rewrite functioning features. Produce a gap analysis and implementation briefs, then implement Phase 0 and Phase 1 in dependency order. Evaluate the linked open-source projects, their current licenses and compatibility. Prefer least-privilege native monitoring, privacy-preserving local storage and graceful fallbacks. Do not add root access, auto-kill functionality or a remotely accessible metrics endpoint. Coordinate expensive tests. Report architecture decisions, validation on Apple Silicon, limitations and acceptance-test results before advancing to the next phase.
