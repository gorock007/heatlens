# ADR-0006: Force Quit (SIGKILL) only after a failed stop request, a separate confirmation and a Settings switch

- **Status:** Accepted for Phase 3 (2026-10-28; owner rulings of the same day in
  `handoffs/2026-10-28-1150-v2-3d-safe-actions-design.md`)
- **Context:** PRD-v2 §6 Phase 3 ("graceful termination → optional force quit only after separate
  confirmation"), §8 ("never automatically kill a coding agent or development server; ask and
  explain consequences"); v1 FR-09 (PRD §4.4: explicit consent, PID identity revalidation,
  SIGTERM only, protected-process denylist); the v1 reviews
  `handoffs/merged/2026-10-26-1935-p2c-security-review-safe-stop.md` and
  `…-1944-p2d-security-fixes.md`; the 3a-fixes ruling that Live never stops a process.

v1 shipped `ProcessTerminator` with the invariant "the signal is SIGTERM and nothing stronger,
ever". A process that ignores SIGTERM is reported as `.stillRunning` and the user is sent to
Activity Monitor. This ADR relaxes that invariant in exactly one place, under five conditions
that all have to hold at once. Everything else in the v1 engine stays as it is.

## Decision

1. **Off by default.** Settings gains "Offer Force Quit when a process ignores a stop request"
   (`UserDefaults` key `forceQuitEnabled`, default false), in a new "Actions" group under the
   monitoring sources. While it is off, nothing in HeatLens can send SIGKILL: the UI shows no
   Force Quit control, and the app's stop service refuses a force quit with "Force Quit is off in
   Settings" even if asked. The "still running" result then says: "It didn't exit. HeatLens does
   not force-quit unless you turn that on in Settings; Activity Monitor can also stop it."
2. **Only after a failed stop request, for the same process instance.** A force quit is offered
   only in the result step of a stop flow whose `requestStop` returned `.stillRunning` for that
   exact `ProcessIdentity` (pid + start time). There is no Force Quit button on a card, in process
   detail, in Live, in the CLI or in the MCP server. A new in-memory `StopLedger` (an actor in
   `HeatLensCore/Safety`) records every SIGTERM the app sent, keyed by identity, with the time it
   was sent. `forceQuit` refuses an identity the ledger has no SIGTERM for ("no stop request was
   sent to this process in this session"). The ledger lives for the app session only and is also
   the feed Phase 3e persists as the audit trail (fields in §Audit record).
3. **Timing.** `requestStop` waits 3 s today. A force quit is sent no sooner than **5 s** after
   that SIGTERM: `forceQuit` reads the ledger's `sentAt` and, if less than 5 s have passed, waits
   the remainder before its final checks. The offer **expires 60 s** after the SIGTERM: the
   engine refuses it ("too long since the stop request; request a stop again") and the UI
   disables the button with the same words. A slow but cooperative exit therefore gets at least
   5 s, and a stale sheet left open can't fire a minute later at a process whose state the user
   no longer knows.
4. **A separate confirmation, with the loss warning.** Pressing "Force quit…" opens a second
   confirmation, never the same sheet step that confirmed SIGTERM. It names the process and PID,
   its project and uptime, when the stop request was sent, and says:
   *"Force Quit sends SIGKILL. The process ends at once and cannot save or clean up: unsaved
   edits, open files, database writes and child processes it owns can be lost or left half
   done. This cannot be undone."* Buttons: **Cancel** (default, Return) and **Force Quit**
   (destructive, no keyboard shortcut). The sheet cannot be swipe-dismissed while the signal is
   in flight, and a double-click is guarded like `StopFlowView.requestStop()` (p2d finding 6).
5. **Re-checks right before the signal, the same as SIGTERM.** `ProcessTerminator.forceQuit`
   runs the v1 sequence again against the kernel at that moment: identity (pid + start time),
   a zombie counts as exited, uid equals `getuid()` and is not 0, the full `eligibility(of:)` on
   live data (protected names, Apple directories, readable details), then a last identity read,
   then exactly one `kill(pid, SIGKILL)`. Outcomes are the existing `StopOutcome` cases:
   `.stopped` (gone within 2 s), `.stillRunning` (rare: a process stuck in the kernel), `.alreadyExited`,
   `.identityChanged`, `.denied(reason)`, `.failed(errno)`. The word "stopped" in the UI becomes
   "force quit" through `StopWording` keyed by the signal.
6. **The PID only, never a process group or children.** The signal goes to the one validated
   pid. HeatLens never calls `killpg`, never signals `-pid`, never walks children. Reasons: a
   process group often includes processes that never passed eligibility (a terminal's shell
   runs in the same group as the job it launched; a foreground `npm run dev` shares its group
   with `zsh`); group membership is not identity-validated per member; and children that lose
   their parent are re-parented to launchd and appear in the next scan as detached workers,
   where each gets its own validated stop (the 10b flow). The confirmation says "child
   processes it owns can be left running; scan again to see them".
7. **Batch stop: per process, never "force quit all".** In `BatchStopFlowView`, after the run has
   finished, a row whose outcome is `.stillRunning` shows its own "Force quit…" button. It opens
   the same single-process confirmation (decision 4) for that row only. There is no bulk
   control, the batch never escalates on its own, and `BatchStop` itself does not learn about
   SIGKILL (its `Stopper` closure keeps calling `requestStop`).
8. **Scope outside the scan results: none.** Live keeps its `LiveNoStopService` (eligibility
   denied, nothing sent), and that stub denies force quit too. The CLI and the MCP server stay
   read-only; neither links a stop path. Automatic escalation (SIGTERM then SIGKILL without a
   second decision) does not exist anywhere.

## Options considered

| Option | Against |
|---|---|
| The separate confirmation alone, no Settings switch | The installed default could then send SIGKILL. The owner chose the switch so a default HeatLens stays at v1's "SIGTERM and nothing stronger". |
| Escalate automatically after the 3 s wait (what `docker stop` does) | Breaks PRD-v2 "optional force quit only after separate confirmation" and §8 "ask and explain consequences". |
| `killpg`, or signalling the children too | Group members aren't individually validated; a terminal shell or an editor helper in the same group would die with the job (decision 6). |
| A Force Quit button in process detail, without a prior stop request | Removes the graceful step the PRD requires. The ledger makes "no SIGKILL without a prior SIGTERM" an engine rule, not a UI habit. |
| Running `kill -9` through a shell or `launchctl` | PRD-v2 §8 prefers structured APIs; v1 already uses `kill(2)` directly with no shell. |
| A longer wait before offering (30 s) instead of 5 s minimum plus a 60 s expiry | Most dev servers that ignore SIGTERM never exit; the user would wait for nothing. 5 s is enough for a cooperative exit; the expiry handles stale sheets. |
| Offering force quit from Live | The 3a-fixes ruling: Live rows change under the pointer, and Live has no confirmed-stop step to escalate from. |

## Security review

**Threats and what stops them**

| # | Threat | Mitigation | Proof |
|---|---|---|---|
| 1 | PID reuse: the pid now belongs to another process | Identity (pid + start time) re-read twice before `kill`; impostor → `.identityChanged`, nothing sent | Live test with an impostor identity (start time off by 1 s) |
| 2 | The process exits between the last check and the signal | `kill` returns ESRCH → `.alreadyExited`; the start-time check closes the window to microseconds; SIGKILL to a reused pid in that window is the documented residual, the same as v1's SIGTERM | Test: the fixture child is ended by the test after the ledger entry, before `forceQuit` |
| 3 | A root-owned or another user's process | uid check against `getuid()` and 0 before anything is sent; `kill` would also fail with EPERM | Test: pid 1 and a root pid from the live list are refused without a signal |
| 4 | A denylisted or Apple process | `eligibility(of:)` on live kernel data (names, `/System/`, `/usr/bin/`, `/bin/` …) | Test: a forged ledger entry for the `/usr/bin/head` fixture is refused |
| 5 | SIGKILL without a prior SIGTERM (UI bug, stale state, a second window) | The ledger: no SIGTERM recorded for this identity in the last 60 s → `.denied`; engine-enforced | Tests: no entry, entry too old, entry for a different start time |
| 6 | SIGKILL too soon after SIGTERM | 5 s minimum enforced by the engine, not the UI | Test: a ledger entry 1 s old makes `forceQuit` wait ≥ 4 s before signalling |
| 7 | Double dispatch (two SIGKILLs, or SIGKILL while SIGTERM is waiting) | Phase guard in the flow; the engine's second signal would hit the same validated process or nothing | Code review; the existing p2d guard pattern |
| 8 | The switch is flipped by another local process in `UserDefaults` | Not a new boundary: a process with the user's rights can `kill -9` directly. The switch protects against HeatLens's own UI, not against the user's other software | — |
| 9 | Children or a group killed by accident | PID only; no `killpg` anywhere | Test: `grep -n "killpg\|SIGKILL" Sources/` shows one SIGKILL site in `ProcessTerminator.swift` and no `killpg` |
| 10 | Force quit reachable from Live, CLI or MCP | Live stub denies; CLI/MCP targets don't link a stop path | Test: `grep -rn "forceQuit\|requestStop" Sources/HeatLensCLI Sources/heatlens` is empty |

**Data loss is the point, so the words carry it.** The confirmation says what SIGKILL does
to unsaved work and open writes, names the process and project, and makes Cancel the default.
Nothing about the process's argv or paths is added to any export or record by this feature.

**Residual risk.** The microsecond window between the final start-time read and `kill()` is the
same one v1 documented. SIGKILL cannot be caught, so a process in the middle of a write loses
it; that is what the user is told and confirms.

## Audit record (defined here, stored by Phase 3e)

The ledger holds one `ActionRecord` per attempt. No argv, no environment, no paths beyond the
project name. 3e persists it.

| Field | Content |
|---|---|
| `id` | UUID |
| `at` | Date the action was decided (signal sent, or refused) |
| `action` | `stopRequested` (SIGTERM), `forceQuit` (SIGKILL), `containerStop` (ADR-0007) |
| `target` | `.process(pid, startTimeMicros, name ≤ 80 chars)` or `.container(shortID 12 hex, name ≤ 80, image ≤ 80, composeProject?)` |
| `projectName` | The attributed project's name, or nil; never its directory |
| `origin` | `processDetail`, `leftoverCard`, `batchStop`, `containerDetail` |
| `confirmedAt` | When the user pressed the destructive button |
| `signalSentAt` | When the signal or request left HeatLens, or nil when refused |
| `outcome` | The `StopOutcome` (or `ContainerStopOutcome`) case name |
| `detail` | The reason text for `denied`/`failed`, ≤ 200 chars, passed through `Redactor.text` |

## Tests (what proves it is safe)

All live tests use `FixtureChild` from `SafetyTerminatorTests.swift` (ad-hoc-signed copies of
`/bin/sleep` and `/bin/bash` in a temp directory, stopped in a `defer`), and only ever signal
those children.

1. **Happy path.** `bash -c 'trap "" TERM; exec sleep 300'` (the copy) → `requestStop` →
   `.stillRunning`; ledger has the entry; `forceQuit` → `.stopped`; the identity is gone.
2. **PID reuse.** An identity with the child's pid and start time + 1 s → `.identityChanged`;
   the child is alive 200 ms later.
3. **Exited between check and signal.** The test ends its own child after the ledger entry and
   before `forceQuit` → `.alreadyExited`, no error.
4. **Root-owned.** pid 1 → `.denied`; the first uid-0 pid from the live process list → `.denied`
   before any signal (nothing is ever sent to it).
5. **Denylisted / Apple.** A `/usr/bin/head` child with a forged ledger entry → `.denied` by
   eligibility; the child is alive and is stopped by the test's own `defer`.
6. **No prior SIGTERM.** No ledger entry → `.denied`; entry older than 60 s → `.denied`.
7. **Grace.** Entry 1 s old → `forceQuit` returns no earlier than 4 s later (measured), then
   signals.
8. **One SIGKILL site.** A test reads `Sources/HeatLensCore/Safety/ProcessTerminator.swift` and
   asserts exactly one occurrence of `SIGKILL` and none of `killpg` in `Sources/`.
9. **Batch never escalates.** `BatchStopTests`: a stopper that always returns `.stillRunning`
   yields `.finished(.stillRunning)` for every item and no other call.
10. **Switch off.** `TerminatorStopService(forceQuitAllowed: { false })` returns
    `.denied("Force Quit is off in Settings")` without touching the engine (app-level; a
    preview/fixture test or a code read, since `App/` has no test target).

## Revisit when

- Phase 3e stores the ledger: keep the record shape above; if a field is added, add it here.
- A LaunchAgent helper (Phase 4) would move signalling out of the app; the ledger and the
  5 s / 60 s rules must move with it, and the helper must not accept a force quit without a
  ledger entry of its own.
- Users report processes that need more than 5 s to exit cleanly: raise the minimum, never
  lower it.

## Build briefs

Two briefs, in order. Each ends green on
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build && swift test`
and `scripts/run-app.sh --build-only`.

### 3d-1 · Core: `StopLedger` and `ProcessTerminator.forceQuit` (claude, opus, high)

- **Do:**
  - `Sources/HeatLensCore/Safety/StopLedger.swift` (new): `public actor StopLedger` with
    `record(_ record: ActionRecord)`, `stopRequestedAt(_ identity: ProcessIdentity) -> Date?`
    (the newest `stopRequested` entry whose `signalSentAt` is set), `records(since:)`, entries
    pruned after 10 minutes. `public struct ActionRecord` with the fields in §Audit record
    (put `ActionRecord` in this file, not in `Model/`, so no shared file changes; 3e may move it).
  - `ProcessTerminator.swift`: `requestStop(_:wait:ledger:)` gains `ledger: StopLedger? = nil`
    and records the SIGTERM (`signalSentAt` right after `kill` returns 0). New
    `forceQuit(_ identity:, ledger: StopLedger, wait: TimeInterval = 2) async -> StopOutcome`:
    ledger lookup (decision 2), grace and expiry (decision 3, constants
    `minimumGraceAfterStop = 5`, `offerLifetime = 60`), then the exact `requestStop` sequence
    with `SIGKILL` in step 4 and a 2 s poll. Factor the shared revalidation into a private
    helper so both paths run the same checks. Update the type's doc comment: the SIGTERM-only
    invariant now reads "SIGTERM from `requestStop`; SIGKILL only from `forceQuit`, which needs a
    recorded SIGTERM for the same identity".
  - Tests in a new `Tests/HeatLensCoreTests/ForceQuitTests.swift`, reusing `FixtureChild`
    (make it `internal` if it is `private`): tests 1–8 of §Tests. Add test 9 to
    `BatchStopTests.swift`.
- **Pattern to copy:** `requestStop` itself (the three-step revalidation and the poll loop);
  `SafetyTerminatorTests.swift` for fixtures and the impostor-identity test; `BatchStopTests`
  for a stopper closure.
- **Done when:** all §Tests 1–9 pass three runs in a row under `scripts/with-timeout.sh 600`;
  `grep -n "SIGKILL" Sources/ -r` prints exactly one line, in `ProcessTerminator.swift`;
  `grep -rn "killpg" Sources/` prints nothing; every existing `Safety*` test passes unchanged.
- **May touch:** `Sources/HeatLensCore/Safety/ProcessTerminator.swift`,
  `Sources/HeatLensCore/Safety/StopLedger.swift` (new), `Tests/HeatLensCoreTests/ForceQuitTests.swift`
  (new), `Tests/HeatLensCoreTests/SafetyTerminatorTests.swift` (fixture visibility only),
  `Tests/HeatLensCoreTests/BatchStopTests.swift`.
- **Must not touch:** `BatchStop.swift` (it must not learn about SIGKILL), `App/`, `Model/`,
  `Package.swift`, the CLI targets, every doc.

### 3d-2 · App: the switch, the second confirmation, per-row force quit in the batch sheet (claude, opus, medium)

- **Do:**
  - `App/SettingsModel.swift`: `forceQuitEnabled` (key `forceQuitEnabled`, default false), the
    same `didSet` pattern as `dockerEnabled`. `App/SettingsView.swift`: an "Actions" group after
    `MonitoringSourcesSection` with the toggle and caption: "After a stop request that a process
    ignores, offers Force Quit (SIGKILL) behind a second confirmation. Off: HeatLens never sends
    anything stronger than SIGTERM."
  - `App/StopService.swift`: `ProcessStopping` gains
    `forceQuit(_ identity: ProcessIdentity) async -> StopOutcome`. `TerminatorStopService` owns
    one `StopLedger`, passes it to `requestStop`, and takes `forceQuitAllowed: @Sendable () -> Bool`
    (reads `settings.forceQuitEnabled` on the main actor); when false it returns
    `.denied("Force Quit is off in Settings")` without calling the engine. `FixtureStopService`
    returns `.stillRunning` for one fixture PID (so previews show the offer) and `.stopped` on
    force quit. `StopWording.message(for:pid:signal:)` adds the SIGKILL sentences; the
    "HeatLens does not force-quit" strings become the decision-1 wording when the switch is off,
    and "You can force quit it below." when on.
  - `App/ResultsView.swift` (`StopFlowView`): the `.outcome` phase for `.stillRunning` shows
    "Force quit…" when the switch is on and the offer is under 60 s old; new phases
    `.forceQuitConfirmation`, `.forceQuitting`, `.forceQuitOutcome` with the decision-4 text and
    the `guard case` double-dispatch guard. Show the seconds since the stop request, updating
    once a second, and disable the button at 60 s with "request a stop again".
  - `App/BatchStopFlowView.swift`: after `run.isFinished`, rows with `.finished(.stillRunning)`
    get a small "Force quit…" button that sets `@State forceQuitTarget: StopTarget?` and presents
    the single confirmation (`.sheet(item:)`, the same view `StopFlowView` uses, factored into a
    `ForceQuitFlowView` so both call sites share it). No bulk control.
  - `App/LiveView.swift`: `LiveNoStopService.forceQuit` returns `.denied` (nothing sent).
  - `App/HeatLensApp.swift`: pass the settings closure into `TerminatorStopService`.
  - `App/FixtureScanService.swift`: nothing unless a preview needs a stubborn process.
- **Pattern to copy:** `StopFlowView` phases and its `requestStop()` guard; `BatchStopFlowView`'s
  `.sheet(item:)` and row status labels; the `dockerEnabled` toggle and caption in
  `MonitoringSourcesSection`.
- **Done when:** `scripts/run-app.sh --build-only` builds with no new warnings; `swift build`
  unchanged (no `Sources/` edits). Verification steps for the handoff: `scripts/run-app.sh`,
  then in Terminal run `bash -c 'trap "" TERM; exec sleep 600'` from a project folder, Scan now,
  open that process → Request stop → Send SIGTERM → "still running" with no Force quit button
  and the Settings hint; Settings → turn the switch on; Request stop again → still running →
  **Force quit…** → the second sheet names the process, Cancel is default → Force Quit → the row
  reads "force quit", and the shell is gone in Activity Monitor. Then check the batch sheet with
  two such processes in one project: each still-running row has its own button; there is no
  "force quit all".
- **May touch:** `App/SettingsModel.swift`, `App/SettingsView.swift`, `App/StopService.swift`,
  `App/ResultsView.swift`, `App/BatchStopFlowView.swift`, `App/LiveView.swift`,
  `App/HeatLensApp.swift`, `App/FixtureScanService.swift`, `App/ProcessDetailView.swift` (only
  if the "Stop unavailable" wording needs the switch).
- **Must not touch:** `Sources/`, `Tests/`, `Package.swift`, `project.yml`, docs (Jarvis updates
  README/LIMITATIONS/site lines that say HeatLens never force-quits; the list is in the 3d
  handoff).
