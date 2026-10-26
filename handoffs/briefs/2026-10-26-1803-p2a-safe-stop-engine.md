# Phase 2a: safe stop engine (FR-09): eligibility, PID revalidation, SIGTERM only
worker: claude
model: claude-opus-5-5 (amber band; fable-tier task: security-sensitive)
effort: high
started: 2026-10-26 18:02 · terminal: a20dd6fd-f9fa-47eb-bfe5-4e2dd90eb54c

## Goal
`HeatLensCore` can decide whether a process may be offered a stop, and can send **one SIGTERM to one validated process**, re-checking its identity immediately before signalling, then report what happened. The rules engine starts offering `requestStop` where it's eligible. Done means the API below exists, every denial path and the PID-reuse race are tested with fixture children, and nothing in the code can signal a process other than the validated `(pid, startTime)`.

## Context
- Spec: PRD §4.4 (every bullet is a requirement), FR-09, and §9 scenarios 5, 10 and 11. Read `AGENTS.md`'s HeatLens rule: your tests signal only children they spawned.
- **Pattern to copy:** `LibprocProcessSampler.identity(of:)` in `Sources/HeatLensCore/Sampling/ProcessSampling.swift:95` is the identity re-check. `Sources/HeatLensCore/Sampling/ChildProcess.swift` is the fixture-child pattern (spawn, then stop by PID). The `Coordinator*Tests` show fixture tests.
- Running in parallel: a Codex worker on `Sources/HeatLensCore/Provenance/`, and a Codex worker on `App/` that builds the confirmation UI against the API below. **Keep the API exactly as written.**

## Public API (exact)
```swift
public enum StopEligibility: Equatable, Sendable { case eligible, denied(reason: String) }
public enum StopOutcome: Equatable, Sendable {
    case stopped                       // exited within the wait
    case stillRunning                  // SIGTERM sent, still alive after the wait; NO escalation
    case alreadyExited                 // gone before we signalled
    case identityChanged               // pid now belongs to a different process; nothing sent
    case denied(reason: String)        // failed eligibility at revalidation; nothing sent
    case failed(errno: Int32)          // kill() failed (e.g. EPERM)
}
public struct ProcessTerminator: Sendable {
    public init()
    /// Pure: decides from a scan sample whether the UI may offer "Request stop".
    public func eligibility(of sample: ProcessSample) -> StopEligibility
    /// Revalidates identity, owner and denylist right before kill(pid, SIGTERM); then polls until exit or `wait`.
    public func requestStop(_ identity: ProcessIdentity, wait: TimeInterval = 3) async -> StopOutcome
}
```

## Rules
- **Eligible only if all of these hold:**
  - owned by the current user (`ProcessOwner` and a live re-check of the uid)
  - pid > 1, and not HeatLens itself
  - not on the denylist
  - executable path readable and not under `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`, `/usr/bin/` (Apple binaries)
  - `detailAccess == .available`
- **Denylist names:** `kernel_task`, `WindowServer`, `launchd`, `loginwindow`, `Finder`, `Dock`, `SystemUIServer`, `ControlCenter`, `coreaudiod`, `mds*`, `cfprefsd`. Each denial gives a plain reason the UI shows.
- **`requestStop`:** re-read the identity with `identity(of:)` immediately before `kill`. Nil means `.alreadyExited`. A different start time means `.identityChanged`. Re-run the eligibility checks against live data. Then exactly one `kill(pid, SIGTERM)`. **Never SIGKILL**, never a process group (no negative pid), never `pkill`/`killall`/shell, never more than one pid per call.
- **RulesEngine:** add `.requestStop(identity)` only to `staleDevServer` and `detachedWorker` findings, for the group's root process, and only when `eligibility` returns `.eligible`. `requestStop` stays absent from `highCPU` (active work) and from system kinds. Update the existing "never recommends requestStop" test to the new rule: present only on eligible review findings.

## Scope
- May touch: `Sources/HeatLensCore/Safety/` (new), `Sources/HeatLensCore/Rules/RulesEngine.swift` (the requestStop rule only), `Tests/HeatLensCoreTests/` (new `Safety*Tests.swift`, plus `RulesEngineTests.swift`)
- Must not touch: `App/`, `Sources/HeatLensCore/{Provenance,Sampling,Coordinator,Export,Pipeline}/`, `docs/`, `project.yml`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/` (shouldn't need changes)

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`
Tests, using fixture children only:
- a `sleep 60` child stops (`.stopped`)
- a child that traps SIGTERM gives `.stillRunning`, and is then cleaned up by the test
- an exited child gives `.alreadyExited`
- an identity with a wrong start time gives `.identityChanged`, nothing is sent, and the child is still alive
- eligibility denials for pid 1, a root sample, a denylisted name, an Apple path, `.permissionDenied` and self
Grep your own diff for `SIGKILL`, `killpg`, `kill(-` and `Process(` running `kill`; there must be none. Run `handoffs/bin/jarvis leftovers --mine`.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
