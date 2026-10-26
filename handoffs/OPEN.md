# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: amber (5h 33% used, 17:44)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
- 2026-10-26 17:53 · claude/claude-opus-5-5 medium · term 3420ad42-0d6c-4266-9525-bf24afb03c73 · handoffs/briefs/2026-10-26-1753-p1b-wire-real-scan.md
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 engine + UI merged (4c53ce3). 1b wiring + docs running (see Running workers).
- Phase 2: safe stop (FR-09: SIGTERM, PID/start-time revalidation, denylist). Band was amber at Phase 1 start, so opus high instead of fable unless green; plus a codex gpt-5.6-sol security review of it. Detail screen, exclusions/settings (5/10/15 s), optional history. Perf profiling (FR-12). Re-run probe from a signed bundle once signing exists.
- Phase 2 end-to-end click-through of the popover: codex gpt-6-astra (computer use).
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
