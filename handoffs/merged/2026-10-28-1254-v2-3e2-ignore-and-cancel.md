# v2 3e-2: "Ignore this process / project" buttons, and log ignores and cancelled confirmations
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-1630-v2-3e2-ignore-and-cancel.md
## What the user asked
Finish PRD-v2 Phase 3e:
- "Ignore this process" and "Ignore this project" buttons that add a line to Settings' exclusions,
  with no confirmation, each one logged as `ignored`;
- log every cancelled stop, force quit, container stop and batch stop confirmation as `cancelled`.

No questions were needed.
## What changed
- **Settings helpers** (`SettingsModel`):
  - `isProcessExcluded(_:)` and `isProjectExcluded(_:)` both go through `ExclusionFilter.excludes`.
    So a process name matches case-insensitively, and a project counts as excluded when it or a
    parent prefix is.
  - `ignoreProcess(_:)` appends the name to `excludedProcesses` unless it's already excluded.
  - `ignoreProject(_:)` appends the directory to `excludedProjects` in its `~/…` form
    (`ProjectFormat.path`), unless it's already excluded.
  - Each adds a newline only when the text doesn't already end in one. Neither adds a duplicate.
- **One recording helper** (`ActionRecording`, in `App/ResultsView.swift`). It writes straight
  into `ActionLog.shared.ledger`, with `signalSentAt: nil` and `detail: nil`:
  - `ignoreProcess`: `action .ignored`, `outcome "ignored"`, target
    `.process(pid:startTimeMicros:name:)`. `projectName` is the folder name only, as `StopTarget`
    already does.
  - `ignoreProject`: target `.project(name:)`, with name only, never the directory.
  - Both set `at` and `confirmedAt` to the click time.
  - `cancelled(offered:…)`: `action .cancelled`, `outcome "cancelled"`, `offered` set,
    `confirmedAt: nil`.
- **Ignore this process:**
  - **Process detail:** in Actions, next to Activity Monitor. Once clicked, the button is replaced
    by the note "Ignored. Remove it in Settings → Exclusions to undo." The existing "Excluded in
    Settings" line then shows, as before.
  - **Finding cards:** shown when every process the card names has the same name, so that one
    excluded name hides the card. Origin `.findingCard`.
    - The card disappears at once: `ResultsView` already recomputes visible findings from the
      observed settings.
    - So the same note shows above the findings, next to "N findings hidden by your exclusions".
    - A card naming several differently-named processes has no button. Use Inspect details →
      Ignore this process for those.
- **Ignore this project:**
  - **Projects card:** at the bottom of an expanded project row, with origin `.projectRow`. It
    excludes the project's root, and the note replaces the button.
  - **Process detail:** in the "Project attribution" section, with origin `.processDetail`. It
    excludes the same directory the Projects card shows: the repository root when there is one,
    otherwise the attributed directory.
  - Not on the Unattributed or Docker VM rows.
  - Hidden when the project, or a parent of it, is already excluded.
- **Live stays read-only.** `ProcessDetailView.settings` and `ProjectsCard.settings` are optional
  and default to nil. `LiveView` passes neither, so Live shows no ignore buttons. `LiveView.swift`
  is untouched.
- **Cancelled confirmations** are recorded in `.onDisappear` while the flow is still at its
  confirmation step. That covers Cancel, Escape and the sheet closing, and logs once per flow:
  - **`StopFlowView`:** phase `.confirmation` → `offered: .stopRequested`, origin `target.origin`.
  - **`ForceQuitFlowView`:** phase `.forceQuitConfirmation` → `offered: .forceQuit`.
    - In the single-stop sheet, Cancel swaps this view back to the outcome, so `onDisappear` fires
      once.
    - In the batch sheet, Cancel closes the inner sheet.
    - When the whole stop sheet closes during the force-quit step, only the force-quit cancel is
      logged, because `StopFlowView` is in `.forceQuit` by then.
  - **`ContainerStopFlowView`:** phase `.checking` or `.confirmation` → `offered: .containerStop`.
    The target is `.container(shortID:name:image:composeProject:)`, with origin `.containerDetail`.
    A preview that ends in "Can't stop this container" isn't a cancel.
  - **`BatchStopFlowView`:** before anything was sent (`sent.isEmpty`), one record per still-checked
    row, origin `.batchStop`. The in-progress "Cancel" (`run.cancel()`) is after sending, so it
    isn't logged.
  - A Done or Scan again after an outcome logs nothing.
- `ActionLogLine` (untouched) formats these lines, which I checked by reading the code:
  - `Ignored · node (my-app)`
  - `Ignored · project my-app`
  - `Cancelled stop request · node (my-app) · nothing sent`
  - `Cancelled force quit · … · nothing sent`
  - `Cancelled container stop · demo-db-1 (demo) · nothing sent`
- `docs/v2/PLAN.md`: 3e is marked **Done** (briefs 3e-1, 3e-2), with a summary of what 3e-2 adds.
## Files
- App/SettingsModel.swift — modified
- App/ResultsView.swift — modified
- App/ProcessDetailView.swift — modified
- App/FindingCard.swift — modified
- App/ProjectViews.swift — modified
- App/BatchStopFlowView.swift — modified
- App/ContainerStopFlowView.swift — modified
- docs/v2/PLAN.md — modified
- handoffs/2026-10-28-1254-v2-3e2-ignore-and-cancel.md — created
## Checks run
- `swift build`: Build complete.
- `scripts/run-app.sh --build-only`: built `HeatLens.app`.
- I touched the seven App files and ran a non-quiet `xcodebuild`. There were no Swift warnings or
  errors; the only line was the usual `appintentsmetadataprocessor` "Metadata extraction skipped"
  note.
- **Not run:** `swift test`. No `Sources/` or `Tests/` file changed, so the engine suite is
  unaffected. Jarvis runs the full suite before merging.
- **Not checked by me:** I didn't launch the app or click through. The behaviour above comes from
  reading the code and the build.
## Verification (the user's click-through)
1. Run `scripts/run-app.sh`, then **Scan now**.
2. **Ignore a process:** open any process (for example from "What's using resources") and press
   **Ignore this process**.
   - The button is replaced by "Ignored. Remove it in Settings → Exclusions to undo."
   - Settings → excluded processes has the name on its own line.
   - Settings → **Recent actions** shows `HH:MM · Ignored · <name> (<project>)`.
   - Open the same process again: no Ignore button.
   - Remove the line in Settings to undo.
3. **Ignore a process from a finding card:** press Ignore this process on a card.
   - The card goes away.
   - Above Findings: the "Ignored…" note and "1 finding hidden by your exclusions".
4. **Ignore a project:** in the Projects card, expand a project and press **Ignore this project**.
   - Settings → excluded projects gains `~/…/<project>`.
   - Recent actions shows `Ignored · project <name>`, with no path.
   - Unattributed and the Docker VM row have no such button.
   - Open a process in that project: its Project attribution section has no Ignore button now.
5. **Cancel a stop:** start `bash -c 'trap "" TERM; exec sleep 600'` in Terminal, then Scan now.
   Open that process, press Request stop, then **Cancel**.
   - Recent actions: `Cancelled stop request · bash (<project>) · nothing sent`.
   - Pressing Escape instead of Cancel gives the same line.
   - End the `sleep` with Ctrl-C afterwards. Signal only the process you started.
6. Optional:
   - With Force Quit on, send SIGTERM to that trap-ignoring `bash`. Then press Force quit… →
     Cancel. Recent actions: `Cancelled force quit · … · nothing sent`.
   - A batch "Stop leftovers (N)…" → Cancel logs one line per checked row.
   - In fixture mode (`-HeatLensFixtures`), container Stop container… → Cancel logs a cancelled
     container stop. The fixture stop services still don't record the stops themselves, but
     ignores and cancels do go into the ledger there.
7. Live: no Ignore buttons in Live's process detail or its Projects card.
## Processes left running
none (`handoffs/bin/jarvis leftovers --mine`: nothing this session started is still running)
## Notes for Jarvis
- **The brief and ADR-0006 disagree on `confirmedAt` for `ignored`.** The brief says "the click
  time"; ADR-0006 §Audit record (line 126) says "nil for `cancelled` and `ignored`". I followed
  the brief for `ignored` (click time) and the ADR for `cancelled` (nil). The ADR row needs a
  one-word fix ("nil for `cancelled`"), or a ruling the other way. `docs/v2/ADR-0006` was outside
  my scope.
- **Ignoring is immediate, not on the next scan.** `ResultsView` reads the observed `settings`, so
  the hidden-by-exclusions count and the finding list update at once, as they already did when
  Settings was edited with results open. That's why the finding-card note sits at the results
  level.
- **The process detail project button uses the repository root** (as in the Projects card) when
  there is one. That can hide more than the attributed cwd would, for example a whole repository
  rather than one subfolder. The tooltip names the exact directory.
- **The popover closing while a confirmation sheet is open counts as a cancel**: it's the sheet
  being dismissed.
- Shared files: none.
- `handoffs/OPEN.md` and the brief file were already modified or untracked before I started; I
  didn't touch them.
- Suggested commit message:
  `feat(v2): Phase 3e-2 — "Ignore this process/project" (process detail, finding cards, Projects rows; no confirmation, logged by name), cancelled stop/force-quit/container/batch confirmations logged as cancelled; 3e done`
