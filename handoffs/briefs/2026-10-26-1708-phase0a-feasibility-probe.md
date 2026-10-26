# Phase 0a: feasibility probe for process, system and thermal data
worker: claude
model: fable
effort: high
started: 2026-10-26 17:09 · terminal: 97400f86-99a1-4ad5-a4fb-15a06dfc1e5b

## Goal
Find out, on this M3 Pro (macOS 27.0.1, Xcode 26.6 / SDK 26.5), which public APIs give HeatLens each piece of data the PRD needs, what's visible without permissions, and what a sandbox hides. Then decide the core types Phase 1 builds on. Done means three things. First, `swift run heatlens-probe` prints a bounded-sample report. Second, `docs/FEASIBILITY.md` records what works, what doesn't, and the chosen API for each field. Third, that doc proposes the `HeatLensCore` module boundary and types. This is the PRD §8 Phase 0 gate: nothing polished gets built on guesses.

## Context
- Spec: `docs/PRD.md`. Read §4.1 (collection), §4.2 (provenance), §5 (privacy/sandbox), §8 Phase 0 and §9 (test scenarios).
- **Decided by Jarvis:** a SwiftPM package at the repo root holds the engine as library `HeatLensCore` (tested with `swift test`). An xcodegen app target in `App/`, built in parallel by another worker (`handoffs/briefs/2026-10-26-1708-phase0b-menubar-shell.md`), will link it in Phase 1. The app ships unsandboxed, direct-distribution, first. You measure what a sandbox would cost, but you don't build for it.
- Builds need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Xcode isn't selected and `swift test` fails on `Testing` without it).

## What to probe (each gets a row in FEASIBILITY.md: API, works?, caveats, verified how)
1. PID enumeration: `proc_listallpids`/`proc_listpids`. Count found vs `ps -A | wc -l`.
2. Per-process: PPID, start time (for `(pid, startTime)` identity), executable path (`proc_pidpath`), CPU time (`proc_pid_rusage` / `proc_pidinfo` taskinfo; mind Mach absolute-time units on Apple Silicon), physical footprint / RSS. Note which of these fail for other-user and root processes.
3. argv and cwd: `sysctl KERN_PROCARGS2` and `proc_pidinfo PROC_PIDVNODEPATHINFO`. Record visibility for own-user, other-user and root processes.
4. CPU %: two snapshots across a monotonic interval (default 5 s, the PRD allows 5–10). Convention: 100% = one full core, so values can exceed 100%. Sanity-check against `ps -o %cpu` / `top -l 2` for a known busy fixture (e.g. `yes > /dev/null` you spawn and stop).
5. System: total CPU load (`host_processor_info` or `host_statistics`), memory pressure level (`kern.memorystatus_vm_pressure_level` or the dispatch memory-pressure source), swap (`vm.swapusage`), compressed memory.
6. Thermal: `ProcessInfo.thermalState`, and `pmset -g therm` parsed defensively (direct `Process` exec, no shell). Record what this machine actually reports. Never fabricate a temperature.
7. Sandbox cost: ad-hoc sign a probe build with an `com.apple.security.app-sandbox` entitlement (`codesign -s - --entitlements …`) and rerun. List what disappears. If this can't run outside an app bundle, say so and why.
8. Real-world grouping: run the probe while whatever's normally running here is up (Claude Code, OpenCode, Superset, Next.js if any). Check that ancestry and argv give enough to attribute processes to a project directory and to tell `next dev` / `vitest` / `node worker.js` / claude / opencode apart. Don't start Docker or CapCut. For the PPID-1 orphan case, spawn your own detached fixture (`nohup sleep 600 &` from a subshell) and stop it by PID afterwards.

## Deliverable shape
- `Package.swift`: library `HeatLensCore`, executable `heatlens-probe`, test target `HeatLensCoreTests`. Platform: pick the macOS deployment target and justify it in the doc (the app worker is assuming 14.0; flag it if that's wrong).
- `Sources/heatlens-probe/`: spike code, fine to be rough. Any C-bridging (e.g. a `CLibproc` system-library or shim target) only if Swift can't reach an API directly. Say so in the doc.
- `Sources/HeatLensCore/`: only the primitives you're confident Phase 1 keeps, e.g. CPU-delta math and `ProcessIdentity`, plus tests for them. Keep it small.
- `docs/FEASIBILITY.md`: the table, sample output **redacted** (`~/…`, placeholder project names), the decisions, and a "Phase 1 proposal" section. That section covers the module boundary (ScanCoordinator / ProcessSampler / SystemSampler / ProvenanceResolver / RulesEngine), the shared model types (`ProcessIdentity`, `ProcessSample`, `SystemSample`, `DiagnosticFinding` from PRD §4.3), which go in `Sources/HeatLensCore/Model/`, and a suggested split into 2–4 disjoint Phase 1 briefs.

## Scope
- May touch: `Package.swift`, `Sources/`, `Tests/`, `docs/FEASIBILITY.md`, your scratchpad
- Must not touch: `App/`, `project.yml`, `scripts/`, `docs/PRD.md`, `handoffs/` (except your handoff)
- Shared files (edit minimally, name in handoff): `Package.swift` (you create it)

## Phase
Phase 0a only. No UI, no findings engine, no termination code.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30 && swift run heatlens-probe 2>&1 | tail -40`
Also confirm nothing you spawned is still running (`handoffs/bin/jarvis leftovers --mine`).

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through. Most rulings here are yours to make and record in FEASIBILITY.md.
