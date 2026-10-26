# Phase 1.2: pure provenance, deterministic findings and redacted export
status: done
agent: codex gpt-5.6-sol
brief: handoffs/briefs/2026-10-26-1736-p1-provenance-rules-export.md
## What the user asked
Implement and test the pure `ProvenanceResolver`, `RulesEngine`, `RuleThresholds` and `Redactor` APIs over synthetic `ScanSnapshot`s, covering the PRD §9 scenarios and Phase 0a's real-world grouping lessons without kernel calls or I/O.
## What changed
- `ProvenanceResolver` deterministically groups the captured parent tree around meaningful workload boundaries. A package runner owns its Next/dev-tool descendants; Claude/OpenCode agents beneath Superset own generic package-runner helpers. It recognizes every requested kind from exact executable or argv-token evidence, treats bare Node as weak evidence, and keeps application/system/unknown workloads distinct.
- Project attribution uses a captured cwd first and an absolute non-system argv path second. Missing evidence stays nil and is labelled “Unknown project”; every group includes confidence and evidence.
- `RuleThresholds` exposes named defaults. `RulesEngine` emits stable-ID findings for high CPU, memory pressure/normal-pressure swap, stale dev servers, detached workers, WindowServer, kernel_task and thermal state. It sorts measured CPU impact first, then severity/confidence; active agent/editor/build/CapCut work is never called junk.
- Recommended actions are read-only Phase 1 actions. `requestStop` is never produced; project actions require attribution, and command-copy is omitted for system or non-current-user roots.
- Text and JSON reports are built from dedicated Codable redacted values: home prefixes become `~`, argv after argv[0] becomes `<N args redacted>`, argv evidence is removed, token-shaped secrets in strings are removed, usernames are replaced case-insensitively, and no environment exists in the export.
- Synthetic tests cover PRD scenarios 1, 2, 3, 4, 6, 7, 11 and 12, the explicit impact ranking, all findings categories, real-world tree boundaries, cwd/argv attribution, deterministic IDs and text/JSON privacy.
## Files
- Sources/HeatLensCore/Provenance/ProvenanceResolver.swift — created
- Sources/HeatLensCore/Rules/RulesEngine.swift — created
- Sources/HeatLensCore/Export/Redactor.swift — created
- Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift — created
- Tests/HeatLensCoreTests/ProvenanceResolverTests.swift — created
- Tests/HeatLensCoreTests/RulesEngineTests.swift — created
- Tests/HeatLensCoreTests/RedactorTests.swift — created
- handoffs/2026-10-26-1745-p1-provenance-rules-export.md — created
## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30` — final retry passed: build complete; 43 tests in 9 suites passed.
- The first invocation collided with another worker modifying `Sources/heatlens-probe/Fixtures.swift` during compilation and temporarily failed in that out-of-scope executable. No probe file was touched here; the exact command passed after the concurrent rewrite settled.
- `git diff --check -- Sources/HeatLensCore/Provenance Sources/HeatLensCore/Rules Sources/HeatLensCore/Export Tests/HeatLensCoreTests/ProvenanceResolverTests.swift Tests/HeatLensCoreTests/RulesEngineTests.swift Tests/HeatLensCoreTests/RedactorTests.swift Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift` — passed.
- Not checked: live process output, kernel behavior, app UI integration or a real copied report; this phase is intentionally pure and the current app still uses its fixture service.
- User verification after the coordinator-to-app wiring lands: run `scripts/run-app.sh`, click the thermometer and **Scan now**, then compare the highest-CPU groups with Activity Monitor over the same sample. Check an idle old dev server appears under review below active CPU work, restricted rows say Unknown/Not accessible, no Request stop appears, and copied text/JSON contains `~` but no username or argv beyond argv[0].
## Processes left running
none
## Notes for Jarvis
- No shared files were edited by this worker.
- Same-app XPC attribution (for example CapCut's launchd-parented decoder) remains explicitly outside this brief, matching the Phase 0a limitation.
- The app integration should feed `ProvenanceResolver.resolve(snapshot)`, then `RulesEngine.evaluate(snapshot, groups:)`, and use `Redactor.textReport` for `ScanReport.reportText`.
- Suggested commit message: `feat(core): add provenance rules and redacted reports`
