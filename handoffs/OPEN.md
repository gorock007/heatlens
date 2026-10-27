# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: green (5h 4% used, 11:18)

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
- v1.0.0 RELEASED 2026-10-27: https://github.com/gorock007/heatlens/releases/tag/v1.0.0 (notarized, DMG stapled, Gatekeeper accepted after a quarantined download via the site link). Site LIVE https://heatlens-app.vercel.app (Vercel project heatlens-app, scope gorock007s-projects, root dir site, git-connected; Vercel MCP cannot see this team, use `vercel api`). Notary profile `heatlens-notary` saved. MIT license.
- v1.0.1 IN PROGRESS (user: v1.0.0 DMG has no app icon): 5a icon (codex astra) + 5b release.sh staples the app + DMG volume icon (opus medium), disjoint files. After both merge: Jarvis bumps MARKETING_VERSION to 1.0.1 in project.yml → `scripts/release.sh` (two notary submissions now) → check icon in Finder/DMG + `stapler validate` on the app inside → `gh release create v1.0.1` (same 3 assets) → consider the new icon for site header/favicon/og (separate small brief).
- Contributor guidance done (fc6df17): CLAUDE.md/AGENTS.md tell non-workflow agents to ignore handoffs/; README 'How this was built'. Ruling: Jarvis files stay public.
- Release = `scripts/release.sh` then `gh release create` (docs/RELEASING.md). Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
