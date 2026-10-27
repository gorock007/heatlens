# Phase 7b: ship `heatlens` inside HeatLens.app, "Connect to an AI agent" in Settings, `ports` command/tool, lean MCP output
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1330-p7b-bundle-cli-connect.md

## What the user asked
Put the `heatlens` CLI/MCP server inside the app (signed like the app), add a Settings section that
copies the `claude mcp add` / `codex mcp add` command, make the MCP `scan` tool return only the
text report unless `includeJSON` is set, add a fast `ports` command and MCP tool, and update the docs.

## What changed
- **Bundled, at `Contents/Helpers/heatlens`, not `Contents/MacOS/heatlens`. This differs from the
  brief, and the brief's path can't work.** APFS here is case-insensitive, so `MacOS/heatlens` *is*
  `MacOS/HeatLens`. The first build put the CLI over the app's own executable.
  `Contents/Helpers/` is Apple's documented place for helper tools. It is signed as nested code,
  and the command name stays `heatlens`. Everything below (Settings, README) uses that path.
- **xcodegen target `heatlens-cli`** (type `tool`, sources `Sources/heatlens`, depends on the new
  `HeatLensCLI` library product), with `PRODUCT_NAME: heatlens` and `PRODUCT_MODULE_NAME: heatlens_cli`.
  The app depends on it with `embed: true, codeSign: true, copy: {destination: wrapper, subpath: Contents/Helpers}`.
  The target is not named `heatlens` for the same case-insensitivity reason. With that name, its
  intermediates folder and `.swiftmodule` were the same as the app's, and the **Release**
  `heatlens` linked the app's objects. Running `heatlens --version` then launched a second HeatLens
  menu-bar app. Debug only worked by luck. The rename fixes both configurations (checked, see below).
  Hardened runtime is on in the target settings. As with the app, Xcode's ad-hoc Debug signing
  doesn't set the runtime flag; `release.sh` does.
- **`scripts/release.sh`** signs every executable in `Contents/Helpers/` with the same
  `sign_args` (runtime, plus `--timestamp` for a real identity) and `--identifier dev.heatlens.<name>`,
  then verifies it with `--strict`, all before the app is signed. It doesn't use `--deep`.
- **Settings → "Connect to an AI agent"** (`App/SettingsView.swift`):
  - the sentence from the brief
  - the Claude Code command with the single-quoted helper path (`'` inside the path is escaped
    as `'\''`), selectable, plus a **Copy Claude Code command** button
  - a smaller Codex row with **Copy**

  Both buttons use `.resetsAfterCopy` ("Copied" for 2 s). If the bundle path contains
  `/AppTranslocation/` or starts with `/Volumes/`, the section shows "Move HeatLens to
  Applications first" instead of the commands. Nothing is executed.
- **MCP `scan`** returns only the text report by default. The new optional boolean `includeJSON`
  (strict JSON boolean, default false) adds a second item: the JSON report re-encoded compact (one
  line, sorted keys, slashes unescaped). The schema and description are updated. `heatlens scan --json` on
  the command line still prints pretty JSON.
- **`heatlens ports [--json]`** and **MCP tool `ports`**. The tool takes no arguments
  (`additionalProperties: false`, `readOnlyHint: true`, `openWorldHint: false`) and returns the text.
  - Core entry point:
    - `ScanCoordinator.ports()` does one process read plus `LibprocPortSampler`. It skips host
      counters, `ps` and pmset.
    - `ScanAssembly.portsSnapshot` builds a `ScanSnapshot` with interval 0, no CPU and a
      placeholder `system`, plus the refused-processes notice.
    - `ScanPipeline.ports()` adds `ProvenanceResolver.resolve` and returns a new public
      `PortsSnapshot { snapshot, groups, listings }`.
  - Formatting: `Redactor.portsTextReport` is a header line ("HeatLens listening ports, read
    <ISO time>"), then Notices, then the **same** "Listening ports:" lines. The scan report now
    uses the same private `portLines` helper. `Redactor.portsJSONReport` gives
    `{readAt, notices, listeningPorts}` with the same `RedactedPort` rows, from a shared
    `portRows` helper. Nothing is duplicated.
- `heatlens --help` lists `ports`, and says mcp has two tools.
- Docs: the README section now covers the installed path, the Settings button, `ports` and
  `includeJSON`. `docs/RELEASING.md` has the `heatlensVersion` + `MARKETING_VERSION` note.

## Files
- Package.swift — modified (shared: `HeatLensCLI` library product only)
- project.yml — modified (shared: `heatlens-cli` tool target, the app's dependency on it)
- Sources/HeatLensCore/Coordinator/ScanAssembly.swift — modified
- Sources/HeatLensCore/Coordinator/ScanCoordinator.swift — modified
- Sources/HeatLensCore/Pipeline/ScanPipeline.swift — modified
- Sources/HeatLensCore/Export/Redactor.swift — modified (port formatting shared; ports reports)
- Sources/HeatLensCLI/Arguments.swift — modified
- Sources/HeatLensCLI/LiveScan.swift — modified
- Sources/HeatLensCLI/MCPServer.swift — modified
- Sources/heatlens/main.swift — modified
- Tests/HeatLensCLITests/CLITests.swift — modified
- Tests/HeatLensCoreTests/PortSamplingTests.swift — modified
- App/SettingsView.swift — modified
- scripts/release.sh — modified
- README.md — modified
- docs/RELEASING.md — modified
- handoffs/2026-10-27-1343-p7b-bundle-cli-connect.md — created

(`handoffs/OPEN.md` and the brief were already modified/untracked before I started. They aren't mine.)

## Checks run
- `swift build`: ok. `swift test`: **123 tests in 24 suites passed** (was 118). The new tests cover:
  - `includeJSON`: off by default, explicit `false`, compact when `true`, non-boolean values
    rejected, and `compact()` on bad input
  - the `ports` tool: listed with an empty schema, called with `{}` and with no arguments, any
    argument rejected, a failure becomes a tool error
  - `ports` / `ports --json` parsing
  - core: `coordinator.ports()` reads processes once, never touches host sampling, and gives no CPU
  - the ports text/JSON share their lines/rows with the scan report, and are sanitized
  - live: `ScanPipeline().ports()` finds this test's loopback listener in under 1 s
- `scripts/run-app.sh --build-only`: ok. `ls …/Debug/HeatLens.app/Contents/Helpers/` shows `heatlens`.
  `Contents/MacOS/` still has `HeatLens`. `…/Contents/Helpers/heatlens ports` took **0.08 s** (`time`).
- `scripts/release.sh --identity - --skip-notarize`: succeeded. `codesign --verify --strict --verbose=2`
  passes on `dist/stage/HeatLens.app/Contents/Helpers/heatlens` and on the app. The helper shows
  `Identifier=dev.heatlens.heatlens` and `flags=0x10002(adhoc,runtime)`. Its symbols contain no
  SwiftUI. `--version` prints `heatlens 1.0.1`, and `ports` takes 0.07 s.
  - Scripted MCP session on the staged Release helper: `tools/list` shows `[scan, ports]`.
    `ports` returns 1 item (~0.9 KB). `scan` returns 1 item. `scan` with `includeJSON:true`
    returns 2 items, the JSON on one line (~320 KB vs ~390 KB pretty).
- **`dist/` is back to how I found it.** The ad-hoc run overwrites `dist/HeatLens-1.0.1.dmg`,
  `dist/HeatLens.dmg`, `SHA256SUMS` and `dist/stage/`. Those held your real Developer ID–signed
  1.0.1 build (team 9PXJ82UU32). I copied `dist/` to my scratchpad first and copied it back
  afterwards. Checksums match (`33db37…b37b`), and the staged app shows the team ID again.
  So no ad-hoc artifacts are left in `dist/`.
- Live Debug app (my own instance via `open -n`, driven through System Events and a small CGEvent
  helper in my scratchpad):
  - Settings shows the section with the real path.
  - **Copy Claude Code command** put exactly
    `claude mcp add heatlens -- '<checkout>/.build/xcode/Build/Products/Debug/HeatLens.app/Contents/Helpers/heatlens' mcp`
    on the clipboard. The label read "Copied", then went back after ~2 s.
  - Codex **Copy** copied the `codex mcp add …` line and showed "Copied".
  - The previous clipboard text was saved first and restored afterwards (checked with `cmp`).
  - After the first look I moved the Codex label and Copy button onto one line above the command,
    because the command was squeezed into a narrow column. The screenshot shows the final layout.
- Screenshot (local only; it shows the real home path, **don't commit**):
  /private/tmp/claude-501/-Users-gorock--superset-worktrees-HeatLens-run-jarvis-project-7dc121ed/a9d5d2a8-63a4-4042-9cb2-b94ad2d55c2f/scratchpad/p7b-settings-connect.png
- I ran the copied command with `eval "$(pbpaste)"` in my scratchpad. `claude mcp list` showed
  `heatlens: …/Contents/Helpers/heatlens mcp - ✔ Connected`. Then I ran `claude mcp remove heatlens`,
  and the list no longer shows it.
- Quoting and the translocation/DMG check: I ran a copy of `AgentCommand` in a scratch script.
  `/Applications/My Apps/Heat'Lens.app` quotes correctly (checked by running it through `sh`).
  AppTranslocation and `/Volumes/…` paths give the "Move HeatLens to Applications first" text.
  The app has no test target, so this check isn't in `swift test`.
- `git diff --check`: clean.
- **Not checked:**
  - the "Move to Applications" text in the live app (not run from a DMG or translocated)
  - a real-identity signed build, or notarization of a bundle with a helper (Jarvis's job)
  - `codex mcp add` actually run
  - Activity Monitor comparison (no scan-logic changes)
- **For the user to verify:**
  1. Run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && scripts/run-app.sh --build-only`,
     then `open -n .build/xcode/Build/Products/Debug/HeatLens.app`.
  2. Open the gear, scroll to **Connect to an AI agent**, and click **Copy Claude Code command**.
  3. In a terminal, run `.build/xcode/Build/Products/Debug/HeatLens.app/Contents/Helpers/heatlens ports`.

## Processes left running
none. My two Debug app instances were stopped by PID. Two runs of the broken first Release helper
(it was the app binary, see above) were also mine, and were stopped by PID. `jarvis leftovers --mine`
reports nothing. PID 26715, a Debug HeatLens that was already running from this checkout when I
started, isn't mine and I left it alone. Its bundle was rebuilt underneath it, so relaunch it to
get the new Settings.

## Notes for Jarvis
- **Path change to confirm with the user:** the CLI is at `HeatLens.app/Contents/Helpers/heatlens`, not
  `Contents/MacOS/heatlens` (case-insensitive collision with `HeatLens`, see What changed). If a
  different name in `MacOS/` is preferred (e.g. `heatlens-cli`), it's a one-line `copy:` change, plus
  `AgentCommand.helperPath` and the README.
- **Release with a real identity:** the helper is signed by `release.sh` before the app, so
  notarization should accept it. This is the first notarized build with nested code, so check
  `notarytool log` if it's rejected.
- Shared-file edits: `Package.swift` (one `.library` product line) and `project.yml` (the
  `heatlens-cli` target, the app's dependency with copy-to-Helpers, and two comments explaining why).
  `HeatLens.xcodeproj` is generated and not tracked.
- If any other build folder still has stale outputs from the bad `heatlens` target name, delete
  `.build/xcode/Build/Intermediates.noindex/HeatLens.build/{Debug,Release}/HeatLens.build` and
  `.build/xcode/Build/Products/*/heatlens*`. I already cleaned this checkout's.
- **Follow-up worth a brief:** the default MCP `scan` text was 60–78 KB in one run under load, not the
  ~14 KB measured in 7a. That's because `Redactor.textReport` lists *every* process a finding
  names, without a cap. One finding named ~300 processes. Capping that list (e.g. "N more named
  in this finding") is in Redactor and Rules territory, which was outside this brief.
- `ScanCoordinator.ports()` doesn't take the scan lock, because it shares no state with a scan.
  It can run while a scan is waiting.
- Suggested commit message: `feat(app,cli): bundle heatlens in HeatLens.app (Contents/Helpers), Connect to an AI agent in Settings, ports command and MCP tool, text-only scan by default (Phase 7b)`
