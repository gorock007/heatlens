# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: amber (5h 57% used, 19:16)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 DONE incl. 1c grouping (62 groups on this Mac).
- 2a/2b/2c merged (2c review 8009831: no high/medium; 7 low). 2d fixes running (claude opus medium). Ruling made: an exclusion also suppresses the stop offer.
- CODEX: 5h limit exhausted, resets 22:38 on 2026-10-26. gpt-6.1-sol is model_not_found on this ChatGPT-plan account; gpt-5.6-sol works; gpt-6-astra untested. Until 22:38 no Codex routing (astra click-through waits).
- Then: codex gpt-6-astra click-through of the popover (computer use): scan, cancel, detail, settings, confirm dialog → Cancel only (never send SIGTERM to a real process).
- Then: FR-12 perf profiling (idle after a real scan, scan cost), PRD §9 scenario sweep, sample reports (redacted, synthetic) per PRD §10.
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
