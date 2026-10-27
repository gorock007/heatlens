# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: green (5h 1% used, 11:07)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 DONE incl. 1c grouping (62 groups on this Mac).
- Phase 2 safety DONE: 2a/2b/2c/2d merged (d009384); review findings all fixed (#5: scripts/with-timeout.sh). Ruling: exclusion also suppresses stop. 2e docs merged (d7cd4bf): PERFORMANCE.md, SCENARIOS.md, samples/. PRD §11 definition of done met in code; scenarios 8 & 9 are manual-only (need the click-through).
- Phase 3a click-through DONE (docs/CLICKTHROUGH.md): all 10 steps pass; scenarios 6/8/9/11 verified by hand. Remaining unverified: scenario 7 wording (needs a Mac without thermal info), Activity Monitor comparison (user). Driving trick: cua.getApp times out on LSUIElement apps; a CoreGraphics click on the status icon + System Events works.
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
