# Phase 1c provenance quality on real data
status: done
agent: codex gpt-5.6-sol
brief: handoffs/briefs/2026-10-26-1803-p1c-provenance-quality.md
## What the user asked
Make real-process provenance produce at most 80 meaningful groups, reject Library/system/temporary paths as projects, group app bundles and system services honestly, and keep labels free of project placeholders while preserving existing ownership, evidence, and confidence behavior.
## What changed
- Project attribution now rejects `~/Library`, top-level Library/system/private/temporary/tool/app paths, the home directory, root, and paths containing hidden directory components. The explicit Superset project/worktree exceptions resolve to their meaningful project roots.
- App processes group by their outer `.app` bundle even when helpers are launchd-parented. The label is the bundle name and the kind is `app` unless a recognized workload such as Claude is more specific.
- Root and other-user Apple services collapse into `macOS system services`. `kernel_task`, `WindowServer`, and Apple services at 10% CPU or more remain individual named groups. Per-user agents embedded in `/System/Library` collapse into `macOS user services`, which avoids treating dozens of system helper bundles as projects/apps.
- Repeated named workloads coalesce by workload and project. Anonymous processes coalesce into honest project/background families rather than one group per launchd branch. Agent/helper and package-runner/dev-tool ancestry rules remain intact.
- Labels are workload names only (`next dev`, `claude`, `node worker.js`, bundle names, and service-family names); project attribution remains a separate field. Every group retains confidence and evidence.
- The latest aggregate-only real scan produced 62 groups, with 0 invalid project attributions and 0 labels containing `Unknown project`. No real process names, argv, paths, or reports were written into the repo.
## Files
- Sources/HeatLensCore/Provenance/ProvenanceResolver.swift — modified
- Tests/HeatLensCoreTests/ProvenanceResolverTests.swift — modified
- Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift — modified
- handoffs/2026-10-26-1825-p1c-provenance-quality.md — created
## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30` — passed; build complete and 92 tests in 17 suites passed.
- `scripts/run-app.sh --build-only 2>&1 | tail -20` — passed; produced the debug `HeatLens.app`.
- `swift test --scratch-path /tmp/heatlens-p1c-swift-ddf28a91 --filter ProvenanceResolverTests` — passed; 11 tests, including parameterized coverage of all excluded project-path classes, Superset exceptions, bundle grouping, service collapse/exceptions, labels, evidence, and preserved ancestry behavior.
- `swift run heatlens-probe --report --no-fixtures | grep -c ''` — exit 0; concise report was 69 lines.
- Latest aggregate-only real scan — 62 groups, 0 forbidden/hidden project paths, 0 placeholder labels. This is below the required 80-group ceiling.
- `git diff --check` on the three implementation/test files — passed.
- Not checked: the menu-bar popover was not opened, and the rendered groups were not manually compared with Activity Monitor.
- User verification: run `scripts/run-app.sh`, click the thermometer, click **Scan now**, and compare group names/members and high-CPU processes with Activity Monitor. CapCut, Docker, Superset, Chrome, and similar apps should appear once by bundle name; Library paths should not appear as projects; Apple services should be compact service groups except protected/hot processes. CLI verification: `swift run heatlens-probe --report --no-fixtures`.
## Processes left running
none
## Notes for Jarvis
- No shared model files were changed.
- The temporary aggregate validator and SwiftPM scratch build live under `/tmp/heatlens-p1c-*`; they contain no saved real scan report and are not repo files.
- Unrelated concurrent changes in `handoffs/OPEN.md` and `handoffs/briefs/2026-10-26-1823-p2c-security-review-safe-stop.md` were not touched and are not part of this handoff.
- Suggested commit message: `fix(core): improve real-data provenance grouping and project attribution (Phase 1c)`
