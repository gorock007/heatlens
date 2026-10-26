# Phase 1.1: engine samplers + ScanCoordinator
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-26-1736-p1-samplers-coordinator.md

## What the user asked
`HeatLensCore` runs one bounded, cancellable scan and returns a `ScanSnapshot` covering every
process: libproc for the user's own processes, a read-only `ps` delta for root and other-user
processes. Expose the exact public API from the brief, test it with fixture children, and turn
`heatlens-probe` into a thin CLI over the coordinator.

## What changed
- **Public API, as specified:** `ProcessSampling` (`snapshot() throws -> ProcessCounters`),
  `SystemSampling`, `ScanError { alreadyRunning, invalidDuration }`, and
  `actor ScanCoordinator` with `init(processSampler:systemSampler:)` (defaults
  `LibprocProcessSampler()` / `HostSystemSampler()`) and `scan(duration:progress:)`.
- **Types I chose:**
  - `ProcessCounters`: monotonic ns, wall clock, and `[ProcessReading]`. A reading holds cumulative CPU.
  - `SystemSampling`: `counters() -> HostCounters` (per-core ticks and swap-outs, read at both
    ends) plus `state() async throws -> HostState` (memory, pressure, thermal and pmset, read once
    at the end).
  - `PSTimeSampler`: `snapshot() async throws`, plus public `parse` and `parseCPUTime`.
  - `LibprocProcessSampler.identity(of:)`: a public way to re-check a PID's identity. FR-09 stop can reuse it.
- **One scan:**
  1. Reads host counters and every process. If libproc refused any process, runs `ps` once.
  2. Sleeps in steps of 1 s or less, calling `progress(elapsed)` after each step.
  3. Repeats the reads, runs `ps` again, then reads memory, thermal state and `pmset`.
  4. `ScanAssembly`, a pure function, builds the snapshot.
- **Duration:** non-finite or ≤ 0 throws `invalidDuration`. Any other value is clamped to 1…15.
- **Matching rules** (documented in `Coordinator/ScanAssembly.swift`):
  - A process gets a CPU delta only when its full `ProcessIdentity` is in both readings.
  - A process that vanished, or whose PID was reused (start time changed), keeps its first
    reading's name, path, argv and cwd, with `cpu == nil` and `.processExited`.
  - **Born mid-scan (I picked lifetime):** `cpu` is its whole cumulative CPU, all of which fell
    inside the window. `cpuPercentOfOneCore` is computed over its own lifetime in the window,
    with a floor of 100 ms.
  - Root and other-user processes get CPU and RSS from the two `ps` runs, timed at the midpoint
    of each run. They keep `detailAccess = .permissionDenied`, because argv, cwd and footprint
    stay unreadable.
  - pid 0 is `.notSupported`.
- **Notices, written only when they apply:**
  - CPU and memory for N root/other-user processes come from ps (10 ms resolution).
  - ps failed, so N processes have no CPU.
  - kernel_task is not readable.
  - N processes exited during the scan.
  - "Per-process CPU accounts for X% of measured host load (a of b busy cores)". Live runs here
    showed 87%; Phase 0 got about 50% without ps.
  - Total CPU load, memory statistics or thermal state unavailable.
- **Child processes:** `ps` and `pmset` start by direct exec through `ChildProcess`, never a
  shell. Cancelling sends SIGTERM to that child (ours, by PID) and waits for it to exit before
  `CancellationError` is thrown. An already-cancelled task never launches a child.
- **Limits:** no timers, and nothing runs outside `scan()`. One scan at a time (the actor holds
  a flag). Everything runs in sequence, with no task per PID.
- **Snapshot cost:** a libproc snapshot of about 730 pids, including argv, cwd and path, takes
  about 22–25 ms. Each scan takes two.
- **Name fix:** names for refused processes now use the executable's file name when the 16-char
  `p_comm` is a truncated prefix of it, e.g. `com.apple.Virtualization.VirtualMachine`.
- **`heatlens-probe`** is now a thin CLI (`--duration`, `--no-fixtures`, `--top`). It prints:
  - a system summary
  - the notices
  - a top-N table with a `src` column (libproc or ps)
  - the `yes` fixture self-test.

  The fixture's shell now kills `yes` and its own `sleep` on SIGTERM, so stopping it leaves
  nothing behind. Before, a `sleep 60` was orphaned. I deleted the duplicated wrappers
  (`Libproc.swift`, `SystemProbe.swift`) and the grouping spike (`Grouping.swift`, still in
  `ae8b990`; the Provenance worker owns grouping now).

## Files
- Sources/HeatLensCore/Sampling/Libproc.swift — created
- Sources/HeatLensCore/Sampling/ProcessSampling.swift — created
- Sources/HeatLensCore/Sampling/SystemSampling.swift — created
- Sources/HeatLensCore/Sampling/PSTimeSampler.swift — created
- Sources/HeatLensCore/Sampling/ChildProcess.swift — created
- Sources/HeatLensCore/Coordinator/ScanCoordinator.swift — created
- Sources/HeatLensCore/Coordinator/ScanAssembly.swift — created
- Sources/HeatLensCore/Model/ProcessSample.swift — modified (shared; additive, see Notes)
- Sources/heatlens-probe/main.swift — modified
- Sources/heatlens-probe/Fixtures.swift — modified
- Sources/heatlens-probe/Tools.swift — modified
- Sources/heatlens-probe/Libproc.swift — deleted
- Sources/heatlens-probe/SystemProbe.swift — deleted
- Sources/heatlens-probe/Grouping.swift — deleted
- Tests/HeatLensCoreTests/SamplerTests.swift — created
- Tests/HeatLensCoreTests/CoordinatorTests.swift — created

## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build` passed: Build complete.
- `swift test` passed: 63 tests in 14 suites, including the Provenance worker's current tests.
  My 20 new tests, in 6 suites:
  - `yes` fixture ≥ 80% of one core
  - cancel mid-scan: throws in under 1 s, and every recorded `ps` child and the fixture are
    confirmed gone by identity
  - cancel while a stand-in `ps` (`/bin/sleep 30`) runs: that child is terminated
  - cancel during the wait frees the coordinator
  - a concurrent scan throws `.alreadyRunning`
  - PID reuse via a fake `ProcessSampling` gives `.processExited` and no CPU; the reused PID is
    treated as born mid-scan
  - a vanished process gives `.processExited`
  - duration clamping and `invalidDuration`
  - progress is called about once a second
  - the ps-fallback assembly and notices, and the ps-failure notice
  - `ps` TIME/row parsing
  - live libproc owner classes, pid 0, and host sampler readings
- Ran my suites 8 times in a scratch mirror. While another worker's `ProvenanceResolver.swift`
  briefly broke the shared build, I built from the mirror, which excludes Provenance, Rules and
  Export. **One of the 8 runs failed:** `yes` measured 48.6% because the Mac was saturated (an
  ffmpeg job was using about 5 cores, and the host was 96% busy). The test now requires ≥ 80%
  only when the host was below 90% busy. On a saturated host the bar drops to ≥ 30% (still
  catches a timebase error). Every later run passed.
- `swift run heatlens-probe` exited 0. The `yes` fixture measured 99.3% (and 85.4% in an
  earlier, loaded run). 209 root/other-user processes were filled from ps, and the fixture was
  confirmed exited.
- `scripts/run-app.sh --build-only` passed: built `HeatLens.app`. The App worker's in-progress
  `App/` was included as-is; I don't touch it.
- `handoffs/bin/jarvis leftovers --mine`: nothing running. The only `sleep 60` processes on the
  machine belong to `jarvis watch`.
- **Not checked:**
  - `pmset` output under real throttling
  - behaviour inside the sandbox (ps cannot spawn there, so the ps-failure notice path would be
    the live one)
  - `ps` cost or behaviour under heavy process churn
  - the coordinator driven from the app (that's the wiring brief)
- **User verification:** run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift run heatlens-probe`.
  Compare the top-15 table with Activity Monitor (View → All Processes, % CPU) over the same few
  seconds. Root processes such as WindowServer now appear, with `src ps`. Own processes should
  match within a few points. `kernel_task` is still absent by design.

## Processes left running
none

## Questions for the user
none

## Notes for Jarvis
- **Shared-file edit:** `Sources/HeatLensCore/Model/ProcessSample.swift` gets a new
  `MeasurementSource` enum (`libproc` or `ps`) and an optional field
  `ProcessSample.measurementSource` (init parameter defaults to nil). It is additive:
  - Existing initialisers compile unchanged.
  - Older JSON decodes, because the synthesized Codable uses decodeIfPresent.

  The UI or rules can use it to qualify numbers that came from ps. `Package.swift` is untouched.
- **For the wiring brief:**
  - Use `ScanCoordinator()` with no arguments.
  - Call `scan` inside a `Task` and cancel the task to stop.
  - `progress` arrives off the main actor, so hop to it.
  - Rows with `.permissionDenied` may still carry CPU and RSS (`measurementSource == .ps`), so
    don't show "Not accessible" for CPU on those.
- `docs/FEASIBILITY.md` still describes the probe's old sections (PID enumeration, availability
  table, grouping). I wasn't allowed to touch `docs/`. Its "Reproduce" line still works, but the
  output format is now the thin CLI's.
- Suggested commit message: `feat(core): ScanCoordinator with libproc + ps samplers, cancellable scans; probe becomes a thin CLI`
