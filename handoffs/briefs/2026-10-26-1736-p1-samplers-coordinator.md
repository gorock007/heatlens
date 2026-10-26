# Phase 1.1: engine samplers + ScanCoordinator
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-26 17:38 · terminal: cfc4cdd5-06b3-4a80-8532-bfca93e7dffd

## Goal
`HeatLensCore` can run one bounded, cancellable scan and return a `ScanSnapshot` (the existing type in `Sources/HeatLensCore/Model/SystemSample.swift`). It covers every process, using libproc for the user's own processes and a read-only `ps` delta for the root and other-user processes libproc refuses. Done means the public API below exists, is tested with fixture child processes, and `heatlens-probe` prints its top-15 table from the coordinator.

## Context
- Read first: `docs/FEASIBILITY.md` ("Summary of decisions", "Chosen API per field", "Phase 1 proposal"), the previous handoff `handoffs/merged/2026-10-26-1733-phase0a-feasibility-probe.md`, and the model types in `Sources/HeatLensCore/Model/`.
- **Pattern to copy:** `Sources/heatlens-probe/Libproc.swift` and `SystemProbe.swift` already wrap every call. Port them into the library and don't re-derive anything. CPU math is in `Sources/HeatLensCore/Sampling/CPUMath.swift` (Mach ticks × timebase, 100 = one core).
- Two other workers run in parallel. One owns `Sources/HeatLensCore/{Provenance,Rules,Export}/` (pure functions over `ScanSnapshot`). The other owns `App/`, which renders a fixture report until a later brief wires in your coordinator.

## Public API (exactly this; the wiring brief depends on it)
```swift
public protocol ProcessSampling: Sendable { func snapshot() throws -> ProcessCounters }   // one point-in-time read
public protocol SystemSampling: Sendable { … }                                            // your shape
public enum ScanError: Error, Equatable { case alreadyRunning, invalidDuration }
public actor ScanCoordinator {
    public init(processSampler: some ProcessSampling = LibprocProcessSampler(), systemSampler: some SystemSampling = HostSystemSampler())
    /// duration clamped to 1...15 s (PRD offers 5/10/15). progress is called about once a second with elapsed seconds.
    /// Throws CancellationError if the calling Task is cancelled (returns within ~1 s), ScanError.alreadyRunning if a scan is in flight.
    public func scan(duration: TimeInterval, progress: @escaping @Sendable (TimeInterval) -> Void) async throws -> ScanSnapshot
}
```
`ProcessCounters` and the sampler type names are yours. Keep them in `Sampling/`.

## Behaviour
- Bracket the interval with two snapshots. A process is matched across the two only when the full `ProcessIdentity` matches. A PID whose start time changed (PID reuse), or that vanished, gets no CPU delta and `detailAccess = .processExited`. A process born mid-scan gets CPU over its own lifetime in the window, or nil; pick one and document it.
- `PSTimeSampler` runs `/bin/ps -A -o pid=,time=,rss=` via `Foundation.Process` with a direct exec (never a shell), twice, and fills CPU/RSS only for PIDs libproc refused. A cancelled scan must terminate a running `ps` child, leaving no orphan.
- Fill `notices` honestly: e.g. "CPU for N root/other-user processes is from ps (10 ms resolution)", "Per-process CPU accounts for X% of measured host load", and "Thermal state unavailable" where that applies.
- No timers or work outside `scan()`. At most one scan at a time. Limit concurrency (no task per PID).
- Turn `heatlens-probe` into a thin dev CLI over `ScanCoordinator`, with a top-15 table and system summary, and delete its duplicated wrappers. Keep its fixture self-test if it's cheap.

## Scope
- May touch: `Sources/HeatLensCore/Sampling/`, `Sources/HeatLensCore/Coordinator/`, `Sources/heatlens-probe/`, `Tests/HeatLensCoreTests/` (new files named `Sampler*Tests.swift` / `Coordinator*Tests.swift` only), scratchpad
- Must not touch: `App/`, `project.yml`, `Sources/HeatLensCore/{Provenance,Rules,Export,Parsing}/`, `docs/`
- Shared files (edit minimally, name in handoff): `Package.swift`, `Sources/HeatLensCore/Model/` (additive only: new optional fields with defaults, no renames)

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30 && swift run heatlens-probe 2>&1 | tail -25`
Tests must cover the following:
- A `yes` fixture measures ≥ 80% of one core.
- Cancelling mid-scan throws within ~1 s and leaves no `ps`/fixture child (check by PID).
- A second concurrent `scan` throws `.alreadyRunning`.
- PID reuse, via a fake `ProcessSampling` whose start time changes, yields `.processExited` and no CPU.
- Duration clamping.
Fixtures are spawned and stopped by the test, by PID. Run `handoffs/bin/jarvis leftovers --mine` before handing off. Never paste raw probe output into the repo.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
