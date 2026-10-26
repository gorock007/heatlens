# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: green (5h 11% used, 17:09)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 (after 0a + 0b merge): split per 0a's "Phase 1 proposal" into 2–4 disjoint briefs. Likely: samplers (Process/System) · ProvenanceResolver + fixtures · RulesEngine + findings tests · popover UI wired to ScanCoordinator (scan/cancel/results/export). Engine briefs claude-opus-5-5 high; UI opus high.
- After Phase 1: add the app build (`scripts/run-app.sh --build-only`) to the Checks line in CLAUDE.md + AGENTS.md.
- Phase 2: safe stop (FR-09: SIGTERM, PID/start-time revalidation, denylist) on fable, plus a gpt-5.6-sol security review of it. Detail screen, exclusions/settings, optional history. Perf profiling (FR-12).
- Phase 2 end-to-end click-through of the popover: codex gpt-6-astra (computer use).
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
