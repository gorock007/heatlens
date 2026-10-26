# Phase 1c: provenance quality on real data (fewer, better groups; no Library "projects")
worker: codex
model: gpt-5.6-sol
effort: high
started: 2026-10-26 18:02 · terminal: ddf28a91-fb52-42a4-b89d-8ec6dfd78a6e

## Goal
On this Mac a real scan gives 663 groups, many labelled "system — Unknown project" or "unknown — Unknown project". CapCut and Docker get the project "Data" from a `~/Library/Containers/…/Data` cwd. Make `ProvenanceResolver` produce a small, meaningful set of groups with honest project attribution. Done means a real `swift run heatlens-probe --report --no-fixtures` here yields **≤ 80 groups**, no project attributed to a Library, system or temporary path, and labels that read like names, with all tests green.

## Context
- You wrote `Sources/HeatLensCore/Provenance/ProvenanceResolver.swift` (handoff `handoffs/merged/2026-10-26-1745-p1-provenance-rules-export.md`). The real-data observations are in `handoffs/merged/2026-10-26-1800-p1b-wire-real-scan.md`, under "Notes for Jarvis". Also read `docs/FEASIBILITY.md` §8.
- **Pattern to copy:** your own resolver and `Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift`.
- Running in parallel: a Claude worker on `Sources/HeatLensCore/Safety/` and `RulesEngine.swift`, and a Codex worker on `App/`. Stay out of both.

## Rules to implement (pure functions; no file I/O, no `stat`)
1. **Never a project:** paths under `~/Library/`, `/Library/`, `/System/`, `/private/`, `/var/`, `/tmp/`, `/usr/`, `/Applications/`, `/opt/homebrew/`, `/`, `~` itself, and any hidden directory component (`/.foo/`). The one exception: `~/.superset/projects/<x>` and `~/.superset/worktrees/<x>/<y>` **are** projects, because agents run there. The project label is the meaningful directory name: `<x>`, or `<x>/<y>` for a worktree.
2. **App bundles:** every process whose executable is inside the same `*.app` bundle forms one group named after the bundle (`CapCut`, `Docker`, `Superset`, `Google Chrome`), including helpers that launchd parented. Kind `app` unless a more specific kind applies.
3. **System services:** root and other-user processes with Apple paths (`/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`) collapse into **one** group, "macOS system services", **except** `kernel_task`, `WindowServer` and any single system process at ≥ 10% CPU, which keep their own named group.
4. **Labels:** a label is a name ("next dev", "CapCut", "claude", "node worker.js"). The project goes in `ProjectAttribution` only, never into the label. No label may contain "Unknown project".
5. Keep every existing behaviour and test: agent ownership of helper processes, package-runner ownership of dev tools, evidence and confidence on every group.

## Scope
- May touch: `Sources/HeatLensCore/Provenance/`, `Tests/HeatLensCoreTests/ProvenanceResolverTests.swift`, `Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift` (additive)
- Must not touch: `App/`, `Sources/HeatLensCore/{Rules,Safety,Sampling,Coordinator,Export,Pipeline}/`, `RulesEngineTests.swift`, `docs/`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/` (shouldn't need changes)

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`. Then `swift run heatlens-probe --report --no-fixtures | grep -c ''`, and report the group count from the report's Groups section. Add synthetic tests for every rule above, with invented paths only. **Never paste real report output into the repo or the handoff.** Summarise it as counts and labels, with project names replaced by `<project>`. Never run git commands that change state.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
