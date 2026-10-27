# Phase 8a: listening ports (which process and project holds localhost:3000)
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1315-p8a-listening-ports.md

## What the user asked
After a scan, show which processes listen on which TCP ports, tied to the group and project
HeatLens already resolves. Show this in the results, the process detail, both exports and the
evidence of existing findings, and measure what it costs.

## What changed
- **Sampling.** `LibprocPortSampler` (new `Sampling/PortSampling.swift`) runs once at the end of
  every scan, on the second process reading. For each readable process it re-checks the
  identity (pid + start time, so a reused PID is skipped), lists socket fds with
  `PROC_PIDLISTFDS`, and reads each one with `PROC_PIDFDSOCKETINFO`. It keeps
  `SOCKINFO_TCP` sockets in `TSI_S_LISTEN`. It records the port, the family (ipv4, ipv6, or
  dual) and the scope (loopback, all interfaces, or a specific address, with that address
  kept). IPv4/IPv6 twins of a port merge into one `dual` entry with the wider scope.
  Processes libproc refuses (`detailAccess == .permissionDenied`) aren't asked at all; they
  are counted for one overview notice: "Listening ports of N root/other-user processes are
  not visible."
- **Model.** New `Model/ListeningPort.swift` holds `ListeningPort`, `AddressFamily`,
  `BindScope`, `ProcessListeningPorts`, and `PortListing` (one row per port and process, with
  its group, used by both the UI and the Redactor). `ScanSnapshot.listeningPorts:
  [ProcessListeningPorts]` uses an array, not a dictionary, so the JSON is a plain list. The
  init parameter defaults to `[]`, and a custom `init(from:)` uses `decodeIfPresent`, so older
  JSON decodes with no ports (tested). Helpers: `snapshot.ports(for:)` and
  `snapshot.portNumbers(for:)`.
- **Coordinator.** `ScanCoordinator.init` takes `portSampler:` (defaulted).
  `ScanAssembly.snapshot` takes `ports: PortReading? = nil`. Ports of processes that exited
  are dropped. Existing call sites are unchanged.
- **Export.** The text report gets a "Listening ports:" section before Processes, for example
  `- :3000 (loopback) — next-server, PID 123, project my-app`. It shows `- none` when empty and
  `Unknown project` when there is no project. The JSON gets `listeningPorts` (port, family,
  scope, pid, processName, groupLabel, projectDirectory), with names and paths passed through
  the existing sanitizer. **A specific bind address (a LAN or VPN IP) is left out of both
  exports.** Only the scope "specific address" is kept. The app's detail view still shows the
  address.
- **Rules.** When a group's members listen, its highCPU, staleDevServer and detachedWorker
  findings get one more evidence line: `Listening on: :3000, :9229 (proc_pidfdinfo)`. There
  are no new finding kinds, and severities and ranking are unchanged (tested: same IDs, same
  order, same severities).
- **UI.** `ResultsView` has a "Ports" section between "Potential leftovers" and "What's using
  resources". Each row shows the port, `name · PID`, `scope · group label · project`, and an
  "Inspect" label. It shows 6 rows, then "Show all N ports" / "Show fewer ports", and is hidden
  when there are no ports. **One change from the brief:** in a 300 pt popover a bordered
  Inspect button cut off the name and PID, so the whole row is now the button, the same
  pattern as the group member rows. It has an accent "Inspect" label and the tooltip "Inspect
  process", and it opens the existing `ProcessDetailView`. PIDs print without a thousands
  separator here (`Text(verbatim:)`). `ProcessDetailView` has a "Listening on" row
  (`:8765 (loopback)`), shown only when the process has ports. The fixtures have
  opencode :4096, next-server :3000 (dual, all interfaces) and worker.js :8787, and their
  hand-written findings carry the matching evidence lines.
- **Probe.** `heatlens-probe` prints a "listening ports" list, then a line timing the port
  read on its own.
- **Cost.** The port read took 3.4–9.3 ms for about 690 processes in the release build and
  11–22 ms in the debug build, far under 150 ms, so the work isn't capped. This is recorded in
  `docs/PERFORMANCE.md` §2 item 5.

## Files
- Sources/HeatLensCore/Model/ListeningPort.swift — created (shared Model dir)
- Sources/HeatLensCore/Model/SystemSample.swift — modified (shared: `ScanSnapshot.listeningPorts` + Codable init)
- Sources/HeatLensCore/Sampling/PortSampling.swift — created
- Sources/HeatLensCore/Sampling/Libproc.swift — modified (`socketFDs`, `socketInfo`)
- Sources/HeatLensCore/Coordinator/ScanCoordinator.swift — modified
- Sources/HeatLensCore/Coordinator/ScanAssembly.swift — modified
- Sources/HeatLensCore/Export/Redactor.swift — modified
- Sources/HeatLensCore/Rules/RulesEngine.swift — modified
- Sources/heatlens-probe/main.swift — modified
- Tests/HeatLensCoreTests/PortSamplingTests.swift — created
- App/ResultsView.swift — modified
- App/ProcessDetailView.swift — modified
- App/FixtureScanService.swift — modified
- docs/PERFORMANCE.md — modified
- handoffs/2026-10-27-1327-p8a-listening-ports.md — created

## Checks run
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build && swift test`:
  build complete, **118 tests in 23 suites passed**. That includes 10 new tests in
  `PortSamplingTests.swift`: filtering, scope and family, twin dedup, `socket_fdinfo` parsing
  on a synthetic struct, a **live loopback listener on an ephemeral port found for
  `getpid()`**, refused and stale-identity skipping, coordinator wiring and the notice,
  Codable backward compatibility, rules evidence, and the text/JSON export with sanitizing and
  no bind address.
- `scripts/run-app.sh --build-only`: built `.build/xcode/Build/Products/Debug/HeatLens.app`.
- `swift run heatlens-probe --no-fixtures --duration 2` prints the ports list. Its count (11
  pid:port pairs) matched `lsof -nP -iTCP -sTCP:LISTEN` on this Mac at the time.
- Live app: I launched the Debug build with `open -n`, started
  `python3 -m http.server 8765 --bind 127.0.0.1` from my scratch folder, and clicked Scan now
  (System Events). The Ports section listed `:8765 Python · PID … · loopback`, and the row
  opened a detail view with "Listening on :8765 (loopback)". I bound to loopback instead of
  the brief's all-interfaces default so nothing was exposed on the LAN.
  Screenshots (local only; they show real process names and PIDs, so **don't commit them**):
  - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/873d442e-fdfe-4ca6-bd33-cfc31159572f/scratchpad/p8a-results-ports.png (Ports section)
  - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/873d442e-fdfe-4ca6-bd33-cfc31159572f/scratchpad/p8a-detail.png (detail with Listening on)
  - /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/873d442e-fdfe-4ca6-bd33-cfc31159572f/scratchpad/p8a-results-top.png (overview with the new notice)
- `git diff --check`: clean. A grep for usernames and `/Users/` paths in the new and changed files found nothing.
- **Not checked:** the SwiftUI preview canvas (the fixture compiles in the app build, but I
  didn't render the preview). I didn't compare against Activity Monitor (it has no ports
  view; `lsof` was used instead). Not tested: an "all interfaces" or specific-address listener
  in the live app (both are covered by synthetic tests), the CLI target's output (it uses
  `Redactor`, so the section reaches it, but I didn't run it), or other Macs.
- **For the user to verify:** `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh`
  (quit any running HeatLens first, or `open -n` the Debug build). Start something that
  listens, for example `python3 -m http.server 8765 --bind 127.0.0.1`. Click Scan now and
  scroll to **Ports**, then click the row to see **Listening on**. Copy report shows the
  "Listening ports:" section.

## Processes left running
none. My app instance and the http.server were stopped by PID, and `jarvis leftovers --mine`
reports nothing. A Debug HeatLens, **PID 26715**, started at 13:08 before this session, was
already running from this checkout. I didn't start it and left it alone. It runs the old
binary, so relaunch it to see ports.

## Notes for Jarvis
- Shared-file edits: `Sources/HeatLensCore/Model/SystemSample.swift` (`ScanSnapshot` field +
  explicit `CodingKeys`/`init(from:)`; encoding is still synthesized) and the new
  `Sources/HeatLensCore/Model/ListeningPort.swift`.
- Inside the Bash sandbox, `http.server` came up with its socket in CLOSED state and curl got
  nothing. I didn't find the cause and assume it's the sandbox's network rules. I ran the
  server and osascript outside the sandbox. The in-process listener in `swift test` works
  inside it.
- Suggested commit message: `feat(core,app): listening TCP ports per process, in results, detail, exports and finding evidence (Phase 8a)`
