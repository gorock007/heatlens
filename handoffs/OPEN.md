# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: amber (5h 46% used, 18:21)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
- 2026-10-26 18:22 · codex/gpt-6.1-sol high · term 3e7dd97c-fb81-458f-8758-66a19c0ba50c · handoffs/briefs/2026-10-26-1823-p2c-security-review-safe-stop.md
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 DONE (c4e8a73): real scans in the popover. Running now: 2a safe-stop engine (claude), 2b detail/stop/settings UI (codex), 1c provenance quality (codex).
- 2a (fe859d1) + 2b (55e55d6) merged. 2c security review + Safety fixture-hang fix running on codex gpt-6.1-sol (gpt-5.6-sol hit 'model at capacity' 18:23). Its findings → a fix brief.
- 1c (codex 5.6-sol) hit 'model at capacity' 18:22; nudged to continue. If it stalls again: respawn the same brief on gpt-6.1-sol --after nothing (its edits are uncommitted in Provenance/).
- Then: codex gpt-6-astra click-through of the popover (computer use): scan, cancel, detail, settings, confirm dialog → Cancel only (never send SIGTERM to a real process).
- Then: FR-12 perf profiling (idle after a real scan, scan cost), PRD §9 scenario sweep, sample reports (redacted, synthetic) per PRD §10.
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
