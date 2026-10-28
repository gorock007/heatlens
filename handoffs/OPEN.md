# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: green (5h 16% used, 11:23)

## Questions for the user
<!-- - <date> · <slug> · Q1 …  (batched from worker handoffs; remove when answered and passed back) -->

## Running workers
<!-- `jarvis spawn` adds: - <date HH:MM> · claude/claude-opus-5-5 high · term <id> · handoffs/briefs/<file>.md -->
<!-- `jarvis merge` removes the line -->

## Waiting on Jarvis
<!-- - handoff to review: handoffs/<file>.md · migration to apply · release to cut -->

## To-do
- Flaky: RedactorTests '1,000 processes … under a second' fails (1.1–2.1 s) when the Mac is under load (seen twice 2026-10-28); passes at 0.5 s idle. Loosen or move behind the suite lock in a future brief.
- At v2 release: site copy says no history (site/index.html ~249 'no background monitoring and no history', ~432 'nothing is stored after you quit'). True for v1.2.2; must change when v2 (Keep history) ships.
- v1.2.2 RELEASED 2026-10-28 (https://github.com/gorock007/heatlens/releases/tag/v1.2.2, main 59a7a98): ring app icon + menu-bar glyph; site Price and "What it can't tell you" sections + Limits nav link removed (live). releases/latest serves 1.2.2.
- v2 (branch run-jarvis-project-7dc121ed tracks origin/main; v2 pushed to main 2026-10-28 after merging v1.2.2 — unreleased, releases are manual): Phases 0–2 done (commits a48f55c..b5369cf, outside the handoff flow). Phase 3 in progress per docs/v2/PHASE-2-REPORT.md 'Next: Phase 3 brief': 3a click-through merged (49f8324; 2 gaps → 3a-fixes worker), 3b concurrency explanations merged (0e4d555); 3a fixes 876e8c4; projects in reports/MCP c294794; 3c alert policies merged 3d7ab02 (Live-only: Live stops when the panel closes, so alerts need a detached panel until Phase 4; HeatLensCore.Alert clashes with SwiftUI.Alert, rename to LiveAlert optional); 3d design merged dfd54b3 (ADR-0006/0007, SECURITY-REVIEW-3d; user rulings: force quit + container stop each behind an off-by-default switch, container stop = docker stop, scan results only). Build order from the ADRs' 'Build briefs': 3d-1 merged 2009819 → 3d-2 app force quit merged (README updated; LIMITATIONS had no such line; click-through for user in its handoff) + 3d-3 core container stop merged b778b4a (live test 12 NOT run: Docker was off) → 3d-4 app container stop (running) → 3d-4 app container stop. With 3d-2/3d-4 Jarvis fixes docs that say 'never force-quits/read-only' (README 4,46,97,107; site 7,21,29,493,497; LIMITATIONS 29) — only at v2 release for site.; then 3d builds from the ADRs' Build briefs, then 3e audit trail + ignore, then 3d safe actions (ADRs + security review first: force quit after separate confirmation; stop one selected container), 3e audit trail + ignore. Exit: FDA multi-worker Docker scenario.
- v2 owner decisions: 2. project names in report/MCP = YES (user 2026-10-28) — DONE, merged. 1. 'Keep history' stays OFF by default (user 2026-10-28); revisit at Phase 4 (background sampling).
- v1.1.0 RELEASED 2026-10-27 (https://github.com/gorock007/heatlens/releases/tag/v1.1.0): movable panel (6a), ports (8a), heatlens CLI/MCP bundled at Contents/Helpers/heatlens + Settings connect (7a/7b), report cap (7c). Notarization accepted the nested helper. Site download auto-serves it (releases/latest). 7d site copy merged (OpenCode; needed one correction: printed handoff instead of saving it).
- v1.2.1 RELEASED 2026-10-27 (https://github.com/gorock007/heatlens/releases/tag/v1.2.1): click-only Check for updates (10f). releases/latest + the GitHub API both serve 1.2.1. Users on 1.0–1.2.0 must download once by hand (said in the notes); from 1.2.1 on, the button finds new releases. Every future release MUST be a non-draft, non-prerelease GitHub release on gorock007/heatlens, or the button won't see it.
- Feature backlog (user-approved list) is now EMPTY. AI ruling stands: explain + propose typed actions only; no free-form command execution; CLI/MCP read-only.
- Phase 10 rulings (user, 2026-10-27): 10a thermal alert = opt-in/off by default, on rise to serious/critical run ONE scan + notify top culprit, click opens results, ≤1 per 30 min, no polling. 10b stop leftovers = one dialog listing each process with checkboxes, each PID revalidated before its SIGTERM, only rule-flagged leftovers, ≥2 per project. 10c before/after = in memory only; after a stop offer 'Rescan to see the difference'; any scan with a previous one this session shows 'Since last scan' (CPU, memory, swap, thermal, processes gone). 10d hotkey = fixed ⌃⌥H toggles panel, OFF by default, switch in Settings, no new dependency.
- Phase 1 DONE incl. 1c grouping (62 groups on this Mac).
- Phase 2 safety DONE: 2a/2b/2c/2d merged (d009384); review findings all fixed (#5: scripts/with-timeout.sh). Ruling: exclusion also suppresses stop. 2e docs merged (d7cd4bf): PERFORMANCE.md, SCENARIOS.md, samples/. PRD §11 definition of done met in code; scenarios 8 & 9 are manual-only (need the click-through).
- Phase 3a click-through DONE (docs/CLICKTHROUGH.md): all 10 steps pass; scenarios 6/8/9/11 verified by hand. Remaining unverified: scenario 7 wording (needs a Mac without thermal info), Activity Monitor comparison (user). Driving trick: cua.getApp times out on LSUIElement apps; a CoreGraphics click on the status icon + System Events works.
- v1.0.0 RELEASED 2026-10-27: https://github.com/gorock007/heatlens/releases/tag/v1.0.0 (notarized, DMG stapled, Gatekeeper accepted after a quarantined download via the site link). Site LIVE https://heatlens-app.vercel.app (Vercel project heatlens-app, scope gorock007s-projects, root dir site, git-connected; Vercel MCP cannot see this team, use `vercel api`). Notary profile `heatlens-notary` saved. MIT license.
- v1.0.1 RELEASED 2026-10-27 (https://github.com/gorock007/heatlens/releases/tag/v1.0.1): app icon (5a, 61fe527), app + DMG both notarized and stapled, DMG volume icon (5b, 99d8f5d); site Download serves it. 5c site icon DONE (f0c197a), live.
- Contributor guidance done (fc6df17): CLAUDE.md/AGENTS.md tell non-workflow agents to ignore handoffs/; README 'How this was built'. Ruling: Jarvis files stay public.
- Release = `scripts/release.sh` then `gh release create` (docs/RELEASING.md). Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
