# Phase 7b: ship `heatlens` inside HeatLens.app, "Connect to an AI agent" in Settings, `ports` command/tool, lean MCP output
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-27 13:29 · terminal: cefffb3b-db24-40ab-ba64-21e3492428e8

## Goal
Make the CLI/MCP server something DMG users actually get, and make it cheap for agents. Done means:
1. **Bundled.** The Debug and Release app builds contain an executable `HeatLens.app/Contents/MacOS/heatlens`, built from `Sources/heatlens`. It is signed with hardened runtime like the app, and `HeatLens.app/Contents/MacOS/heatlens --version` runs from the built app. Recommended: expose `HeatLensCLI` as a library product in `Package.swift`, add an xcodegen `tool` target `heatlens` in `project.yml` (sources `Sources/heatlens`, dependency on package product `HeatLensCLI`), and have the app target depend on it with `copy: {destination: executables}`. A cleaner way is fine; say why.
2. **Release signing.** `scripts/release.sh` signs `Contents/MacOS/heatlens` (hardened runtime + timestamp, same `sign_args`) before the app, without `--deep`. `scripts/release.sh --identity - --skip-notarize` succeeds, and `codesign --verify --strict` passes on both the binary and the app. **Don't** run a real-identity build or notarize. That's Jarvis's job.
3. **Settings.** Add a "Connect to an AI agent" section to `App/SettingsView.swift`:
   - one plain sentence: "Lets Claude Code, Codex or another MCP client run a read-only HeatLens scan."
   - the exact Claude Code command built from the running app's real location: `claude mcp add heatlens -- '<Bundle.main.bundleURL>/Contents/MacOS/heatlens' mcp`. Quote the path for spaces.
   - a Copy button that uses the 2-second "Copied" reset already in the app (`.resetsAfterCopy`, `App/FindingCard.swift`)
   - a second, smaller copy row for Codex: `codex mcp add heatlens -- '<path>' mcp`

   Nothing is executed; it only copies text. If the app isn't running from a stable location (the path contains `/AppTranslocation/` or the DMG volume `/Volumes/`), show "Move HeatLens to Applications first" instead of the commands.
4. **Lean MCP output.** The `scan` tool returns only the text report by default. It takes a new optional boolean `includeJSON` (default false); when true, it adds a second item with **compact** (not pretty-printed) JSON. Update the schema and description accordingly. A 391 KB JSON per call was eating ~100k tokens of an agent's context.
5. **Ports without a CPU sample.**
   - `heatlens ports [--json]` reads processes once (no sampling interval), groups them with the same resolver the scan uses, reads listening ports, and prints them redacted, like the report's "Listening ports" section (JSON: the same `listeningPorts` rows the report has).
   - Add an MCP tool `ports` (no arguments, `readOnlyHint: true`) that returns the same text. It must answer in well under a second.
   - Put the core entry point in `HeatLensCore` as a small public API (e.g. `PortsSnapshot` / `ScanPipeline.ports()`), built from what's already there: the process reading that `ScanCoordinator` does, `LibprocPortSampler`, the provenance grouping, `PortListing`, and the `Redactor` port formatting. Don't duplicate the formatting.
6. **Docs.**
   - Update README's "Use from a terminal or an AI agent" section: the installed app path, the Settings button, `ports`, and `includeJSON`.
   - Add one line to `docs/RELEASING.md` saying the version bump touches `heatlensVersion` in `Sources/HeatLensCLI/Arguments.swift` and `MARKETING_VERSION` in `project.yml`.

## Context
- Prior handoffs:
  - `handoffs/merged/2026-10-27-1320-p7a-cli-mcp.md`: CLI layout and MCP rules. Read-only, always redacted, no new dependencies. These still hold.
  - `handoffs/merged/2026-10-27-1327-p8a-listening-ports.md`: `PortReading`, `PortListing`, the Redactor sections, `ScanAssembly`.
  - `handoffs/merged/2026-10-27-1145-p4a-release-pipeline.md` (if present) for `release.sh`.
- Patterns to copy:
  - the new MCP tool follows the `scan` tool in `Sources/HeatLensCLI/MCPServer.swift`
  - the CLI subcommand follows `scan` in `Sources/HeatLensCLI/Arguments.swift`
  - tests extend `Tests/HeatLensCLITests/CLITests.swift` (fake runners) and `Tests/HeatLensCoreTests/PortSamplingTests.swift`
  - the Settings section follows the existing sections in `App/SettingsView.swift`
  - nested signing follows the existing loop at `scripts/release.sh:85-96`
- Rulings: still no stop/kill tool, no redaction-off flag, no new dependencies, and no version bump (Jarvis bumps at release).
- `/Applications/HeatLens.app` (1.0.1) may be running. Don't touch it. Launch your Debug build with `open -n`.

## Scope
- May touch: `Sources/HeatLensCLI/`, `Sources/heatlens/`, `Tests/HeatLensCLITests/`, `Tests/HeatLensCoreTests/`, `Sources/HeatLensCore/Pipeline/`, `Sources/HeatLensCore/Coordinator/`, `Sources/HeatLensCore/Sampling/PortSampling.swift`, `Sources/HeatLensCore/Export/Redactor.swift` (only to share the port formatting), `App/SettingsView.swift`, `scripts/release.sh`, `README.md`, `docs/RELEASING.md`
- Must not touch: `App/StatusPanel.swift`, `App/HeatLensApp.swift`, `App/ResultsView.swift`, `Sources/HeatLensCore/Safety/`, `Sources/HeatLensCore/Rules/`, `site/`, `dist/` (except what the ad-hoc release run writes there; leave it uncommitted and say so)
- Shared files (edit minimally, name in handoff): `Package.swift` (the `HeatLensCLI` library product only), `project.yml` (the tool target and the app's dependency on it), `Sources/HeatLensCore/Model/` (only if a type must change)

## Done when
- Checks pass, with new tests for `includeJSON` (default off, compact when on), the `ports` tool and subcommand, and the core ports entry point.
- `ls .build/xcode/Build/Products/Debug/HeatLens.app/Contents/MacOS/` shows `heatlens`, and `…/MacOS/heatlens ports` prints ports in under 1 s (`time` it).
- `scripts/release.sh --identity - --skip-notarize 2>&1 | tail -20` succeeds, and `codesign --verify --strict --verbose=2` passes on the staged app's `Contents/MacOS/heatlens`.
- In the Debug app, Settings shows the Connect section with the right path. Copy puts the command on the clipboard (restore the previous clipboard text afterwards), and the label resets. The handoff names a screenshot path.
- `claude mcp add heatlens -- '<Debug app>/Contents/MacOS/heatlens' mcp` then `claude mcp list` shows it connected; then `claude mcp remove heatlens`.

## Phase
One phase.

## Checks
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`, then `scripts/run-app.sh --build-only 2>&1 | tail -20`. Bound long runs with `scripts/with-timeout.sh 600`.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After
the answers arrive on your terminal, finish this phase without stopping
again. If you have no questions, build straight through.
