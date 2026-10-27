# Open items

Jarvis reads this first, every session, and keeps it current. One line per
item; an item goes in when it opens and comes out when it's done. Don't
rebuild "what's pending" by searching the handoff folders. Before Jarvis
stops, this file must hold everything a fresh session needs: `jarvis watch`
may `/clear` Jarvis after a long idle.

Jarvis session: cf788b09-038c-480c-b260-e01e536edeef
Usage band: green (5h 4% used, 11:18)

## Questions for the user
- 2026-10-27 · release · user must run in their own Terminal: `xcrun notarytool store-credentials heatlens-notary --apple-id <their Apple ID> --team-id 9PXJ82UU32` (app-specific password from account.apple.com). Blocks notarization only.
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
- RELEASE (user rulings 2026-10-27: free, Vercel subdomain, MIT, Developer ID 9PXJ82UU32). DONE: 4a release.sh (d9cf9e5), real signing verified, signed app scans OK; 4b site (129a46b) LIVE at https://heatlens-app.vercel.app (Vercel project heatlens-app, scope gorock007s-projects, root dir site, git-connected: every push to main redeploys); MIT LICENSE (bd30bac). LEFT: user saves notary profile → `scripts/release.sh` → `spctl`/`stapler validate` → `gh release create v1.0.0 dist/HeatLens-1.0.0.dmg dist/HeatLens.dmg dist/SHA256SUMS` → check site Download link 200. Vercel MCP connector cannot see this team; use `vercel api` CLI.
- Jarvis/user only: real signing + notarization. Remote: github.com/gorock007/heatlens (PUBLIC); branch tracks origin/main, push.default=upstream, commits use the noreply email.
