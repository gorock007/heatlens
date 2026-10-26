# Phase 2c: security review of safe stop + fix the hanging Safety test fixture
worker: claude
model: claude-opus-5-5 (security work prefers codex sol, but Codex 5h limit is exhausted until 22:38 and gpt-6.1-sol is unsupported on a ChatGPT account)
effort: high
started: 2026-10-26 19:16 · terminal: 84f8c803-bf43-4a48-a915-bc0d8d97ff1e

## Goal
An adversarial review of everything that can signal a process or start a child process, and of what an export can leak. Findings are ranked, each with a concrete exploit or failure scenario. **One fix is in scope:** the Safety test fixture that hangs. Done means the handoff lists verified findings (or says none survived), the fixture can't hang, and the Safety suites pass 10 runs in a row under a timeout.

## Context
- Spec: PRD §4.4, §5, FR-09, FR-10, FR-11; `AGENTS.md` (the HeatLens rules about signalling and real scan output).
- Merged handoffs to read: `handoffs/merged/2026-10-26-1809-p2a-safe-stop-engine.md` (engine, including its "residual race" note) and `handoffs/merged/2026-10-26-1816-p2b-detail-stop-settings-ui.md` (UI flow).
- **Files to review:**
  - `Sources/HeatLensCore/Safety/ProcessTerminator.swift`
  - the requestStop rule in `Sources/HeatLensCore/Rules/RulesEngine.swift`
  - `Sources/HeatLensCore/Sampling/ChildProcess.swift` and `PSTimeSampler.swift` (exec of `ps`/`pmset`)
  - `Sources/HeatLensCore/Export/Redactor.swift`
  - `App/StopService.swift`, plus the stop sheet in `App/ResultsView.swift` and `App/ProcessDetailView.swift`
  - `App/SettingsModel.swift` (exclusions must never widen what can be stopped)
- **Known bug (fix it):** `swift test --filter 'Safety|RulesEngine'` hung for over 10 minutes in `SafetyTerminatorTests.identityChanged`, then its `defer`, then `FixtureChild.stop()`. The unbounded `process.waitUntilExit()` at `Tests/HeatLensCoreTests/SafetyTerminatorTests.swift:62` never returned. Replace it with a bounded wait (a deadline on `isRunning`, or a `terminationHandler` with a semaphore timeout). No unbounded wait may remain anywhere in `Tests/HeatLensCoreTests/Safety*`.

## What to look for, at least
- Any path to a signal for a process other than the validated `(pid, startTime)`: TOCTOU between the scan and the click, a stale `ProcessIdentity` held by the UI, pid ≤ 1 or a negative pid, or an integer conversion.
- Any path where the eligibility check is skipped, or done on scan data only.
- Escalation (SIGKILL, retries) or repeated sends.
- Denylist and Apple-path bypasses: symlinked or relative paths, a case trick, a renamed binary, `/private/var/...`, a translocated app.
- Child exec: shell injection, PATH lookup, an inherited environment that matters, a leaked child on cancel.
- Redactor leaks: the username in non-home paths, argv inside evidence strings, tokens inside cwd paths, and the JSON report.
- UI: whether the destructive action can trigger without the confirmation (keyboard shortcuts, the default button, double-click).

## Scope
- May touch: `Tests/HeatLensCoreTests/SafetyTerminatorTests.swift`, `Tests/HeatLensCoreTests/SafetyEligibilityTests.swift` (the fixture fix only)
- Must not touch: everything else. **Report** issues; don't fix them (Jarvis briefs the fixes). Don't create files or folders inside the repo; build with `swift build --scratch-path "$(mktemp -d)"` if the shared `.build` is locked. Never run git commands that change state. Signal only test-spawned children.
- Shared files: none

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`
- `for i in $(seq 10); do timeout 120 swift test --filter 'Safety' 2>&1 | tail -1; done`: all 10 must pass. `timeout` may not exist on macOS; use `perl -e 'alarm 120; exec @ARGV' swift test …` instead.

## Handoff format for findings
Under **Notes for Jarvis**: a numbered list, most severe first. Each entry gives severity (high/medium/low), `file:line`, the failure scenario in one or two sentences, and a suggested fix. Separate "verified (reproduced or proven from code)" from "plausible". If nothing survives, say so plainly.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
