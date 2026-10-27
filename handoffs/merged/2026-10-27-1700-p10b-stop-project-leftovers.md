# Phase 10b: stop a project's leftovers together (one listed confirmation, each PID revalidated)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1641-p10b-stop-project-leftovers.md

## What the user asked
When one project has several leftovers, show one confirmation that lists each process with a checkbox. Then stop the selected ones one at a time, revalidating each PID right before its SIGTERM. Only processes the rules already offer to stop can be included.

## What changed
- **Core candidates:** `LeftoverCandidates.byProject(findings:groups:processes:hiddenFindingIDs:)` is pure. It collects `.requestStop` actions from `staleDevServer`/`detachedWorker` findings only and groups them by the project of the group that contains each identity. Findings the user hid are skipped, so exclusion also suppresses stop. Stops with no project or no process sample are dropped, and identities are de-duplicated (first finding wins). `batches(..., isEligible:)` also drops ineligible candidates and keeps only projects with at least `minimumBatchSize` (2) left. HeatLens adds no candidates of its own.
- **Core runner:** `BatchStop(stop:)` calls the injected `(ProcessIdentity) async -> StopOutcome` closure once per identity, in order, never in parallel. It reports `.stopping` and then `.finished(outcome)` for each item through `onUpdate`.
  - Cancelling the calling task stops the run before the next item.
  - The item in progress runs in an unstructured task, so a cancel can't cut its exit wait short and misreport it as "still running".
  - Items not reached come back `.notAttempted`.
  - `ProcessTerminator.swift` is unchanged.
- **Entry point:** I chose a small row above the project's first leftover card: "portfolio-demo has 2 leftovers [Stop leftovers (2)…]". It's in `ResultsView` as `BatchStopRow`, and `FindingCard` is untouched.
  - The row appears only when 2 or more candidates pass `stopService.eligibility`.
  - A project with one candidate keeps today's `StopFlowView` unchanged.
  - Each card's own "Request stop" stays as before.
- **Batch sheet (`App/BatchStopFlowView.swift`):** It's presented from `ResultsView` with `.sheet(item:)`, like `StopFlowView`.
  - Title: "Stop N leftovers in <project>?", with the project path under it.
  - One checkbox row per process (default on): name · PID, "up 1d 14h · 0% CPU (of one core) in this scan", and the finding title.
  - A SIGTERM explanation line, plus `StopFlowView`'s interruption warning.
  - "Stop selected (k)" is destructive and disabled at k = 0.
  - While it runs, each row shows stopping… / stopped / already gone / skipped: it changed / still running / skipped: not allowed (with the reason under the row). There is a Cancel button, and swipe-dismiss is disabled.
  - Afterwards it shows a summary ("2 stopped · 1 skipped: it changed"), Done, and Scan again (`onScanAgain`).
- **Shared wording:** `StopFlowView`'s outcome sentences moved into `StopWording.message(for:pid:)` in `App/StopService.swift`, unchanged. `StopWording.status(for:)` holds the short row labels. `StopFlowView` now calls the helper. `ProcessDetailView` didn't need changes.
- **Fixture:** `portfolio-demo` gains a second leftover: a detached `node …/scripts/watch-images.js`, PID 23140, PPID 1, with its own group and a `detachedWorker` finding that offers `.requestStop`. The preview now shows the batch button for portfolio-demo (npm + the watcher). `FixtureStopService` needed no change: everything is eligible and every stop returns `.stopped` after 0.5 s.
- **README:** one feature line under Status.

## Files
- Sources/HeatLensCore/Rules/LeftoverCandidates.swift — created
- Sources/HeatLensCore/Safety/BatchStop.swift — created
- Tests/HeatLensCoreTests/LeftoverCandidatesTests.swift — created
- Tests/HeatLensCoreTests/BatchStopTests.swift — created
- App/BatchStopFlowView.swift — created
- App/ResultsView.swift — modified
- App/StopService.swift — modified
- App/FixtureScanService.swift — modified
- handoffs/2026-10-27-1700-p10b-stop-project-leftovers.md — created

## Checks run
- `swift build`: complete.
- `swift test`: 171 tests in 33 suites passed. The new tests:
  - **Candidates (8 tests):** only the leftover kinds count (a `.highCPU` finding carrying `.requestStop` is ignored); a finding without a stop offer adds nothing; grouping per project in first-finding order; no-project stops excluded; hidden findings excluded; de-duplication; a missing sample is skipped; the ≥2 rule, including dropping below 2 when one candidate is ineligible.
  - **BatchStop (5 tests):** order and per-item updates and outcomes; strictly sequential calls; a cancel during item 2 lets it finish and leaves items 3–4 `.notAttempted`; a run cancelled up front sends nothing; and the live test.
  - **Live test:** 4 ad-hoc-signed copies of `/bin/sleep 300` (the existing `FixtureChild`, since `/bin/` itself is on the Apple denylist) go through the real `ProcessTerminator().requestStop`. The order is child 1, child 2, an impostor with child 4's PID and a start time 1 s off, then child 3. Result: stopped, stopped, identityChanged, stopped. Children 1–3 are gone, and child 4 is still alive 200 ms later. Every child is stopped in a `defer`.
- `scripts/run-app.sh --build-only`: built. A full non-quiet xcodebuild showed no Swift warnings.
- **Screenshot:** a scratch-only `ImageRenderer` driver compiles `App/*.swift` (minus `HeatLensApp.swift`) with fixtures.
  - The sheet: `/private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/3c675932-dbb8-4f3f-bd5d-631527d254ce/scratchpad/render/batch-stop-sheet.png`
  - The leftovers section with the batch row: `/private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/3c675932-dbb8-4f3f-bd5d-631527d254ce/scratchpad/render/leftovers-section.png`. `BatchStopRow` is private, so this render re-creates that row inline. Its old one-line label is the one I changed to wrap.
  - The script that makes them: `/private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/3c675932-dbb8-4f3f-bd5d-631527d254ce/scratchpad/render/render.sh`
- `handoffs/bin/jarvis leftovers --mine`: nothing running.
- **Not checked:**
  - No click-through in the running app (deferred by the brief).
  - The running and finished states of the sheet weren't rendered, only the confirmation.
  - Two `.sheet` modifiers on the same `Group` weren't exercised live.

## Verify
`scripts/run-app.sh`, then Scan now. On a Mac with two stale dev servers or detached workers in one project, a "Stop leftovers (N)…" row appears above that project's first leftover card. Open it and check the listed PIDs against Activity Monitor. Untick one, stop the rest, and confirm only the ticked processes are gone. In Xcode, the `ResultsView` "Results" preview shows the row for portfolio-demo, and the "Batch stop" preview shows the sheet.

## Processes left running
none

## Questions for the user
none

## Notes for Jarvis
- No shared files were touched (`Sources/HeatLensCore/Model/` is unchanged).
- I didn't touch 10a's files. They are in my render compile, but I didn't edit them.
- Possible overlap with 10a: their new `Sources/HeatLensCore/Rules/ExclusionFilter.swift` may replace `ResultsView.matchesExclusion`. My code only reads `context.hiddenFindingIDs`, so a later swap there shouldn't conflict, but both phases edit `App/ResultsView.swift`. Check the merge.
- The batch row is keyed to the first candidate's finding. Both leftover kinds are `.review`, so that card is always in the "Potential leftovers" list. If a rule ever ships either kind at another severity, the row would silently not show.
- Suggested commit: `feat(core,app): stop a project's leftovers together: one listed confirmation, each PID revalidated before its SIGTERM (Phase 10b)`
- Jarvis: README.md (one Status line) left out of this commit because 10a edited the same file; it is committed with 10a.
