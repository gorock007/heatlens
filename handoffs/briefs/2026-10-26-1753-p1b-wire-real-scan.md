# Phase 1b: wire the real engine into the popover (ScanPipeline + concise report)
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-26 17:53 · terminal: 3420ad42-0d6c-4266-9525-bf24afb03c73

## Goal
Clicking **Scan now** runs a real scan of this Mac, with progress, grouping, ranked findings and a redacted, concise copied report. The fixture service only stays for SwiftUI previews. Done means `heatlens-probe --report` prints the same redacted text the app copies, from the same pipeline, on this machine, and the app builds with the real service as its default.

## Context
- Read first: the three Phase 1 handoffs in `handoffs/merged/`: `2026-10-26-1751-p1-samplers-coordinator.md` (see its "For the wiring brief" notes), `2026-10-26-1745-p1-provenance-rules-export.md` and `2026-10-26-1744-p1-popover-ui.md` (see its Notes for Jarvis). Also read PRD FR-03, FR-08, FR-11 and FR-13.
- **Pattern to copy:** `App/ScanService.swift` is the seam. `App/FixtureScanService.swift` shows the shape of a service. `Sources/heatlens-probe/main.swift` already drives `ScanCoordinator()`.

## What to build
1. **`Sources/HeatLensCore/Pipeline/ScanPipeline.swift`** (new; the one composition point, shared by the app and the probe):
   - `public struct ScanResult: Sendable { snapshot, groups, findings }`
   - `public struct ScanPipeline: Sendable { public init(coordinator: ScanCoordinator = ScanCoordinator(), rules: RulesEngine = RulesEngine()); public func run(duration:progress:) async throws -> ScanResult }`
   - The flow is `coordinator.scan` → `ProvenanceResolver.resolve` → `rules.evaluate`. Cancellation propagates.
2. **Concise text report (FR-11):** change `Redactor.textReport` to list only the top 15 processes by CPU, plus every process named in a finding, then one line: "N other processes omitted; Copy JSON for the full list". `jsonReport` keeps everything. Update `RedactorTests` and keep every existing privacy assertion.
3. **Finding kind:** add `public enum FindingKind: String, Codable, Sendable` (`highCPU, memoryPressure, swapInUse, staleDevServer, detachedWorker, uiHeavy, kernelTask, thermal`). Add `kind: FindingKind?` to `DiagnosticFinding`; the init parameter defaults to nil, so it's additive and old JSON still decodes. Make `RulesEngine` set it. In the app, replace the evidence-label heuristic in `Headline` with `kind`.
4. **App:**
   - `PipelineScanService` (in `App/`) wraps `ScanPipeline` and builds `reportText` with `Redactor.textReport`. `HeatLensApp` uses it.
   - Keep `FixtureScanService` for `#Preview` only.
   - Add a **Copy JSON** action next to Copy report.
   - Rows with `measurementSource == .ps` show their CPU and memory with a small "via ps" note, not "Not accessible".
   - Processes with `.processExited` show "Exited during scan".
   - FR-13: `ScanError.alreadyRunning` is ignored quietly (the model already guards it). Any other error shows the failed state with a plain message and a **Try again** button.
5. **Probe:** add `--report`, which runs `ScanPipeline` and prints `Redactor.textReport`. Use this to check the real pipeline end to end on this Mac. **Don't paste its output into the repo or the handoff.** Summarise counts and finding titles only, with project names replaced by `<project>`.

## Scope
- May touch: `Sources/HeatLensCore/Pipeline/`, `Sources/HeatLensCore/Export/Redactor.swift`, `Sources/HeatLensCore/Rules/RulesEngine.swift` (setting `kind` only), `Sources/heatlens-probe/main.swift`, `App/` (except `Info.plist`), `Tests/HeatLensCoreTests/` (`RedactorTests.swift`, `RulesEngineTests.swift`, new `Pipeline*Tests.swift`)
- Must not touch: `Sources/HeatLensCore/{Sampling,Coordinator,Provenance,Parsing}/`, `project.yml`, `docs/`, `README.md`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/Findings.swift` (additive `kind` only)

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`. Then run `swift run heatlens-probe --report --no-fixtures 2>&1 | wc -l`; it should be ≤ ~60 lines, and you should read it for anything unredacted (home path, username, argv beyond argv[0]). Launch the app, take its PID, record idle `ps -o %cpu=,rss=` after 30 s, then quit it. List exactly what the user should click.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
