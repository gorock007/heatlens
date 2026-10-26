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
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Phase 1 running (3 workers, see above). When all three merge: Phase 1b wiring brief (opus medium): real `ScanService` in App/ composing ScanCoordinator → ProvenanceResolver → RulesEngine → Redactor.textReport; delete FixtureScanService from the release path (keep for previews); FR-13 error states. ALSO: Redactor.textReport lists every process (~500 lines); FR-11 wants concise: top ~15 by CPU + processes named in findings, full list only in JSON. DiagnosticFinding has no kind field; UI headline uses an evidence-label heuristic (Headline.text) — add a `kind` if cheap.
- Phase 2: safe stop (FR-09: SIGTERM, PID/start-time revalidation, denylist). Band was amber at Phase 1 start, so opus high instead of fable unless green; plus a codex gpt-5.6-sol security review of it. Detail screen, exclusions/settings (5/10/15 s), optional history. Perf profiling (FR-12). Re-run probe from a signed bundle once signing exists.
- Phase 2 end-to-end click-through of the popover: codex gpt-6-astra (computer use).
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
