# HeatLens

“Click once. See what's using your Mac, why, and what you can safely do.” HeatLens is an
on-demand, read-only macOS menu-bar diagnostic app that explains why a Mac is hot, noisy, slow,
or under resource pressure. It runs fully offline: nothing is monitored until you scan.

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

## Developer CLI

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run heatlens-probe
```

## Privacy

- Fully local: no account, API key, or network access.
- No telemetry or analytics.
- No file contents are read.
- Nothing is stored except user settings.
- Reports redact home paths and process arguments by default.

## Status

Phase 1 (read-only MVP) in progress; process termination is not implemented.

## Documentation

- [docs/PRD.md](docs/PRD.md)
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md)
- [docs/LIMITATIONS.md](docs/LIMITATIONS.md)
