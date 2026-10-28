# v2.1 Phase 4j: helper protocol, codec and XPC server/client (core)
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-28 14:45 · terminal: be153abd-de75-4f36-a8dd-a2e156c77826

## Goal
Brief **4j** in `docs/v2/ADR-0008-background-helper.md` ("4j · Core (v2.1)", ~lines 399–433),
built as specified: `Background/HelperProtocol.swift`, `HelperCodec.swift` (binary plist, 8 MB
cap, version check), `HelperXPC.swift` (`@objc` one-method protocols, `HelperServer`,
`HelperClient` with 1/2/5/10 s reconnect + replay, `HelperReadClient`), `Codable` on the tick
types, and `HelperProtocolTests` + `HelperXPCTests` as listed. Nothing registers or launches a
helper yet — that's 4k.

## Done when
- Every test listed in the 4j brief passes three runs in a row under
  `scripts/with-timeout.sh 600 swift test --filter "HelperProtocol|HelperXPC"`, and every existing
  test passes unchanged (`ModelCodableTests` included) in one full-suite run under the lock.
- `grep -rnE "kill\(|requestStop|forceQuit|ContainerStopper|StopLedger|URLSession|import Network" Sources/HeatLensCore/Background/` prints nothing.
- `swift build` and `scripts/run-app.sh --build-only` succeed.

## Context
- Read first: ADR-0008 §2 (IPC: services, requirements, envelope, control/read/push messages), §3
  (what runs where; one history writer), §4 (lifecycle incl. the 1-hour orphan pause, v2.1
  column), §Security review, and the 4j brief.
- Merged core it builds on: `handoffs/merged/2026-10-28-2000-v2-p4b-background-monitor.md`
  (`BackgroundMonitor`, `BackgroundStatus` is already Codable; API incl. `setAlerts`) and
  `handoffs/merged/2026-10-28-2000-v2-p4f-watchlists-core.md` (`ProjectWatch` is Codable;
  `Alert.watch`, `rule` optional).
- Owner decisions (final): the helper never signals, never writes to Docker, never posts
  notifications; MCP reads answer `.notRunning` unless configured, sampling and the MCP switch is on;
  a read never changes mode.
- Patterns: `MCPServer`'s strict argument handling (unknown → error, never a crash);
  `HistoryStoreTests` temp-directory stores; `LiveMonitorTests` fakes.
- This is a security boundary. Be strict: size cap before decode, version check, unknown case →
  error reply, control envelopes refused on the read handler.

## Scope
- May touch: `Sources/HeatLensCore/Background/HelperProtocol.swift`, `HelperCodec.swift`,
  `HelperXPC.swift` (all new); `Tests/HeatLensCoreTests/HelperProtocolTests.swift`,
  `HelperXPCTests.swift` (new); and, **conformance only** (name each in the handoff):
  `Live/LiveMonitor.swift`, `Projects/ProjectBreakdown.swift`, `Rules/AlertPolicy.swift`,
  `History/HistoryModel.swift`. If another type needs `Codable` (e.g. in `Live/`), add only the
  conformance and name it.
- Must not touch: `App/` (another worker, 4c, is editing it now), `Background/BackgroundMonitor.swift`
  (unless a missing accessor makes the server impossible — then the smallest addition, named),
  `Package.swift`, `project.yml`, CLI targets, `Safety/`, `Docker/`, docs, entitlements.

## Phase
One phase: 4j. 4k (helper target, registration, app client; needs a signed build) is later.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20`
- `scripts/with-timeout.sh 600 swift test --filter "HelperProtocol|HelperXPC" 2>&1 | tail -30` ×3
- the release-timing bound: `swift test -c release --filter HelperProtocol 2>&1 | tail -10` (if
  release testing isn't workable with `@testable`, say so and keep the debug bound)
- Full suite once via `handoffs/bin/jarvis lock suite --reuse -- scripts/with-timeout.sh 600 swift test 2>&1 | tail -30`.
- `scripts/run-app.sh --build-only 2>&1 | tail -20`.

## Questions first
The design is decided. Genuine contradictions only: one blocked handoff, then stop.
