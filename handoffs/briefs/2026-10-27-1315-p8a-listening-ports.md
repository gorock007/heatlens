# Phase 8a: listening ports — which process (and project) holds localhost:3000
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-27 13:15 · terminal: d0edcb33-26fe-4fc2-8df0-75457f669656

## Goal
After a scan, HeatLens shows which processes are listening on which TCP ports, tied to the project/group it already resolves. A developer can then see "`:3000` → next dev · my-app" and act on it with the existing Inspect / Open project / Request stop actions. Done means:
1. **Core sampling.** `Sources/HeatLensCore/Sampling/PortSampling.swift` lists TCP sockets in LISTEN state per PID. It uses public libproc: `proc_pidinfo(PROC_PIDLISTFDS)` to list the PID's file descriptors, then `proc_pidfdinfo(..., PROC_PIDFDSOCKETINFO)` for each socket fd; keep entries where `soi_kind == SOCKINFO_TCP` and `tcpsi_state == TSI_S_LISTEN`. Record port, address family and bind scope (loopback / all interfaces / a specific address). Sample once per scan, at the end, only for PIDs in the snapshot. A process libproc refuses (another user's or root's) is skipped quietly, and the overview gets one data-quality notice saying ports for other users' processes aren't visible. Deduplicate IPv4/IPv6 twins of the same port.
2. **Model.** Add a `ListeningPort` type (port, family, scope) and attach ports to the snapshot keyed by `ProcessIdentity` (e.g. `ScanSnapshot.listeningPorts: [ProcessIdentity: [ListeningPort]]` or an array of `(identity, port)`). Keep `Codable` backward compatible: a JSON without the field decodes as empty (`decodeIfPresent`). Keep existing initializers source-compatible with a defaulted parameter, so the fixtures and tests that build snapshots still compile.
3. **Export.** Add a "Listening ports" section to the text report (`:3000 (loopback) — next-server, PID 123, project my-app`) and a field to the JSON report. Port numbers aren't personal, but project names and paths go through the existing sanitizer exactly as they do elsewhere in `Redactor`.
4. **Rules.** Where an existing finding covers a group whose processes listen on ports, add an evidence line ("Listening on :3000, :9229"). Don't create new finding kinds and don't change severities or ranking.
5. **UI.**
   - `App/ResultsView.swift` gets a compact "Ports" section listing each port, the process name, the project/group label and an Inspect button (opens the existing `ProcessDetailView`). Collapse it if there are more than ~6 ports. Hide it entirely if there are none.
   - `App/ProcessDetailView.swift` gets a "Listening on" row.
   - Show the fixtures in `App/FixtureScanService.swift` with a couple of ports (e.g. the next dev server on 3000), so previews and fixture runs show the section.
6. **Cost.** Measure the time port sampling adds to a scan on this Mac (with `heatlens-probe` or a test timing). Add one line to `docs/PERFORMANCE.md`. It must stay well under the scan's own interval; if it's over ~150 ms, cap the work and say how.

## Context
- Prior handoff: none for ports. Sampling follows the Phase 1 sampling handoffs in `handoffs/merged/` (`ls handoffs/merged | grep -i p1`), but you shouldn't need them.
- Patterns to copy:
  - libproc calls follow `Sources/HeatLensCore/Sampling/Libproc.swift` (`static func … -> Result<…, Failure>`, buffer sizing, `proc_pidinfo` return-size checks)
  - where samplers are called and results land in the snapshot follows `Sources/HeatLensCore/Coordinator/ScanCoordinator.swift` / `ScanAssembly.swift`
  - report sections follow the existing ones in `Redactor.textReport`
  - tests use swift-testing like `Tests/HeatLensCoreTests/SamplerTests.swift`. Test socket-info parsing/filtering on synthetic values. Add one live test that opens a listening socket on an ephemeral loopback port in-process and finds it for `getpid()`.
- Another worker is adding a `heatlens` CLI/MCP target at the same time (new `Sources/HeatLensCLI/`, `Sources/heatlens/`, `Package.swift`). It prints `Redactor` output, so your export changes reach it automatically. Don't touch those paths.
- Privacy: never put real port listings from this Mac in the repo. Fixtures and synthetic data only.

## Scope
- May touch: `Sources/HeatLensCore/Sampling/` (new PortSampling.swift, small hooks in Libproc.swift), `Sources/HeatLensCore/Coordinator/`, `Sources/HeatLensCore/Export/Redactor.swift`, `Sources/HeatLensCore/Rules/RulesEngine.swift`, `Sources/heatlens-probe/main.swift` (print ports), `Tests/HeatLensCoreTests/`, `App/ResultsView.swift`, `App/ProcessDetailView.swift`, `App/FixtureScanService.swift`, `App/ScanModel.swift` if the report wrapper needs ports, `docs/PERFORMANCE.md`
- Must not touch: `Package.swift`, `Sources/HeatLensCLI/`, `Sources/heatlens/`, `App/StatusPanel.swift`, `App/HeatLensApp.swift`, `site/`, `scripts/`, `README.md`, `Sources/HeatLensCore/Safety/`
- Shared files (edit minimally, name in handoff): `Sources/HeatLensCore/Model/` (ListeningPort + the snapshot field)

## Done when
The Checks pass, and the new tests pass, including the live loopback-listener test. `swift run heatlens-probe --no-fixtures --duration 2` prints a ports list. Launching the app with `scripts/run-app.sh` (quit `/Applications/HeatLens.app` first, or launch the Debug build with `open -n`) shows the Ports section after a scan while something listens: start `python3 -m http.server 8765` from your scratch folder, and stop it before handing off. The handoff names a screenshot path in your scratch folder.

## Phase
One phase.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`. Bound with `scripts/with-timeout.sh 600` if anything hangs.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
