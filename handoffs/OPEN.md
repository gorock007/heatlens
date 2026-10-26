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
- Phase 2 safety DONE: 2a/2b/2c/2d merged (d009384); review findings fixed except #5 (test tooling: perl alarm orphans swiftpm-testing-helper; use a process-group timeout). Ruling: exclusion also suppresses stop. 2e docs merged (d7cd4bf): PERFORMANCE.md, SCENARIOS.md, samples/. PRD §11 definition of done met in code; scenarios 8 & 9 are manual-only (need the click-through).
- CODEX: 5h limit exhausted, resets 22:38 on 2026-10-26. gpt-6.1-sol is model_not_found on this ChatGPT-plan account; gpt-5.6-sol works; gpt-6-astra untested. Until 22:38 no Codex routing (astra click-through waits).
- AFTER 22:38 (Codex reset; user must say 'resume' — the watcher won't wake Jarvis for it): probe gpt-6-astra, then codex gpt-6-astra click-through of the popover (computer use): scan, cancel, detail, settings, confirm dialog → Cancel only (never send SIGTERM to a real process).
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
