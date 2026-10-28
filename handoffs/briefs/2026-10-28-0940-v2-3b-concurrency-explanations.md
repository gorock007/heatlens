# v2 Phase 3b: concurrency explanations ("three Docker integration tests began within 10 s across two agent trees")
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 11:20 · terminal: 0dea1179-8a3f-4c3c-b1aa-f12e5af4ffe2

## Goal
Live mode explains bursts of concurrent expensive work in plain words, with the evidence behind them. This is the first part of PRD-v2 Phase 3 (`docs/PRD-v2.md` §Phase 3, lines ~98–107), and it is what the Phase 3 exit (the FDA multi-worker Docker test scenario) is judged on. Done means:

1. **Core (pure, tested).** A new `Sources/HeatLensCore/Live/ConcurrencyRules.swift` with a struct that, like `TimelineDetector`, is fed one `LiveTick` at a time and keeps a short memory. It returns zero or more `Explanation`s. A new shared type `Sources/HeatLensCore/Model/Explanation.swift` holds:
   - `title`, e.g. "3 integration test runs began within 10 s across 2 agent trees", built only from command labels, container names, project names and agent names (the same rule as `TimelineEvent.title`: no paths, no argv).
   - `observations`: each one a timestamped fact (what started, when, in which project, under which agent tree). Reuse `Evidence` for the fact text and source where it fits.
   - `confidence` (the existing `Confidence`) and `uncertainty`: one or two lines naming what HeatLens can't know. It must never claim how much heat or power any one process caused.
   - `recommendation`: non-destructive text only, e.g. "These test runs compete for the same CPU and Docker VM. Run them one at a time, or have the agents take turns." No stop action, no `requestStop`.
   - `startedAt`, `projects`, `agentTrees` (agent name + root identity), `affected: [ProcessIdentity]`, and container IDs.
2. **Agent tree.** For each expensive command (reuse `ExpensiveCommand.outermost`/`classify`, as `TimelineDetector` does), walk its parent chain in `tick.snapshot.processes` to the nearest ancestor that is a coding agent. Use the existing agent recognition (`ProvenanceResolver.agentKinds` or `RulesEngine.agentNames`; pick one, don't add a third list). The agent's root process identity is the tree's key. A command with no agent ancestor belongs to "no agent" (a person in a terminal). Containers that start in the same project inside the window count toward that project's burst, attributed through `tick.projects.containerAttributions`.
3. **Rules** (constants on the struct, documented):
   - **Burst:** ≥ 2 expensive commands *or* test runs started within `burstWindow = 10 s` across ≥ 2 agent trees, or across ≥ 2 projects. Containers started in the window are added as observations, and when ≥ 2 started, the title names them ("…and 3 containers").
   - **Confidence:** high when every command maps to an agent tree and a project; medium when some don't; low when it rests on containers alone.
   - **No spam:** a burst is reported once. It isn't reported again while the same set is still running, and a new one in the same project needs at least one new command. Same idea as `lastConcurrent` in `TimelineDetector`.
   - The first tick only sets the baseline, as in `TimelineDetector`.
4. **Wiring.** `LiveTick` gains `explanations: [Explanation]` (current, recent first, at most 5, dropped 10 minutes after their burst ends) set in `LiveMonitor`, next to where `detector.events(for:)` runs. Each new explanation also adds one `TimelineEvent` of a new kind `.concurrencyExplained` (with `isInference: true`) so it shows on the timeline and in history. If history stores `kind.rawValue`, make sure an old database still reads, and say how in the handoff.
5. **UI.** A compact "What's going on" card at the top of `App/LiveView.swift`, shown only when there are explanations, in a new file `App/ExplanationsCard.swift`. Each explanation shows its title, the recommendation and a confidence chip, and expands to show its observations (time + fact) and uncertainty. Follow the look and conventions of `App/ProjectViews.swift` and `App/TimelineView.swift`. No buttons that act on processes.
6. **FDA scenario test.** In `Tests/HeatLensCoreTests/ConcurrencyRulesTests.swift`, build synthetic ticks (follow `Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift` and `TimelineTests.swift`): two agent trees (a `claude` and a `codex` process) in one project "FDA", each starting `npm run test:integration` → `vitest` within 10 s, plus 3 containers attributed to FDA starting in the same window. Expect one explanation: 3 test-ish commands or 2 (count them as `outermost` does), 2 agent trees, 3 containers, high confidence, a non-destructive recommendation, and an observation for each. More tests: a single agent running one test (nothing), two commands 30 s apart (nothing), two projects with no agents (one explanation, "across 2 projects"), the same burst on the next 5 ticks (reported once), and the first tick (nothing). Also a cost test: 1,000 processes, `ConcurrencyRules` under 10 ms per tick after the first.

## Context
- Read first: `Sources/HeatLensCore/Live/TimelineDetector.swift` (the pattern to copy), `Sources/HeatLensCore/Live/ExpensiveCommand.swift`, `Sources/HeatLensCore/Live/LiveMonitor.swift` (~lines 170–230), `Sources/HeatLensCore/History/HistoryModel.swift` (`TimelineEvent`), `Sources/HeatLensCore/Projects/ProjectBreakdown.swift`, `ProcessTree` in `Sources/HeatLensCore/Provenance/WorkloadRules.swift`, `Sources/HeatLensCore/Model/Findings.swift` (`Evidence`, `Confidence`).
- Background: `docs/v2/PHASE-2-REPORT.md` ("Next: Phase 3 brief"), `docs/v2/PLAN.md` §Phase 3, ADR-0004 (project attribution).
- Rulings: rules first, no LLM. Explain and recommend only; no actions (the user's AI ruling). Inference is labelled as inference.
- Live cost budget: Phase 2 measured 1.1–1.2% of one core at 5 s. Don't add more than ~0.1 points. Cache per process identity as `TimelineDetector` does.

## Scope
- May touch: `Sources/HeatLensCore/Live/` (new `ConcurrencyRules.swift`, `LiveMonitor.swift` wiring), `Sources/HeatLensCore/History/HistoryModel.swift` (the new event kind only), `App/LiveView.swift` (insert the card), `App/ExplanationsCard.swift` (new), `App/TimelineView.swift` (only if the new event kind needs an icon or colour), `Tests/HeatLensCoreTests/ConcurrencyRulesTests.swift` (new), `docs/v2/PLAN.md` (mark 3b done in the Phase 3 list, one short "Did" line)
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/Explanation.swift` (new shared type)
- Must not touch: `Sources/HeatLensCore/Safety/`, `Sources/HeatLensCore/Docker/`, `Sources/HeatLensCore/History/HistoryStore.swift` (unless an old database won't read otherwise; say so), `App/SettingsView.swift`, `App/SettingsModel.swift`, `Package.swift`, `project.yml`, `docs/CLICKTHROUGH.md` and `docs/v2/PHASE-2-REPORT.md` (another worker is editing these two)
- Another worker is driving the app for a click-through at the same time. Don't launch or quit the app (`scripts/run-app.sh --build-only` only builds, so it's fine).

## Phase
This phase only: explanations for concurrency bursts. Alert policies (3c), safe actions (3d) and the audit trail (3e) are later briefs.

## Checks
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build 2>&1 | tail -20
scripts/with-timeout.sh 600 swift test --filter "ConcurrencyRules|Timeline|LiveMonitor|HistoryStore" 2>&1 | tail -30
scripts/with-timeout.sh 600 swift test 2>&1 | tail -15
scripts/run-app.sh --build-only 2>&1 | tail -20
```
In the handoff, give the user a verification step: in Live mode, run `(exec -a "npm ci" sleep 40) & (exec -a vitest sleep 40) &` from two different projects' folders in Terminal. Say what the card should show (no agent trees, so "across 2 projects").

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
