# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: amber (5h 12% used, 16:55)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
- 2026-10-27 16:52 · claude/claude-opus-5-5 high · term 9a6345ea-6f3c-4822-bcca-8f164c9b1124 · handoffs/briefs/2026-10-27-1720-p10c-before-after.md
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- v1.1.0 RELEASED 2026-10-27 (https://github.com/gorock007/heatlens/releases/tag/v1.1.0): movable panel (6a), ports (8a), heatlens CLI/MCP bundled at Contents/Helpers/heatlens + Settings connect (7a/7b), report cap (7c). Notarization accepted the nested helper. Site download auto-serves it (releases/latest). 7d site copy merged (OpenCode; needed one correction: printed handoff instead of saving it).
- 9a keeping-awake MERGED (unreleased). 1.2.0 = 9a + 10a–10d when all merged. AI ruling: explain + propose typed actions only; no free-form command execution; CLI/MCP read-only.
- Phase 10 rulings (user, 2026-10-27): 10a thermal alert = opt-in/off by default, on rise to serious/critical run ONE scan + notify top culprit, click opens results, ≤1 per 30 min, no polling. 10b stop leftovers = one dialog listing each process with checkboxes, each PID revalidated before its SIGTERM, only rule-flagged leftovers, ≥2 per project. 10c before/after = in memory only; after a stop offer 'Rescan to see the difference'; any scan with a previous one this session shows 'Since last scan' (CPU, memory, swap, thermal, processes gone). 10d hotkey = fixed ⌃⌥H toggles panel, OFF by default, switch in Settings, no new dependency.
- 10a MERGED b1b1f33, 10b MERGED 915ab66. USER TO VERIFY 10a banner (needs their Allow on the notification prompt): `open -n .build/xcode/Build/Products/Debug/HeatLens.app --args -thermalAlertsEnabled YES -HeatLensSimulateThermal serious` → Allow → banner names top CPU group → click opens panel.
- 10d hotkey MERGED 9165a1e (Settings row + runtime toggle + conflict msg not verified live; part of click-through). 10c before/after RUNNING (rulings sent: memory = pressure level; Gone = finding-named or ≥0.2 cores). After both merge: click-through of 10a–10d (fixtures mode for the 10b batch sheet), README line for 10c, then release 1.2.0.
- Phase 1 DONE incl. 1c grouping (62 groups on this Mac).
- Phase 2 safety DONE: 2a/2b/2c/2d merged (d009384); review findings all fixed (#5: scripts/with-timeout.sh). Ruling: exclusion also suppresses stop. 2e docs merged (d7cd4bf): PERFORMANCE.md, SCENARIOS.md, samples/. PRD §11 definition of done met in code; scenarios 8 & 9 are manual-only (need the click-through).
- Phase 3a click-through DONE (docs/CLICKTHROUGH.md): all 10 steps pass; scenarios 6/8/9/11 verified by hand. Remaining unverified: scenario 7 wording (needs a Mac without thermal info), Activity Monitor comparison (user). Driving trick: cua.getApp times out on LSUIElement apps; a CoreGraphics click on the status icon + System Events works.
- v1.0.0 RELEASED 2026-10-27: https://github.com/gorock007/heatlens/releases/tag/v1.0.0 (notarized, DMG stapled, Gatekeeper accepted after a quarantined download via the site link). Site LIVE https://heatlens-app.vercel.app (Vercel project heatlens-app, scope gorock007s-projects, root dir site, git-connected; Vercel MCP cannot see this team, use `vercel api`). Notary profile `heatlens-notary` saved. MIT license.
- v1.0.1 RELEASED 2026-10-27 (https://github.com/gorock007/heatlens/releases/tag/v1.0.1): app icon (5a, 61fe527), app + DMG both notarized and stapled, DMG volume icon (5b, 99d8f5d); site Download serves it. 5c site icon DONE (f0c197a), live.
- Contributor guidance done (fc6df17): CLAUDE.md/AGENTS.md tell non-workflow agents to ignore handoffs/; README 'How this was built'. Ruling: Jarvis files stay public.
- Release = `scripts/release.sh` then `gh release create` (docs/RELEASING.md). Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
