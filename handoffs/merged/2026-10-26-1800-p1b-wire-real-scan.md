# Phase 1b: wire the real engine into the popover (ScanPipeline + concise report)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-26-1753-p1b-wire-real-scan.md

## What the user asked
**Scan now** runs a real scan of this Mac (progress, groups, ranked findings, redacted concise
report) through one shared `ScanPipeline`. `heatlens-probe --report` prints the same text the app
copies. The fixture service is kept for previews only.

## What changed
- **`ScanPipeline`** (new, `Sources/HeatLensCore/Pipeline/ScanPipeline.swift`): `ScanResult { snapshot, groups, findings }`
  and `ScanPipeline(coordinator:rules:).run(duration:progress:)`. It runs `coordinator.scan`, then
  `ProvenanceResolver.resolve`, then `rules.evaluate`. Cancellation and `ScanError` propagate. A task
  cancelled after sampling ends still throws instead of returning a result.
- **Concise text report (FR-11):** `Redactor.textReport` lists the top 15 processes by CPU
  (unmeasured ones sort last, so a tiny snapshot still lists its rows), plus every process a finding
  names, highest CPU first. Then it prints "N other processes omitted; Copy JSON for the full list".
  - **Beyond the brief, so the 60-line budget holds:** the Groups section lists only groups that
    contain a listed process, then "N other groups omitted". Without this, this Mac's 663 groups
    would put the report at about 700 lines.
  - The limit is `Redactor.textProcessLimit` (overridable via a `processLimit:` parameter).
    `jsonReport` is unchanged and still carries everything. All existing privacy assertions are kept.
- **`FindingKind`:** a new enum (`highCPU, memoryPressure, swapInUse, staleDevServer, detachedWorker, uiHeavy,
  kernelTask, thermal`) plus `DiagnosticFinding.kind: FindingKind?`. The init parameter defaults to nil
  and decoding is synthesized, so the change is additive. `RulesEngine` sets it on every finding.
  `Headline`'s "High load observed" now checks `kind == .highCPU` (high or medium) instead of the
  evidence-label heuristic.
- **App:**
  - `PipelineScanService` wraps one `ScanPipeline` and is the default in `HeatLensApp`.
  - `ScanReport` gains `reportJSON` and an `init(_ ScanResult)` that builds both exports with `Redactor`.
  - `FixtureScanService` is preview-only. It now builds its exports through that same init, and I
    deleted its hand-written report text. Its findings carry kinds.
  - The results footer is now two rows: **Copy report** and **Copy JSON** on top, **Done** and **Scan again** below. Four buttons
    don't fit in one row at 300 pt.
  - Group member rows and Inspect details show CPU and memory with "via ps" when
    `measurementSource == .ps`, and "Exited during scan" for `.processExited` (`Format.measurement`).
  - FR-13: `ScanError.alreadyRunning` returns quietly to idle. Any other error shows the existing
    failed view with plain words and **Try again**. The message is
    "HeatLens couldn't read process activity on this Mac. Nothing was changed. (…)", or a
    specific line for `invalidDuration`.
- **Probe:** `--report` runs `ScanPipeline`, prints `Redactor.textReport` and exits. It works with or without
  `--no-fixtures`; the fixture is stopped before printing.

## Files
- Sources/HeatLensCore/Pipeline/ScanPipeline.swift — created
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Sources/HeatLensCore/Rules/RulesEngine.swift — modified
- Sources/HeatLensCore/Model/Findings.swift — modified (shared; additive `FindingKind` + `kind`)
- Sources/heatlens-probe/main.swift — modified
- App/PipelineScanService.swift — created
- App/ScanService.swift — modified
- App/ScanModel.swift — modified
- App/HeatLensApp.swift — modified
- App/FixtureScanService.swift — modified
- App/Formatting.swift — modified
- App/ResultsView.swift — modified
- App/FindingCard.swift — modified
- Tests/HeatLensCoreTests/PipelineTests.swift — created
- Tests/HeatLensCoreTests/RedactorTests.swift — modified
- Tests/HeatLensCoreTests/RulesEngineTests.swift — modified
- handoffs/2026-10-26-1800-p1b-wire-real-scan.md — created

## Checks run
- `swift build`: Build complete. `swift test`: **69 tests in 15 suites passed**. 6 are new:
  - Pipeline end to end: a fake hot process becomes the first finding, with `kind == .highCPU`.
  - Pipeline cancel: throws within 0.5 s.
  - Pipeline `.alreadyRunning`.
  - Every rule sets its kind.
  - The concise text lists 15 processes plus the finding's process, keeps an unmeasured root
    process out, prints the omitted line, has no home path, username or secret, and the JSON
    keeps all 32 processes.
  - A small scan prints no omitted line.
- `scripts/run-app.sh --build-only`: built `HeatLens.app`. A forced rebuild of `App/` showed no warnings or errors.
- `swift run heatlens-probe --report --no-fixtures`: exit 0, **47 lines**, saved only in my scratchpad.
  - No `$HOME` and no username anywhere.
  - Every argv is argv[0] only or `<N args redacted>`.
  - The detached worker's argv evidence shows `<arguments redacted>`.
  - Summary: 708 processes (206 filled from ps), 663 groups (16 listed), host 20.9% busy,
    pressure normal, thermal nominal.
  - Findings: "Potential detached worker" (a 55 h PPID-1 node script in
    `~/.superset/projects/<project>`) and "Swap in use with normal pressure" (7.6 GiB).
- **Idle app:** launched via `open`, PID 89987. With the popover never opened:
  - after 30 s: `%cpu 0.0`, RSS 86,880 KB, CPU time 0:00.21
  - 10 s later: unchanged
  - Quit via osascript; the PID is gone. `jarvis leftovers --mine`: nothing running.
- **Not checked:**
  - No click in the popover, because I can't drive the menu bar from a script. The real-scan UI,
    the two-row footer at 300 pt, the "via ps" and "Exited during scan" text, and the pasteboard
    contents have not been seen.
  - The idle CPU after a real scan was not measured.
  - The failed state has not been triggered live.
- **User verification:** run `scripts/run-app.sh`, then:
  1. Click the thermometer, then **Scan now**. Progress should count 1…10 of 10 seconds.
  2. Compare the results with Activity Monitor (View → All Processes, % CPU):
     - The headline should read "No significant issue observed" unless something is hot.
     - Under Potential leftovers there should be a detached node worker card.
     - Findings should include "Swap in use with normal pressure".
  3. Under What's using resources, expand a system group:
     - Root rows show CPU and memory with "· via ps", not "Not accessible".
  4. Click **Copy report** and paste it. Expect about 50 lines ending with "N other processes
     omitted; Copy JSON for the full list", with `~/` paths, no username, and no args beyond argv[0].
  5. Click **Copy JSON** and paste it. Expect the full JSON with every process.
  6. Click **Scan again**, then **Cancel** at about 4 s. Expect idle with "Last scan: just now".
  7. For the CLI version, run `swift run heatlens-probe --report --no-fixtures`. It prints the same text the app copies.

## Processes left running
none

## Notes for Jarvis
- **Shared-file edit:** `Sources/HeatLensCore/Model/Findings.swift` adds `FindingKind` and an optional
  `DiagnosticFinding.kind` (init default nil). Old initialisers and older JSON still work.
- **Seen on real data (Provenance owns the fixes; I didn't change anything there):**
  - Many group labels read "system — Unknown project" or "unknown — Unknown project".
  - CapCut and Docker get the project "Data", taken from a `~/Library/Containers/…/Data` cwd.
  - Worth a later rule: never attribute a project to `~/Library/Containers` paths.
- Suggested commit message: `feat: wire ScanPipeline into the popover and probe --report; concise text report, FindingKind, Copy JSON (Phase 1b)`
