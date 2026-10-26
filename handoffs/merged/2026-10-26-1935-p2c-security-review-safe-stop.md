# Phase 2c: security review of safe stop + fix the hanging Safety test fixture
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-26-1823-p2c-security-review-safe-stop.md

## What the user asked
An adversarial review of everything that can signal a process, start a child process, or leak data through an export, with findings ranked by severity. One fix was in scope: the Safety test fixture that hangs.

## What changed
- **Fixture hang: root cause found and fixed.**
  - I reproduced the hang on the unmodified tests. `--filter 'Safety|RulesEngine'` hung in **6 of 10** runs.
  - I sampled a hung run. It was stuck in `identityChanged` → `defer` → `FixtureChild.stop()` → `-[NSConcreteTask waitUntilExit]`, blocked in `mach_msg`.
  - The child had **already exited and been reaped**: the test helper had no child processes left. So Foundation's `waitUntilExit()` misses the exit when it's called from a Swift-concurrency cooperative thread. Nothing was wrong with the child.
- **`FixtureChild` no longer calls `waitUntilExit()` anywhere.**
  - `stop()` closes stdin, then waits up to 1 s for the exact `(pid, startTime)` to leave the kernel's process list.
  - If it's still there, it SIGTERMs our own child through `Process.terminate()`. That happens only while the kernel still lists that same instance, so the signal can't reach a reused pid. It then waits up to 2 s more.
  - It returns true or false and never blocks longer than about 3 s.
- **The init failure path** waits for `isRunning` with a 2 s deadline.
- **The ready-line read** used to be an unbounded `availableData` loop. It's now a `poll(2)` loop with a 5 s deadline. A child that never prints is stopped, and the fixture throws `FixtureError.notReady`.
- **No test logic or assertions changed.** `SafetyEligibilityTests.swift` needed nothing: it has no waits.

## Files
- Tests/HeatLensCoreTests/SafetyTerminatorTests.swift — modified
- handoffs/2026-10-26-1935-p2c-security-review-safe-stop.md — created

## Checks run
- **Before the fix:** 10 runs of `swift test --filter 'Safety|RulesEngine'` under a 90 s alarm. **4 passed and 6 hung.**
- **After the fix:**
  - **20 of 20** runs of `--filter 'Safety|RulesEngine'` passed, with a 120 s process-group timeout. Each took about 1.35 s.
  - **10 of 10** runs of `--filter 'Safety'` passed in the shared `.build` (16 tests in 2 suites, about 1.33 s each).
- **`export DEVELOPER_DIR=… && swift build && swift test`:** Build complete. **92 tests in 17 suites passed.**
- **`scripts/run-app.sh --build-only`:** built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- **Grep of `Tests/HeatLensCoreTests/Safety*`:** no `waitUntilExit`, `availableData`, `readDataToEndOfFile` or bare semaphore wait remains. The one `while true` returns at its deadline.
- **Review experiments** ran in a throwaway SwiftPM package in my scratchpad that depends on this repo by path. Nothing was created in the repo.
  - I ran `Process` children through differently cased and `..` paths (for example `/USR/BIN/tail`). In each case I read `proc_pidpath` and the live eligibility.
  - I checked for leaked file descriptors with `lsof`.
  - I ran synthetic provenance and rules scenarios to see which process a stop targets.
  - I ran the Redactor on synthetic argv and cwd strings carrying fake secrets and fake tokens.
  - Every signal went only to children my own code spawned.
- **Not checked:**
  - I did not click anything in the app UI. The double-click and sheet findings below are reasoned from code.
  - I did not stop any real process.
- `handoffs/bin/jarvis leftovers --mine`: nothing running.

## Processes left running
none

## Notes for Jarvis

### Findings, most severe first

No high- or medium-severity issue survived. The engine's core invariants hold:
- one `kill(pid, SIGTERM)` per call, to a positive pid > 1
- live revalidation of `(pid, startTime)` and uid right before the signal
- no SIGKILL, no `killpg`, no shell

**Verified (reproduced, or proven from code):**

1. **low** — `Sources/HeatLensCore/Provenance/ProvenanceResolver.swift:222`
   - **Problem:** a script's file name, which comes from argv, leaks into exports. A node script group is labelled `node <script basename>`.
   - **Where it shows up:**
     - The label is exported unredacted as the group label (`Redactor.swift:35`, `:176`).
     - It also appears in finding titles (`RulesEngine.swift:75`, "Sustained high CPU: \(group.label)").
     - The same value in the "Workload label" evidence is redacted, so the two are inconsistent.
   - **Reproduced:** argv `node ~/clients/acme-merger/sync-ghp_FAKETOKEN123.js` gave `"label" : "node sync-ghp_FAKETOKEN123.js"` in both the JSON and the text report.
   - **Suggested fix:** in the Sanitizer, treat labels whose classification source is argv like argv evidence. For example, export the kind (`node script`) in place of the label, or replace the basename with `<script>`.

2. **low** — `Sources/HeatLensCore/Export/Redactor.swift:218-240`
   - **Problem:** path segments in cwd and project paths are never checked for secrets. Only the home prefix and the username are replaced.
   - **Reproduced:** a cwd of `~/clients/acme-merger/ghp_FAKETOKEN456` was exported as-is in:
     - the process `currentDirectory`
     - the project `directory`
     - the `openProject` action path
     - the "Project" evidence, in both formats
   - **Narrow secret regex:** it only matches `--token`, `--api-key`, `--password` and `--secret` with a literal `--` directly in front. It misses `--auth-token=`, `-p x` and `TOKEN=x`.
     - The argv arrays are collapsed to `<N args redacted>`, so the regex only matters for free text. The fake secrets in my test argv did not leak.
   - **Suggested fix:**
     - Redact path components that look like credentials (`ghp_`, `sk-`, `xox`, long hex or base64).
     - Widen the regex to `-{1,2}[\w-]*(token|key|password|secret)[\w-]*(=|\s+)\S+` and `\b[A-Z_]*(TOKEN|KEY|SECRET|PASSWORD)=\S+`.

3. **low** — `Sources/HeatLensCore/Safety/ProcessTerminator.swift:43`
   - **Problem:** `/bin/` is missing from `appleDirectories`. So `/bin/zsh`, `/bin/bash`, `/bin/sh`, `/bin/launchctl` and other Apple binaries pass eligibility.
   - **Reach today:** none. The test `SafetyEligibilityTests.swift:25` asserts that `/bin/sleep` is eligible.
     - The rules only offer a stop on the root of a dev-server group or a node, bun or python script group.
     - My synthetic scenarios all targeted node, npm or vite, never a shell or the agent: agent → npm → sh → next-server, a terminal running npm run dev, a detached sh with a node child, and npm-installed Claude Code.
   - **Why it matters:** PRD §4.4 says protected Apple services are never offered, and eligibility is the last gate if the rules or grouping change.
   - **Suggested fix:**
     - Add `/bin/` and `/Library/Apple/` to the list.
     - Move the fixture children to a copy of `sleep` and `sh` in a temp directory. The `head` revalidation test keeps covering `/usr/bin`.
   - **Already safe:** case tricks and `..` are normalized by the kernel. `/USR/BIN/tail` and `/System/../usr/bin/tail` both report `/usr/bin/tail` and are denied. Symlinks resolve the same way, because the path comes from the vnode.

4. **low** — `Tests/HeatLensCoreTests/SamplerTests.swift:34,45` and `Sources/heatlens-probe/Fixtures.swift:43`
   - **Problem:** these still call `terminate()` and then `waitUntilExit()`. That's the same lost-wakeup pattern I reproduced here, so they can hang the same way.
   - **Suggested fix:** use the same bounded `waitUntilGone`-style wait. Both files were outside my scope.

5. **low (test tooling)** — the brief's timeout idiom
   - **Problem:** `perl -e 'alarm 120; exec @ARGV' swift test …` kills only `swift-test` on timeout. `swiftpm-testing-helper`, which runs the tests, is orphaned to launchd and keeps running.
   - **What happened:** my pre-fix reproduction left **7** of them. I found them by my scratchpad path and stopped each one by PID. None remain.
   - **Suggested fix:** use a wrapper that runs the command in its own process group and TERMs the group on timeout. Mine is in my session scratchpad (`timeout.pl`); its logic is about 8 lines and could go into the Checks line.

**Plausible (not reproduced):**

6. **low** — `App/ResultsView.swift:199` and `:249-255` (`StopFlowView.requestStop()`)
   - **Problem:** nothing guards against a second dispatch. A fast double-click on **Send SIGTERM** can run the action twice before SwiftUI re-renders the `.stopping` phase, which means two `requestStop` calls and two SIGTERMs.
   - **Impact is bounded:** each call revalidates `(pid, startTime)`, so the second signal can only reach the same validated process. Never SIGKILL.
   - **Suggested fix:** add `guard case .confirmation = phase else { return }` as the first line of `requestStop()`.
   - **Related, also plausible:** a double-click on **Request stop** in a card could land the second click on the sheet as it appears. The sheet has no default-focused destructive button: Cancel holds `.defaultAction`, and Send SIGTERM has no shortcut. So keyboard paths are clean.

7. **low** — `Sources/HeatLensCore/Sampling/ChildProcess.swift:77`
   - **Problem:** a child has no deadline of its own. If `pmset -g therm` hangs, for example because powerd is unresponsive, the scan never finishes until the user presses Cancel. Cancel does SIGTERM that child and reap it.
   - **Impact:** availability only, not safety.
   - **Suggested fix:** a per-child deadline of about 5 s that calls `cancel()`, and treat it as "pmset unavailable".

8. **low (username replacement)** — `Redactor.swift:225-231`
   - **Problem:** this is over-redaction, not a leak. The username is replaced case-insensitively anywhere in the text, so a short username corrupts unrelated words. With the username `al`, `/usr/local` becomes `/usr/loc<user>`.
   - **Suggested fix:** replace the username only as a whole path component, or between word boundaries.

### Checked and clean
- **pid guards:** `requestStop` has a `pid > 1` guard before any lookup.
  - The pid stays `Int32` from sample to `kill`, with no conversion.
  - pid 0, 1 and -1 are refused; the tests cover them.
  - `kill` targets a single process, never a group (`-pid`).
- **Stale identity:** a stale identity from the UI can't misfire. Before signalling, the engine:
  - re-reads the start time twice
  - treats a zombie as exited
  - checks that the live uid is non-zero and equals `getuid()`
  - re-runs eligibility on live kernel data (path from `proc_pidpath`, name, uid, task-info readability)

  The pid-reuse window between the last check and `kill()` is the documented residual race.
- **Eligibility in the UI:** the UI's check on scan data only decides whether a stop is offered. The engine always re-checks live.
- **The fixture stopper:** `FixtureStopService` is wired only into previews. `HeatLensApp` uses `TerminatorStopService`.
- **Child exec:** absolute paths, no shell, no PATH lookup.
  - The pipes don't leak into other children: `lsof` showed only fds 0, 1 and 2 in a sibling child.
  - The inherited environment doesn't matter for platform `ps` and `pmset`.
  - Cancel SIGTERMs the child and waits for it to exit.
- **Exclusions:** they only hide findings and never widen what can be stopped. The detail view still offers a stop for a process whose finding is hidden, because it uses `report.findings`. That's not a widening, but decide whether an exclusion should also suppress the stop.
- **No sandbox:** there is no entitlements file, so `NSHomeDirectory()` is the real home and the home redaction works.

### Suggested commit message
`test(core): bound every wait in the Safety fixture — no waitUntilExit (Phase 2c)`
