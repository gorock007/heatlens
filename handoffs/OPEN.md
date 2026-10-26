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
- 2026-10-26 18:02 · codex/gpt-5.6-sol high · term ddf28a91-fb52-42a4-b89d-8ec6dfd78a6e · handoffs/briefs/2026-10-26-1803-p1c-provenance-quality.md
- 2026-10-26 18:02 · codex/gpt-5.6-sol high · term 118133ad-be70-4fcd-a947-bdfba07cc3de · handoffs/briefs/2026-10-26-1803-p2b-detail-stop-settings-ui.md
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 DONE (c4e8a73): real scans in the popover. Running now: 2a safe-stop engine (claude), 2b detail/stop/settings UI (codex), 1c provenance quality (codex).
- When 2a merges: codex gpt-5.6-sol security review of Sources/HeatLensCore/Safety/ + RulesEngine requestStop rule (read-only audit brief; fixes go to a follow-up brief).
- When 2a + 2b merge: if 2b used a temporary ProcessTerminator stub in App/, delete it (small brief, OpenCode-eligible? NO — safe-stop code never goes to free tier; use sonnet).
- Then: codex gpt-6-astra click-through of the popover (computer use): scan, cancel, detail, settings, confirm dialog → Cancel only (never send SIGTERM to a real process).
- Then: FR-12 perf profiling (idle after a real scan, scan cost), PRD §9 scenario sweep, sample reports (redacted, synthetic) per PRD §10.
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
