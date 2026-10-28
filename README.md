# HeatLens

“Click once. See what's using your Mac, why, and what you can safely do.” HeatLens is an
on-demand, read-only macOS menu-bar diagnostic app that explains why a Mac is hot, noisy, slow,
or under resource pressure. It runs fully offline: nothing is monitored until you scan.

## Install

Website: https://heatlens-app.vercel.app

Download [`HeatLens.dmg`](https://github.com/gorock007/heatlens/releases/latest) from the latest
release, open it, and drag HeatLens to Applications. Requires macOS 14 or later on Apple Silicon.

To cut a release, see [docs/RELEASING.md](docs/RELEASING.md).

## Requirements

- macOS 14 or later
- Apple Silicon
- Xcode installed at `/Applications/Xcode.app`
- `xcodegen` (`brew install xcodegen`)

## Build and run the app

Build and launch:

```
scripts/run-app.sh
```

Build only:

```
scripts/run-app.sh --build-only
```

## Engine tests

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift test
```

## Use from a terminal or an AI agent

HeatLens.app ships a `heatlens` command at `HeatLens.app/Contents/Helpers/heatlens`. It runs the
same scan as the app and prints the same redacted report. It is read-only: it never stops or
changes a process.

```
heatlens=/Applications/HeatLens.app/Contents/Helpers/heatlens
"$heatlens" scan                          # 5-second scan, text report
"$heatlens" scan --seconds 10 --json > scan.json
"$heatlens" ports                         # listening TCP ports with their app or project, no CPU sample
"$heatlens" ports --json
"$heatlens" awake                         # what is keeping the Mac awake (power assertions), no CPU sample
```

To let Claude Code, Codex or another MCP client use HeatLens, open **Settings → Connect to an AI
agent** in the app and click **Copy Claude Code command** (or **Copy** next to Codex), then paste
it into a terminal. Move HeatLens to Applications first: the command holds the app's path. By hand:

```
claude mcp add heatlens -- '/Applications/HeatLens.app/Contents/Helpers/heatlens' mcp
codex mcp add heatlens -- '/Applications/HeatLens.app/Contents/Helpers/heatlens' mcp
```

The MCP server has three read-only tools:

- `scan` (`seconds` 1–15, default 5) returns the text report. Pass `includeJSON: true` to also
  get the full JSON report as a second, compact item. It is often hundreds of KB, so it's off by default.
- `ports` (no arguments) returns the listening ports, like the report's "Listening ports"
  section, in well under a second.
- `awake` (no arguments) returns what is keeping the Mac awake (power assertions such as
  `caffeinate`, with their process and project), like the report's "Keeping the Mac awake" section.

From a checkout, `swift build -c release` builds the same command at `.build/release/heatlens`.

## Developer CLI

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run heatlens-probe
```

## Privacy

- Fully local: no account or API key. The only network request is the update check, and only when you click Check for updates.
- No telemetry or analytics.
- No file contents are read.
- Nothing is stored except user settings, and the local history if you turn it on. HeatLens
  writes short operational notes (session start and stop, mode changes, errors) to the macOS
  unified log, which macOS keeps for a few days, with process and project names hidden. It keeps
  no log file of its own. To read them: `log show --last 1h --info --predicate 'subsystem == "dev.heatlens"'`.
- Reports redact home paths and process arguments by default.
- Optional thermal alert, off by default: when macOS reports serious heat, HeatLens runs one scan
  and posts one notification naming the top culprit, at most every 30 minutes. Nothing runs in between.
- Hardware sensors (v2, on by default): temperatures, fans and system power are read from the
  SMC, an undocumented macOS interface, read-only and without admin rights. Turn them off in
  Settings. CPU energy per process comes from a public macOS API.
- Docker containers (v2, off by default): by default, read-only queries to Docker's local socket.
  HeatLens never starts Docker. With "Allow stopping a container" on in Settings, a scan result's
  container detail can stop that one container, the way `docker stop` does, after a confirmation.
- History (v2, off by default): with "Keep history" on, Live mode's updates are saved in
  `~/Library/Application Support/HeatLens/history.sqlite` (owner-only), at most 30 days. Never
  command lines or file contents. Settings → Delete history removes it.
- Keep watching in the background (v2, off by default): after you close the panel, HeatLens keeps
  sampling at a slow, adaptive interval so alerts and history keep working. Quit HeatLens to stop.
- Export incident (v2): from an explanation, an alert or the Timeline's busiest moment, saves a
  redacted Markdown or JSON report only where you choose. It leaves out PIDs, paths, command
  lines and container IDs, and can replace project names with "Project A, B…".
- Optional global shortcut ⌃⌥H, off by default, opens or closes the panel from any app. It needs no
  Accessibility permission.

## Status

Read-only diagnosis and confirmed safe stop (SIGTERM only by default) implemented; signed and notarized from v1.0.0.
In v2, the Settings switch "Offer Force Quit when a process ignores a stop request" (off by default)
adds Force Quit (SIGKILL) for a process that ignored its stop request, behind a second confirmation.
When one project has several leftovers, one confirmation lists them all with checkboxes and stops
the selected ones in turn, re-checking each process right before its SIGTERM.
After a second scan, "Since last scan" shows what changed (CPU, memory pressure, swap, thermal,
processes gone), kept in memory only.

## Documentation

- [docs/PRD.md](docs/PRD.md)
- [docs/PRD-v2.md](docs/PRD-v2.md) and [docs/v2/](docs/v2/PLAN.md) (v2 plan, ADRs, compatibility)
- [docs/RELEASING.md](docs/RELEASING.md)
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md)
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md)
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md)
- [docs/SCENARIOS.md](docs/SCENARIOS.md)
- [docs/samples/](docs/samples/) (synthetic [text](docs/samples/report.txt) and [JSON](docs/samples/report.json) reports)

## How this was built

HeatLens was built with [Jarvis](https://github.com/gorock007/jarvis), a workflow where one
coordinating Claude Code session plans and reviews while worker agents (Claude Code and Codex)
build each phase in their own terminals. Every phase's brief is in
[`handoffs/briefs/`](handoffs/briefs/), and the worker's handoff (what changed, the checks it
ran, what it didn't verify) is in [`handoffs/merged/`](handoffs/merged/). That includes the
safe-stop security review and the menu-bar click-through. You don't need any of it to build,
test or contribute: see `scripts/run-app.sh` and the engine tests above.

## License

MIT. See [LICENSE](LICENSE).
