# PRD §9 scenario coverage

How each of the 12 testing scenarios in PRD §9 is covered today. Test references are
`file:line` of the `@Test`, under `Tests/HeatLensCoreTests/`. Run them all with
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test`.

**covered** = a test asserts the behaviour. **partial** = the engine is tested but part of the
scenario is not. **manual only** = no test exists.

| # | Scenario | How it's covered | Status |
|---|---|---|---|
| 1 | Active editing: labeled active work, not junk | `RulesEngineTests.swift:9` (CapCut and Claude at high CPU read as "active work"); `ProvenanceResolverTests.swift:65` (Claude recognised) | covered |
| 2 | Orphan worker: PPID 1, 48 h, near-zero CPU is "review" | `RulesEngineTests.swift:19` (review-only, "not causing meaningful heat"); `RulesEngineTests.swift:127` (no stop when the root fails eligibility) | covered |
| 3 | Old Next.js server, 38 h, idle | `RulesEngineTests.swift:30`; `ProvenanceResolverTests.swift:7` (Next dev children stay with the `npm` root) | covered |
| 4 | Hot build ranks as current contributor | `RulesEngineTests.swift:38` (hot Vitest ranks before a two-day idle worker); `CoordinatorTests.swift:214` (a real busy `yes` child measures at least 80% of a core) | covered |
| 5 | PID reuse never terminates the wrong process | `CoordinatorTests.swift:55` (reused PID mid-scan); `ProcessIdentityTests.swift:15`; `CPUMathTests.swift:41` (counter going backwards gives nil); `SafetyTerminatorTests.swift:196` (wrong start time sends nothing, child lives) | covered |
| 6 | Restricted process degrades gracefully | `ProvenanceResolverTests.swift:40`; `RedactorTests.swift:49` (nil argv and cwd export as unavailable); `SafetyEligibilityTests.swift:74` (unreadable details are denied); `SamplerTests.swift:122` and `CoordinatorTests.swift:145` (refused processes get `ps` data and notices). The on-screen "Not accessible" text is not tested: manual: run `scripts/run-app.sh`, click the thermometer, **Scan now**, and open a root-owned process in the results | partial |
| 7 | No thermal info: "unavailable", no invented temperature | `RulesEngineTests.swift:48` (no thermal finding when unavailable); `PmsetThermParserTests.swift:34` (no limit keys, nothing invented). The on-screen wording is not tested: manual: on a Mac that reports no thermal state, read the thermal line in results | partial |
| 8 | Idle app: no polling after a scan | No test. Before any scan: measured in `docs/PERFORMANCE.md` section 1, and the app has no timers. After a scan: manual: **Scan now**, wait for results, then run the `ps` and `top` commands from `docs/PERFORMANCE.md` twice, 30 s apart; CPU time must not grow. Not yet done | manual only |
| 9 | App quit: timers and tasks stop, no helper left | No test. Manual: run `scripts/run-app.sh`, click the thermometer, **Scan now**, then **Quit HeatLens** (or ⌘Q) during the scan; then `pgrep -fl "HeatLens|/bin/ps|pmset"` must print nothing. Not yet done by clicking | manual only |
| 10 | Cancellation leaves no orphan child | `CoordinatorTests.swift:234` (cancel mid-scan within about 1 s, no `ps` or fixture child left); `CoordinatorTests.swift:254` (cancel while `ps` runs ends that child); `CoordinatorTests.swift:99`; `PipelineTests.swift:64`; `SamplerTests.swift:156` and `:201` | covered |
| 11 | Protected processes never get kill controls | `SafetyEligibilityTests.swift:27`, `:33`, `:38`, `:45`, `:55`, `:60` (pid 0/1, HeatLens itself, non-owned, denylisted names and Apple paths); `RulesEngineTests.swift:88` and `:113` (stop offered only on eligible review findings); `SafetyTerminatorTests.swift:208`, `:224`, `:234` (live revalidation). The buttons themselves are not click-tested: manual: open a `WindowServer` or `launchd` process in the app, no **Request stop** appears | covered |
| 12 | More than 100% CPU on multiple cores | `CPUMathTests.swift:48` (multi-core work exceeds 100); `RulesEngineTests.swift:54` (180% is represented and rated high) | covered |

## Gaps

1. Scenarios 8 and 9 have no automated test. They need a running app.
2. No test drives the SwiftUI views, so every on-screen wording and button above is checked by
   reading the code and by the manual steps, not by an assertion.
