# v2 Phase 3b: concurrency explanations ("2 test runs began within 10 s across 2 agent trees")
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-28-0940-v2-3b-concurrency-explanations.md

## What the user asked
In Live mode, explain bursts of concurrent expensive work in plain words, with the evidence
behind each explanation. Each one needs a confidence level, what HeatLens can't know, and a
non-destructive recommendation. Done means the FDA multi-agent Docker test scenario gets one
useful explanation.

## What changed
- **`ConcurrencyRules`** (pure, fed one `LiveTick` at a time like `TimelineDetector`; the first tick is the baseline):
  - **Commands:** reuses `ExpensiveCommand.outermost`/`classify` (cached per process identity). A command's start is its fork time, not the tick time.
  - **Agent tree:** walks the parent chain to the nearest coding agent using `RulesEngine.agentNames`. It checks the process name, the executable and argv[0], because the native Claude Code binary is named after its version (e.g. `2.1.4`). A command with no agent ancestor goes in the "no agent" tree.
  - **Burst:** ≥ 2 commands started within `burstWindow = 10 s` across ≥ 2 agent trees or ≥ 2 projects.
  - **Containers:** a container that starts in one of the burst's projects is added to the burst. That holds from 10 s before the first command to 10 s plus one refresh after the last; a container's time is the first tick that saw it running. The title names the containers when ≥ 2 started.
  - **Container-only burst:** with fewer than 2 commands, ≥ 2 containers starting across ≥ 2 projects are a burst on their own, at low confidence. I read "low when it rests on containers alone" that way.
  - **Confidence:** high when every command has a project, medium when some don't, low for container-only.
  - **No spam:** the newest burst stays open for its 10 s window. Later starts inside that window (a container seen a tick late, a third command) update its explanation in place, under the same id and with no second timeline event. A new burst needs a new command.
  - **Lifetime:** `endedAt` is set when nothing in the burst is still running. The explanation is dropped 10 minutes later. At most 5 are kept, newest first.
- **`Explanation`** (new shared model type) holds:
  - title, built only from labels, container names, project names and agent names
  - observations: timestamp + `Evidence`
  - `confidence`
  - 1–2 lines of `uncertainty`; the first is always "…not how much heat or power each one causes."
  - `recommendation`: text only
  - `startedAt`/`endedAt`, `projects`, `agentTrees` (name + root `ProcessIdentity`, nil root for "no agent"), `affected`, `containerIDs`
- **Wiring:**
  - `LiveTick.explanations` is set in `LiveMonitor` right after `detector.events(for:)`.
  - Each new explanation adds one `TimelineEvent` of the new kind `.concurrencyExplained` (`isInference: true`). It shows on the timeline (dashed orange marker, "inference" tag) and goes to history.
- **History compatibility:** the events table stores `kind.rawValue` as TEXT, and the schema is unchanged.
  - An old database reads as before: it just has no rows of the new kind.
  - An older app build reading a newer database skips unknown kinds, because `HistoryStore.window` already does `guard let kind = Kind(rawValue:) else { return }`.
  - `HistoryStore.swift` is untouched. A round-trip test is in `ConcurrencyRulesTests`.
- **UI:** a "What's going on" card at the top of Live mode, shown only when there are explanations (`App/ExplanationsCard.swift`). Each row shows:
  - the title, a confidence chip, the recommendation, and when the burst started (and ended, if it has)
  - expanded: each observation (time, fact; the source in a tooltip) and the uncertainty lines

  There are no buttons. `TimelineView.swift` didn't need changes, because it doesn't switch on kind.
- **Example, the FDA test:** "2 test runs began within 10 s across 2 agent trees (claude, codex) in FDA, plus 3 containers".
  - High confidence, 5 observations.
  - Recommendation: "These test runs compete for the same CPU cores and the Docker VM. Run them one at a time, or have the agents take turns."
  - `npm run test:integration` isn't an `ExpensiveCommand` match (only `run build`/`run test` are). The outermost match is the `sh -c vitest …` under it, so it counts as 2 runs, not 3.

## Files
- Sources/HeatLensCore/Live/ConcurrencyRules.swift — created
- Sources/HeatLensCore/Model/Explanation.swift — created (shared type)
- Sources/HeatLensCore/Live/LiveMonitor.swift — modified
- Sources/HeatLensCore/History/HistoryModel.swift — modified (new `TimelineEvent.Kind.concurrencyExplained` only)
- Sources/HeatLensCore/Rules/RulesEngine.swift — modified (outside the brief's list; see Notes)
- App/ExplanationsCard.swift — created
- App/LiveView.swift — modified (inserts the card)
- Tests/HeatLensCoreTests/ConcurrencyRulesTests.swift — created
- docs/v2/PLAN.md — modified (concurrency line marked ✅ with a short Did)
- handoffs/2026-10-28-1128-v2-3b-concurrency-explanations.md — created

## Checks run
- `swift build`: Build complete.
- `scripts/with-timeout.sh 600 swift test --filter "ConcurrencyRules|Timeline|LiveMonitor|HistoryStore"`: 45 tests in 7 suites passed.
- `scripts/with-timeout.sh 600 swift test`: **305 tests in 52 suites passed**. Note: `jarvis lock test` has no lock class in `handoffs/jarvis.conf`, so I ran the brief's wrapped command directly.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- New tests (12):
  - FDA scenario
  - reported once over 5 more ticks
  - containers seen a tick later join the burst
  - single agent, one test → nothing
  - 30 s apart → nothing
  - two projects, no agents → "across 2 projects"
  - unplaced command → medium
  - containers only → low
  - first tick → nothing
  - ended + dropped after 10 min
  - history round trip of the new kind
  - cost
- **Cost:** 1,000 processes take **3.1 ms per tick (debug build)** after the first. That is about 0.06% of one core at 5 s, under the 0.1-point budget. I didn't measure the release build or the live session.
- **Not checked:**
  - I didn't launch the app or look at the card, because another worker is driving it.
  - The Terminal verification below and the real FDA scenario haven't been run.

## Verification for the user
1. Build and launch: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh`. Open the panel, go to Live and press Start live.
2. In Terminal, run the first command from one project's folder and the second from another project's folder, within a few seconds of each other:
   - `cd ~/Developer/FDA && (exec -a "npm ci" sleep 40) &`
   - `cd ~/Developer/<other repo> && (exec -a vitest sleep 40) &`
3. Within one refresh, a **"What's going on"** card should appear at the top showing:
   - the title "2 expensive commands began within 10 s across 2 projects (FDA, <other>)"
   - a "High confidence" chip
   - "…If the Mac runs hot, let one finish before starting the next."
   - "Started HH:MM · still running"
4. Expand the card. It should show two timestamped observations: "npm ci started · PID …, in FDA, no agent above it" and "vitest started · …". Below them are two uncertainty lines.
5. The Timeline card should list the same title with an "inference" tag. After ~40 s the card should read "ended HH:MM", and it should disappear about 10 minutes later.
6. If a folder isn't recognised as a project, the title loses "across 2 projects" and no card appears. In that case, check the Projects card.

## Processes left running
none

## Questions for the user
none

## Notes for Jarvis
- **Edit outside the brief's list:** `Sources/HeatLensCore/Rules/RulesEngine.swift`. The brief asked me to reuse `RulesEngine.agentNames` (or `ProvenanceResolver.agentKinds`), but both were declared in `private extension`s and couldn't be reached from `Live/`. I moved the `agentNames` declaration unchanged out of `private extension RulesEngine` into a 3-line internal `extension RulesEngine` with a doc comment. No behaviour changed.
- **Shared file:** `Sources/HeatLensCore/Model/Explanation.swift` (new shared type, Codable).
- **Phase numbering:** PLAN.md's Phase 3 list calls this item "3a" (alert policies are "3b" there), while the brief calls it 3b. I marked the concurrency line done and left the numbering alone.
- Suggested commit: `feat(v2): Phase 3b — concurrency explanations ("What's going on" card)`
