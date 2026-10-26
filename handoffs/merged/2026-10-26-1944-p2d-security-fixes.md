# Phase 2d: fix the security review's low findings (export redaction, /bin denylist, bounded waits, double-dispatch)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-26-1937-p2d-security-fixes.md

## What the user asked
Fix every finding in the Phase 2c security review except finding 5, with a test for each where one is possible. Also apply Jarvis's ruling that an exclusion suppresses the stop offer.

## What changed
1. **Script names no longer leak into exports (finding 1).**
   - The fix is in the Redactor, as the brief asked. For every group whose kind ends in ` script` (today only `node script`), the exported label becomes `<tool> <script>`, for example `node <script>`.
   - The same replacement applies to every finding title, explanation, evidence value, notice and project path in both reports.
   - The app still shows the real label locally.
2. **Secrets in paths and free text are redacted (finding 2).**
   - Any path component or word that looks like a credential exports as `<redacted>`. That means one of these:
     - it contains `ghp_`/`gho_`, `xox[abpr]-`, `sk-` plus 16 or more characters, or `AKIA` plus 16 characters (the prefix can't follow a letter or digit, so `task-runner` survives)
     - it contains a hex run of 32 or more characters
     - it contains a run of 32 or more base64-ish characters that mixes upper case, lower case and digits
   - This applies everywhere `text()` runs, so it covers cwd, the project directory, `openProject` paths, evidence and notices.
   - The free-text option regex is now the review's two patterns:
     - `-{1,2}[\w-]*(token|key|password|passwd|secret)[\w-]*` followed by `=value`, or by a value that isn't another flag
     - `\b[A-Z_]*(TOKEN|KEY|SECRET|PASSWORD)=\S+`
   - A short `-p value` is redacted only when the same text also has a password-ish option (for example `mysql --ask-password -p x`). So `vite -p 3000` survives.
3. **The username is replaced only as a whole word or path component (finding 8).** With the username `al`, `/usr/local` survives.
4. **`/bin/` and `/Library/Apple/` are now on the Apple denylist (finding 3).**
   - `SafetyEligibilityTests` now asserts these are denied: `/bin/sleep`, `/bin/zsh`, `/bin/launchctl` and a `/Library/Apple/` path.
   - The terminator fixtures now spawn copies of `/bin/sleep` and `/bin/bash` in a per-fixture temp directory, and remove the directory in `stop()`.
   - **Two deviations from the brief, both forced by macOS:**
     - **Ad-hoc signing.** This macOS SIGKILLs a plain copy of an Apple platform binary at launch (exit 137). So the fixture ad-hoc signs each copy with `/usr/bin/codesign --force --sign -` before running it. That signature has no identity: it is not the "real identity" signing that only Jarvis may do. `codesign` is our own child, and its wait is bounded at 10 s.
     - **`bash`, not `sh`.** `/bin/sh` is a trampoline that re-execs the shell selected in `/private/var/select/sh`, which here is `/bin/bash`. So a copied `sh` still ran from `/bin/` and was denied. The shell fixtures therefore copy `/bin/bash`.
   - The `/usr/bin/head` revalidation test is unchanged.
5. **No `waitUntilExit()` remains in Sources or Tests (finding 4).**
   - `BusyFixture` in `SamplerTests` and the probe's `Fixtures.stopAll()` record the shell's `(pid, startTime)` at launch.
   - They SIGTERM the shell only while the kernel still lists that exact instance, then poll with a deadline.
   - I added a shared test helper, `terminateOwnChild(_:identity:timeout:)`, next to `waitUntilGone`.
6. **No double dispatch (finding 6).** `guard case .confirmation = phase else { return }` is now the first line of `StopFlowView.requestStop()`. `phase = .stopping` was already set synchronously before the `Task`/`await`, and still is.
7. **Each child process now has a deadline (finding 7).**
   - `ChildProcess.run` takes a `deadline`, 5 s by default. At the deadline it SIGTERMs our child (only if the run hasn't finished and wasn't cancelled) and throws `ChildProcess.TimedOut`, for example "/usr/bin/pmset did not finish within 5 s".
   - Cancellation still takes priority over a timeout.
   - For `ps`, the existing `readFallback` turns the timeout into the existing ps-failed notice.
   - For `pmset`, there is no pmset data. `HostState` has a new `pmsetNotice` field, and `ScanAssembly` appends it to the scan notices.
8. **An exclusion also suppresses the stop offer (Jarvis ruling).**
   - `ReportContext` now carries the IDs of the findings hidden by the user's exclusions.
   - `ProcessDetailView` shows "Excluded in Settings" in place of **Request stop** (and in place of the "Stop unavailable" line) when every finding for that process is hidden.

## Files
- App/ProcessDetailView.swift — modified
- App/ResultsView.swift — modified
- Sources/HeatLensCore/Coordinator/ScanAssembly.swift — modified (outside "may touch", see Notes)
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Sources/HeatLensCore/Safety/ProcessTerminator.swift — modified
- Sources/HeatLensCore/Sampling/ChildProcess.swift — modified
- Sources/HeatLensCore/Sampling/PSTimeSampler.swift — modified
- Sources/HeatLensCore/Sampling/SystemSampling.swift — modified
- Sources/heatlens-probe/Fixtures.swift — modified
- Tests/HeatLensCoreTests/CoordinatorTests.swift — modified
- Tests/HeatLensCoreTests/RedactorTests.swift — modified
- Tests/HeatLensCoreTests/SafetyEligibilityTests.swift — modified
- Tests/HeatLensCoreTests/SafetyTerminatorTests.swift — modified
- Tests/HeatLensCoreTests/SamplerTests.swift — modified
- handoffs/2026-10-26-1944-p2d-security-fixes.md — created

## Checks run
- **`export DEVELOPER_DIR=… && swift build && swift test`, three runs:** **98 tests in 17 suites passed** each time, in about 4.0 s. There were 92 tests before; 6 are new.
- Each run was under a process-group timeout wrapper: it `setpgrp`s, then TERMs and KILLs the group. This avoids review finding 5. The wrapper is in my scratchpad: `/private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/f5dcf503-df97-49d1-a464-3623f48c0a23/scratchpad/timeout.pl`.
- **Stress run:** 10 of 10 runs of `swift test --filter 'Safety|Sampler|Redact'` passed.
- **New tests:**
  - **Finding 1:** the review's `sync-ghp_FAKETOKEN123.js` repro exports as `node <script>` in the title and explanation, and `FAKETOKEN123` is in neither report.
  - **Finding 2:** for `~/clients/acme-merger/ghp_FAKETOKEN456` as the cwd, the evidence and the `openProject` path, plus `--auth-token=`, `API_TOKEN=`, `--ask-password -p x`, AKIA, xoxb, sk-, hex and base64, nothing leaked. `vite -p 3000`, `task-runner` and a long all-lowercase project name survived.
  - **Finding 8:** with the username `al`, `/usr/local/bin/node` survives and `al` and `Al's` become `<user>`.
  - **Finding 7:**
    - With a `/bin/sleep 30` stand-in and a 1 s deadline, `ps` throws `TimedOut` in under 3 s and the child is gone.
    - The same stand-in for `pmset` gives `pmset == nil` and the notice.
    - `ScanAssembly` carries the notice into the snapshot.
- **No temp directories left behind:** 0 `heatlens-fixture-*` directories remain in the user temp dir after the runs.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- `handoffs/bin/jarvis leftovers --mine`: nothing running.
- **Not checked:**
  - I didn't click anything in the app. The double-click guard and "Excluded in Settings" compile, but I haven't seen them on screen.
  - The `BusyFixture` ready-line read (`availableData` loop in `SamplerTests`) is still unbounded. It wasn't in the findings and it didn't hang in any run.

**How to verify in the app:**
1. Run `scripts/run-app.sh`.
2. Exclude a project in Settings, scan while a node script from that project is hot, and open the process: it should say "Excluded in Settings" with no **Request stop**.
3. Then press **Copy JSON**: a node script's group should read `node <script>`.

## Processes left running
none

## Notes for Jarvis
- **Edit outside "may touch":** `Sources/HeatLensCore/Coordinator/ScanAssembly.swift`, 3 lines. The brief asks for the pmset timeout to surface as a notice, and `ScanAssembly.notices` is the only place notices are built, so there was no way around it. `Coordinator/` isn't on the must-not-touch list.
- **No shared files touched:** nothing in `Model/`, `Package.swift` or `project.yml`.
  - `HostState` (in `SystemSampling.swift`) gained a public `pmsetNotice: String? = nil`.
  - Its existing initializer calls still compile because the new parameter defaults to nil.
- **Ad-hoc codesign in the tests:** the terminator fixtures run `codesign --sign -` on temp copies of `/bin/sleep` and `/bin/bash`. That is ad-hoc, with no identity and no keychain access, but worth knowing about.
- **Suggested commit message:** `fix(core): redact script labels and credential paths in exports, deny /bin, bound child and fixture waits (Phase 2d security fixes)`
