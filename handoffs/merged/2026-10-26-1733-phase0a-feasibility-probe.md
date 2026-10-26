# Phase 0a: feasibility probe for process, system and thermal data
status: done
agent: claude fable
brief: handoffs/briefs/2026-10-26-1708-phase0a-feasibility-probe.md

## What the user asked
Find out on this M3 Pro (macOS 27.0.1, Xcode 26.6) which public APIs give HeatLens each PRD
field, what is visible without permissions and inside the sandbox, and decide the core types
Phase 1 builds on. Deliverables: `swift run heatlens-probe` printing a bounded-sample report,
`docs/FEASIBILITY.md`, and the `HeatLensCore` package with the primitives Phase 1 keeps.

## What changed
- New SwiftPM package at the repo root (`Package.swift`, macOS 14.0, Swift 6 language mode):
  library `HeatLensCore`, executable `heatlens-probe`, tests `HeatLensCoreTests`. No C shim
  is needed; every libproc/Mach/sysctl call is reachable from Swift via `Darwin`.
- `heatlens-probe` runs one 5 s (configurable 1–15 s) sample and prints: PID enumeration
  agreement across three sources, a per-field availability table by process owner with errnos,
  CPU % per process (100 = one core) cross-checked against a `yes` fixture and `ps`, host CPU,
  memory/swap/pressure, thermal state + `pmset -g therm`, and a grouping pass over the user's
  own processes (ancestry, argv, cwd, project guess, PPID-1 candidates). It spawns two fixtures
  (`yes >/dev/null`, a launchd-adopted `sleep`), both self-terminating after 60 s, and stops
  them by PID after re-checking `(pid, start time)`, which is the FR-09 pattern.
- `docs/FEASIBILITY.md`: the availability table, decisions, redacted sample output, deployment
  target rationale, chosen API per field, and the Phase 1 proposal (module boundary, model
  types, a split into 3 disjoint briefs plus an optional 4th).
- Headline findings (details in the doc):
  1. Unsandboxed, `proc_pidinfo`/`proc_pid_rusage`/`KERN_PROCARGS2` return EPERM for root and
     other-user processes. Only `proc_pidpath` and `sysctl KERN_PROC_ALL` cover everyone. So
     `kernel_task`, `WindowServer` and all root daemons have no CPU/memory from libproc; a
     read-only `ps -A -o pid=,time=` run twice is the fallback (ps carries Apple's private
     task-port entitlement and does report them). The per-process CPU sum covered only ~half
     of the host load in the runs, which the UI must say.
  2. Sandboxed (tested from a scratch `.app` bundle; a bare sandboxed binary is killed at
     launch): `proc_listallpids` EPERM, `proc_pid_rusage` self-only (no footprint), `ps` cannot
     be spawned; own-process `proc_pidinfo`, argv, cwd, host CPU, memory, thermal, pmset still
     work. Confirms unsandboxed direct distribution for v1.
  3. CPU math verified: taskinfo and rusage ticks (Mach absolute time, timebase 125/3) agree
     with each other on every process, and with `ps`/`top` on the fixture (99.7 vs 99.5 %).
  4. `pmset -g therm` on this machine prints only "No … recorded" notes, no limit values;
     `ProcessInfo.thermalState` (`nominal`) is the only thermal source. Memory pressure sysctl is
     live (flipped normal → warning under CapCut load) while swap sits at 8.5 of 10 GB.
  5. The PRD's incident is live on this Mac and the probe attributes it: a 2d 6h `node
     …/scripts/worker.js` with PPID 1 and a project cwd, plus `npm run dev → next dev →
     next-server` for a portfolio project, plus claude/opencode agents under Superset with
     project cwds. argv contains full agent prompts, so exports must redact beyond argv[0].
- `HeatLensCore` contents: `ProcessIdentity`, `MachTimebase`/`CPUTime`/`CPULoadTicks`/`CPUMath`,
  `ProcArgsParser` (never decodes the environment), `PmsetThermParser`, and the Phase 1 model
  types `ProcessSample`, `SystemSample`/`MemorySnapshot`/`ScanSnapshot`, `DiagnosticFinding`
  + `Severity`/`Confidence`/`Evidence`/`SuggestedAction`, `ProcessGroup`/`ProjectAttribution`.
  I landed the model types (beyond the brief's "keep it small") so the Phase 1 briefs can run
  disjoint; they are a first cut, additive changes expected.
- Deployment target: macOS 14.0 confirmed; the app worker's assumption is right.

## Files
- Package.swift — created (shared file; this is its first version)
- Sources/HeatLensCore/Model/ProcessIdentity.swift — created
- Sources/HeatLensCore/Model/ProcessSample.swift — created
- Sources/HeatLensCore/Model/SystemSample.swift — created
- Sources/HeatLensCore/Model/Findings.swift — created
- Sources/HeatLensCore/Sampling/CPUMath.swift — created
- Sources/HeatLensCore/Parsing/ProcArgsParser.swift — created
- Sources/HeatLensCore/Parsing/PmsetThermParser.swift — created
- Sources/heatlens-probe/main.swift — created
- Sources/heatlens-probe/Libproc.swift — created
- Sources/heatlens-probe/SystemProbe.swift — created
- Sources/heatlens-probe/Fixtures.swift — created
- Sources/heatlens-probe/Grouping.swift — created
- Sources/heatlens-probe/Tools.swift — created
- Tests/HeatLensCoreTests/ProcessIdentityTests.swift — created
- Tests/HeatLensCoreTests/CPUMathTests.swift — created
- Tests/HeatLensCoreTests/ProcArgsParserTests.swift — created
- Tests/HeatLensCoreTests/PmsetThermParserTests.swift — created
- Tests/HeatLensCoreTests/ModelCodableTests.swift — created
- docs/FEASIBILITY.md — created

## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build` — Build complete.
- `swift test` — 25 tests in 6 suites passed.
- `swift run heatlens-probe` — ran to "done", exit 0; fixtures confirmed exited. Six further
  runs during the phase (5 s ×3, 10 s no-fixture, 4 s with concurrent `top`, 3 s sandboxed ×3).
- Sandbox: `codesign -s - --entitlements` (app-sandbox) on a scratch `.app` copy of the probe;
  bare-binary variant crashed (crash report read), bundle variant ran; output in the doc.
- `handoffs/bin/jarvis leftovers --mine` — nothing running.
- Not checked: `pmset` output under real throttling (never happened here); E/P core order in
  `host_processor_info`; behaviour under a Developer ID / hardened-runtime signature; the
  `ps` fallback was only exercised for a single `ps -A` read, not as a two-run delta.
- User verification: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift run heatlens-probe`
  then compare the "top 15 by CPU" table with Activity Monitor's CPU column (View → All
  Processes, sorted by % CPU) over the same few seconds. Expect own-user processes to match
  within a few points; root processes (kernel_task, WindowServer) are absent from the probe's
  table by design, which is finding 1.

## Processes left running
none

## Questions for the user
none (status done; rulings recorded in docs/FEASIBILITY.md "Summary of decisions")

## Notes for Jarvis
- Shared file created: `Package.swift`. The 0b worker must not add the app to it; the app stays
  an xcodegen target that links `HeatLensCore` in Phase 1.
- The redacted sample in the doc uses `<project-a/b/c/d>`; the raw probe output on this Mac
  prints real project paths and agent argv (including prompts). Don't paste raw runs into the repo.
- Phase 1 split proposed in the doc: (1) samplers + ScanCoordinator, (2) ProvenanceResolver +
  RulesEngine + Redactor, (3) popover wired to the coordinator, (4 optional) ps-fallback polish
  and XPC-service attribution. Model types already exist so 1–3 can start together.
- Suggested commit message: `feat(core): Phase 0a feasibility probe, HeatLensCore primitives and model types, FEASIBILITY.md`
- Scratch artifacts (sandbox bundle, run logs) live only in this worker's scratchpad.
