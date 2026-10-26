# Phase 2a: safe stop engine (FR-09): eligibility, PID revalidation, SIGTERM only
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-26-1803-p2a-safe-stop-engine.md

## What the user asked
`HeatLensCore` decides whether a process may be offered a stop. It sends one SIGTERM to one
validated `(pid, startTime)`, re-checking identity right before the signal, and reports what
happened. The rules engine offers `requestStop` only on eligible leftover findings.

## What changed
- **`Sources/HeatLensCore/Safety/ProcessTerminator.swift`** (new) contains the brief's public API, unchanged:
  `StopEligibility`, `StopOutcome`, and `ProcessTerminator` with `init()`, `eligibility(of:)` and
  `requestStop(_:wait:)`.
- **`eligibility(of:)`** is pure. It checks these in order and returns the first plain-words reason that applies:
  1. pid ≤ 1
  2. HeatLens itself (`getpid()`)
  3. A denylisted name: `kernel_task`, `WindowServer`, `launchd`, `loginwindow`, `Finder`, `Dock`,
     `SystemUIServer`, `ControlCenter`, `coreaudiod`, `cfprefsd`, plus any name starting with `mds`.
     Matching ignores case and checks both the process name and the executable's file name.
  4. Owner is not `.currentUser`. root, another user and unknown each get their own reason.
  5. The executable path is missing or empty.
  6. The path is under `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/` or `/usr/bin/`.
  7. `detailAccess` is not `.available`.
- **`requestStop`** runs these steps:
  1. A `pid > 1` guard comes first, before any lookup.
  2. It reads `LibprocProcessSampler.identity(of:)` and `proc_pidinfo`:
     - nil → `.alreadyExited`
     - a different start time → `.identityChanged`
     - a **zombie** → `.alreadyExited`. libproc returns ESRCH for a zombie while sysctl still lists it. I checked this on this Mac.
  3. It checks the uid live: it must be non-zero and equal `getuid()`.
  4. It re-runs `eligibility(of:)` on a sample built from live kernel data: name, path, uid, and whether task info is readable.
  5. It re-checks identity a final time.
  6. It calls `kill(pid, SIGTERM)` exactly once. ESRCH → `.alreadyExited`. Any other errno → `.failed(errno:)`.
  7. It polls every 50 ms until the process exits, which means gone, a zombie or a reused pid (→ `.stopped`), or until `wait`
     runs out (→ `.stillRunning`). `wait` is clamped to 0…60 s. A cancelled task stops polling early
     and reports `.stillRunning`. Nothing is ever sent a second time.
  - Another user's process, where libproc refuses details at revalidation, returns `.denied`, and nothing is sent.
  - The code has no shell, no `Process`, no process groups, and no signal other than SIGTERM.
- **RulesEngine:** `staleDevServer` and `detachedWorker` findings add `.requestStop(group.root)` as their
  last action. They add it only when the root's sample is `.eligible`. `highCPU`, the system findings and
  the WindowServer/kernel_task findings never carry it.
- **Residual race, inherent to macOS:** a pid could be reused in the microseconds between the
  final identity check and `kill()`. There is no pidfd on macOS. Pids are allocated in increasing
  order up to 99999 before they wrap, so this needs a full pid wraparound inside that window.

## Files
- Sources/HeatLensCore/Safety/ProcessTerminator.swift — created
- Sources/HeatLensCore/Rules/RulesEngine.swift — modified (requestStop rule only)
- Tests/HeatLensCoreTests/SafetyTerminatorTests.swift — created
- Tests/HeatLensCoreTests/SafetyEligibilityTests.swift — created
- Tests/HeatLensCoreTests/RulesEngineTests.swift — modified
- handoffs/2026-10-26-1809-p2a-safe-stop-engine.md — created

## Checks run
- **Isolated copy** (HEAD plus only my 5 files, in my scratchpad, because the Provenance worker's file was
  deleted mid-edit in the shared checkout): `swift build` completed and `swift test` passed **87 tests in 17 suites**.
  I ran the fixture suite 5 more times and got 7/7 each time.
- **Shared checkout**, after the Provenance file came back:
  - `swift build`: Build complete.
  - `swift test`: 87 tests. All Safety and Rules suites pass. **3 failures, all in `ProvenanceResolverTests`**
    (group label, superset group, argv-path project). They belong to the parallel Provenance worker's
    in-progress edits; my files don't touch that code.
- `scripts/run-app.sh --build-only` built `HeatLens.app`.
- **Fixture tests.** They signal only children the test spawned:
  - `sleep 60` → `.stopped`, then gone.
  - A `/bin/sh` that traps TERM and prints "ready" (so the trap is in place before the signal) → `.stillRunning`.
    It is still alive 200 ms later, and the test then stops it by closing its stdin.
  - An exited child → `.alreadyExited`.
  - A wrong start time → `.identityChanged`, and the child is still alive.
  - A live `/usr/bin/head` child → `.denied` ("Apple"), and the child is still alive.
  - pid 1, 0 and -1 → `.denied`.
  - Live self-eligibility → denied with "HeatLens itself". This only checks eligibility; the test never calls `requestStop` on itself.
- **Pure eligibility tests** cover pid 1 and 0, self, root/other/unknown owners, all 11 denylisted names plus
  `mds_stores`/`mdsync`, a denylisted executable name, all 5 Apple path prefixes, a nil or empty path, and
  `.permissionDenied`/`.processExited`/`.notSupported`.
- **Rules tests:**
  - The old "never recommends requestStop" test is now "requestStop only on eligible review findings, for the group root". It covers 6 snapshots, including system and pressure findings.
  - New: the stale and detached findings carry a stop and highCPU findings never do.
  - New: a detached worker whose root is root-owned, under `/usr/bin` or has no path gets no stop.
- **Grep** for `SIGKILL|killpg|kill\(-|Process\(|pkill|killall|/bin/kill` over my diff:
  - The engine has none.
  - The only hit is `Process()` in the test fixture. It launches `/bin/sleep`, `/bin/sh` or `/usr/bin/head`, never `kill`.
- `handoffs/bin/jarvis leftovers --mine`: nothing running. The two `sleep 60` processes on the
  machine belong to `jarvis watch`.
- **Not checked:** stopping anything from the app. The App worker owns that UI, and the App still uses
  its own stub (see below). Signalling a real non-fixture process was deliberately not tried.
- **User verification:** run
  `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test --filter "Safety|RulesEngine"`
  and expect every Safety and Rules test to pass. You'll see a confirmation UI only after the App worker's branch drops its stub.

## Processes left running
none

## Notes for Jarvis
- **`App/StopEngineStub.swift`** (the App worker's file, which I didn't touch) declares App-local copies of `StopEligibility`,
  `StopOutcome` and `ProcessTerminator`. These always deny. They shadow the real HeatLensCore types, so the app builds but
  never stops anything until that stub is deleted. The real API matches the stub's signatures exactly.
- No shared-file edits. `Findings.swift`'s comment "Phase 2 implements `requestStop`" is now slightly
  stale. I left it alone because it's a shared file.
- Suggested commit message: `feat(core): safe stop engine — eligibility, live PID revalidation, single SIGTERM; requestStop on eligible leftovers (Phase 2a)`
