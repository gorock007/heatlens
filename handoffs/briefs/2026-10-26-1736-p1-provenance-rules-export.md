# Phase 1.2: ProvenanceResolver, RulesEngine and Redactor (pure, tested)
worker: codex
model: gpt-5.6-sol
effort: high
started: 2026-10-26 17:38 · terminal: 735b75d5-8e69-4204-af10-5ba422313432

## Goal
Three pure, deterministic components in `HeatLensCore` that turn a `ScanSnapshot` into grouped processes, ranked evidence-backed findings, and a redacted export. Each comes with synthetic-snapshot tests for the PRD §9 scenarios. No kernel calls, no I/O. Done means the API below exists and `swift test` covers every scenario listed.

## Context
- Read first: `docs/PRD.md` §4.2, §4.3, §9 and FR-05/06/07/11; `docs/FEASIBILITY.md` §8 "Real-world grouping" (its observations are your acceptance list for the resolver) and "Phase 1 proposal"; the previous handoff `handoffs/merged/2026-10-26-1733-phase0a-feasibility-probe.md`.
- **Types to use (already exist, don't rename):** `ScanSnapshot`, `ProcessSample`, `SystemSample`, `ProcessGroup`, `ProjectAttribution`, `DiagnosticFinding`, `Severity` (info < review < medium < high), `Confidence`, `Evidence`, `SuggestedAction` in `Sources/HeatLensCore/Model/`.
- **Pattern to copy:** `Sources/heatlens-probe/Grouping.swift` is the probe's working grouping pass (ancestry, tool hints, project from cwd/argv). Port its logic. Note that another worker is rewriting `Sources/heatlens-probe/` in parallel, so read it now and don't edit it.
- Another worker owns `Sampling/` and `Coordinator/` (produces `ScanSnapshot`). A third owns `App/`.

## Public API (exactly this)
```swift
public enum ProvenanceResolver { public static func resolve(_ snapshot: ScanSnapshot) -> [ProcessGroup] }
public struct RuleThresholds: Sendable { public static let `default`: RuleThresholds; … named constants … }
public struct RulesEngine: Sendable {
    public init(thresholds: RuleThresholds = .default)
    /// Ranked impact-first: current measured impact, then severity/uncertainty. Order of the array IS the ranking.
    public func evaluate(_ snapshot: ScanSnapshot, groups: [ProcessGroup]) -> [DiagnosticFinding]
}
public enum Redactor {
    public static func textReport(_ snapshot: ScanSnapshot, groups: [ProcessGroup], findings: [DiagnosticFinding], homeDirectory: String = NSHomeDirectory()) -> String
    public static func jsonReport(_ snapshot: ScanSnapshot, groups: [ProcessGroup], findings: [DiagnosticFinding], homeDirectory: String = NSHomeDirectory()) throws -> Data
}
```

## Rules (start from these defaults as named constants; tune only with a test that shows why)
- **Group kinds:** `next dev`, `vite`, `astro`, `webpack`, `turbo`, `vitest`, `jest`, `tsc --watch`, `node script`, `bun`, `package runner` (npm/pnpm/yarn), `claude`, `opencode`, `superset`, `docker`, `capcut`, `app`, `system`, `unknown`. Group by parent tree first, then tool hints. Project comes from cwd, then an argv path; if neither, `project = nil` ("Unknown project"), never a guess. Every label carries evidence and confidence.
- **Sustained high CPU** (group CPU over the whole sample): ≥ 50% of one core → medium, ≥ 150% → high. For agent, editor, build and capcut kinds, the explanation says it looks like active work. Never call these junk.
- **Memory pressure:** pressure warning → medium, critical → high. High swap with normal pressure is at most info ("Swap in use but the OS reports normal pressure"). RAM usage alone is never pressure.
- **Potential stale dev server:** dev-server kind, uptime ≥ 12 h, group CPU < 2% → severity `review`, confidence medium, limitation "may be intentionally always-on".
- **Potential detached worker:** root PPID 1, node/bun/python script kind, uptime ≥ 24 h, CPU < 2% → `review`. Limitations: "PPID 1 is a clue, not proof" and "this does not prove it is unused".
- **UI-heavy:** WindowServer ≥ 30% → info, with "no causal proof; not a GPU percentage". **kernel_task** ≥ 50% → info, "a signal of thermal management, not proof".
- **Thermal:** `serious` → medium, `critical` → high, `fair` → info. `nominal` gives no finding. `unavailable` gives no finding (the UI shows "Unavailable").
- **Ranking:** a 2-day idle worker must never outrank an active 80%-CPU process. Sort by measured CPU impact first.
- **Actions:** `requestStop` is **never** emitted in Phase 1, and never for `system` kind, `kernel_task`, `WindowServer`, `launchd`, root-owned or unknown-owner processes. Offer `inspect`, `openProject` (only with an attribution), `copyCommand`, `openActivityMonitor`, `copyReport`.
- **Redactor (FR-11):** home-directory prefix → `~`; argv beyond argv[0] is dropped and replaced with `<N args redacted>` (argv can hold whole agent prompts and tokens); the username never appears anywhere; the environment is never included. The JSON report is `Codable` output of the redacted values.

## Tests (synthetic snapshots only, in `Tests/HeatLensCoreTests/Fixtures/SyntheticSnapshots.swift`)
PRD §9 scenarios:
- 1: active CapCut/claude at high CPU → active work, not junk.
- 2: PPID-1 worker, 48 h, ~0% → review, not "causing heat".
- 3: next dev, 38 h, idle → possible leftover.
- 4: vitest spike → ranked first.
- 6: argv/cwd nil → "Unknown project", no crash.
- 7: thermal unavailable → no thermal finding.
- 11: no `requestStop` anywhere.
- 12: 180% CPU process handled.
Also: the ranking rule above, and a redaction test that plants `/Users/someone/…`, a `--token=abc` arg and the username, then asserts that none of them survive in the text or JSON report. Use invented paths and names only.

## Scope
- May touch: `Sources/HeatLensCore/Provenance/`, `Sources/HeatLensCore/Rules/`, `Sources/HeatLensCore/Export/`, `Tests/HeatLensCoreTests/` (new files named `Provenance*`, `Rules*`, `Redactor*`, and `Fixtures/` only)
- Must not touch: `App/`, `project.yml`, `Sources/HeatLensCore/{Sampling,Coordinator,Parsing}/`, `Sources/heatlens-probe/`, `docs/`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/` (additive only), `Package.swift` (shouldn't need changes)

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`
Never run git commands that change state. Write your handoff per `AGENTS.md`.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
