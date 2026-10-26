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
- 2026-10-26 17:38 · claude/claude-opus-5-5 medium · term a2b37c32-3fd9-4557-a304-b668d9a900d8 · handoffs/briefs/2026-10-26-1736-p1-popover-ui.md
- 2026-10-26 17:38 · codex/gpt-5.6-sol high · term 735b75d5-8e69-4204-af10-5ba422313432 · handoffs/briefs/2026-10-26-1736-p1-provenance-rules-export.md
- 2026-10-26 17:38 · claude/claude-opus-5-5 high · term cfc4cdd5-06b3-4a80-8532-bfca93e7dffd · handoffs/briefs/2026-10-26-1736-p1-samplers-coordinator.md
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 running (3 workers, see above). When all three merge: Phase 1b wiring brief (opus medium): real `ScanService` in App/ composing ScanCoordinator → ProvenanceResolver → RulesEngine → Redactor.textReport; delete FixtureScanService from the release path (keep for previews); FR-13 error states.
- Phase 2: safe stop (FR-09: SIGTERM, PID/start-time revalidation, denylist). Band was amber at Phase 1 start, so opus high instead of fable unless green; plus a codex gpt-5.6-sol security review of it. Detail screen, exclusions/settings (5/10/15 s), optional history. Perf profiling (FR-12). Re-run probe from a signed bundle once signing exists.
- Phase 2 end-to-end click-through of the popover: codex gpt-6-astra (computer use).
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
