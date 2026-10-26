# Phase 2d: fix the security review's low findings (export redaction, /bin denylist, bounded waits, double-dispatch)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-26 19:37 · terminal: 5e5e4e66-16c3-4f1d-99f9-5a3d018db7a4

## Goal
Every finding in the security review's "Notes for Jarvis" (`handoffs/merged/2026-10-26-1935-p2c-security-review-safe-stop.md`) is fixed except finding 5, with a test for each where one is possible. Done means the items below land, `swift test` passes three runs in a row, and none of the review's fake-secret repros leak.

## Context
- Read the review handoff in full first. It has `file:line` and a repro for each finding. Previous engine handoff: `handoffs/merged/2026-10-26-1809-p2a-safe-stop-engine.md`.
- **Pattern to copy:** the bounded `waitUntilGone`-style `FixtureChild.stop()` now in `Tests/HeatLensCoreTests/SafetyTerminatorTests.swift` (that's the fix for findings 4 and 7). `RedactorTests` shows the planted-secret test style.

## Fixes
1. **Finding 1, script names leak into exports.** Fix it in the **Redactor**, not in the resolver: the UI keeps showing the real script name locally. In both reports, a group label whose name came from argv (node, bun or python script kinds) exports as `<kind> <script>`, for example `node <script>`. The same goes for every finding title, explanation and evidence value that contains that label. Test with the review's repro (`sync-ghp_FAKETOKEN123.js`).
2. **Finding 2, secrets in paths and free text.** Redact path components that look like credentials (`ghp_`, `gho_`, `sk-`, `xox[abpr]-`, `AKIA`, hex ≥ 32 chars, base64-ish ≥ 32 chars) as `<redacted>` in cwd, project directory, `openProject` paths and evidence. Widen the free-text regex to the review's two patterns. Test with `~/clients/acme-merger/ghp_FAKETOKEN456`, `--auth-token=x`, `-p x` (only together with a password-ish flag name) and `API_TOKEN=x`.
3. **Finding 8, over-eager username replacement.** Replace the username only as a whole path component or a whole word. Test that `/usr/local` survives with the username `al`.
4. **Finding 3, `/bin/` missing from Apple directories.** Add `/bin/` and `/Library/Apple/` to `appleDirectories` in `ProcessTerminator.swift`. Move the terminator fixtures off Apple paths: copy `/bin/sleep` and `/bin/sh` into a per-test temp directory and spawn those copies. Update `SafetyEligibilityTests` so `/bin/sleep` and `/bin/zsh` are **denied**. The `/usr/bin/head` revalidation test stays.
5. **Finding 4, other unbounded waits.** Replace `terminate()` plus `waitUntilExit()` in `Tests/HeatLensCoreTests/SamplerTests.swift:34,45` and `Sources/heatlens-probe/Fixtures.swift:43` with the same bounded, identity-checked wait.
6. **Finding 6, double dispatch.** Make `guard case .confirmation = phase else { return }` the first line of `StopFlowView.requestStop()` in `App/ResultsView.swift`, and set the phase to `.stopping` synchronously before any `await`.
7. **Finding 7, no child deadline.** Give `ChildProcess` a per-run deadline (default 5 s) that cancels the child and surfaces as "unavailable" (`pmset` → no pmset data plus a notice; `ps` → the existing ps-failed notice). Test it with a stand-in child that sleeps 30 s and a 1 s deadline.
8. **Jarvis ruling on the open question:** an exclusion also suppresses the stop offer. In `App/ProcessDetailView.swift`, don't offer Request stop for a process whose findings are all hidden by the user's exclusions. Show "Excluded in Settings" in its place.

## Scope
- May touch: `Sources/HeatLensCore/Export/Redactor.swift`, `Sources/HeatLensCore/Safety/ProcessTerminator.swift`, `Sources/HeatLensCore/Sampling/ChildProcess.swift`, `Sources/HeatLensCore/Sampling/PSTimeSampler.swift` and `SystemSampling.swift` (only to surface the deadline as a notice), `Sources/heatlens-probe/Fixtures.swift`, `App/ResultsView.swift`, `App/ProcessDetailView.swift`, `Tests/HeatLensCoreTests/{Redactor,SafetyEligibility,SafetyTerminator,Sampler,Coordinator}Tests.swift`
- Must not touch: `Sources/HeatLensCore/{Provenance,Rules,Pipeline,Model}/`, `docs/`, `project.yml`, other `App/` files
- Shared files: none expected. Name any in the handoff.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`. Run three times; all three must pass. Then `scripts/run-app.sh --build-only 2>&1 | tail -20`. If you add a timeout wrapper, it must kill the whole process group, because `perl alarm` orphans `swiftpm-testing-helper` (review finding 5). Run `handoffs/bin/jarvis leftovers --mine` before handing off. Signal only children your tests spawned.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
