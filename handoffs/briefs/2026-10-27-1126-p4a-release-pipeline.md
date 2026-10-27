# Phase 4a: Developer ID release pipeline (hardened runtime, DMG, notarize script), v1.0.0
worker: claude
model: claude-opus-5-5
effort: high
started: 2026-10-27 11:27 · terminal: 5ae4f6c6-b661-4475-b228-cbf0ccf2feda

## Goal
Add `scripts/release.sh`, which turns the checkout into a signed, notarized, stapled `dist/HeatLens-<version>.dmg`. Done means the script runs end to end with `--identity - --skip-notarize` (ad-hoc, no Apple credentials), the resulting Release app launches under the hardened runtime, and the docs say how to cut a release. **You don't sign with the real Developer ID and you don't notarize.** Jarvis runs the real thing afterwards.

## Context
- The app is a non-sandboxed menu-bar app (no entitlements file, `LSUIElement`). It spawns `/bin/ps` and `/usr/bin/pmset` and reads libproc. Distribution is Developer ID outside the App Store, as a free download from GitHub Releases.
- Identity on this Mac: `Developer ID Application: Gorakh Shetty (9PXJ82UU32)`, team `9PXJ82UU32`. The notary credentials will be a notarytool keychain profile named `heatlens-notary`, which doesn't exist yet. The user will create it.
- Pattern to copy: `scripts/run-app.sh` (xcodegen, then xcodebuild with `-derivedDataPath .build/xcode`, quiet with a tail on failure, `set -euo pipefail`).

## What to do
1. `project.yml`, on the HeatLens target:
   - `ENABLE_HARDENED_RUNTIME: YES`
   - `MARKETING_VERSION: "1.0.0"`, `CURRENT_PROJECT_VERSION: "1"`
   - keep `CODE_SIGN_IDENTITY: "-"` so Debug builds and `scripts/run-app.sh` still work unsigned

   `release.sh` re-signs the Release product itself. Add an entitlements file only if the hardened runtime actually breaks something you can name. Ask first, since the sandbox and entitlements choice belongs to Jarvis.
2. `scripts/release.sh [--identity <name|->] [--skip-notarize] [--notary-profile <name>]`:
   - Defaults: identity `Developer ID Application`, which codesign resolves; profile `heatlens-notary`.
   - Steps:
     - xcodegen, then a `-configuration Release` build into `.build/xcode`
     - copy the app to `dist/stage/`
     - `codesign --force --options runtime --timestamp --sign <id>`; skip `--timestamp` for `-`; sign nested code first if any exists, and no `--deep`
     - `codesign --verify --strict --verbose=2`
     - build `dist/HeatLens-<version>.dmg` with `hdiutil create -format UDZO`, containing the app and an `/Applications` symlink
     - sign the DMG
     - unless `--skip-notarize`: `xcrun notarytool submit <dmg> --keychain-profile <p> --wait`; on failure, print `notarytool log`; then `xcrun stapler staple` the DMG
     - `spctl -a -t open --context context:primary-signature -vv <dmg>` (expect "rejected" when ad-hoc, so warn only when `-`)
     - copy to `dist/HeatLens.dmg` (the stable name the site links to)
     - write `dist/SHA256SUMS`
   - Read the version from the built app's Info.plist, not from a hard-coded value.
   - Add `dist/` to `.gitignore`.
3. `docs/RELEASING.md`, short:
   - one-time `xcrun notarytool store-credentials heatlens-notary --apple-id <id> --team-id 9PXJ82UU32`
   - `scripts/release.sh`
   - the `gh release create v<version> dist/HeatLens-<version>.dmg dist/HeatLens.dmg dist/SHA256SUMS` command
   - how to verify with `spctl` and `stapler validate`
4. `README.md`: add an **Install** section above "Build and run the app": download `HeatLens.dmg` from `https://github.com/gorock007/heatlens/releases/latest`, drag to Applications, macOS 14+, Apple Silicon. Link `docs/RELEASING.md`. Change the Status line to drop "not yet signed/notarized" (signed and notarized from v1.0.0).

## Scope
- May touch: `scripts/release.sh` (create), `docs/RELEASING.md` (create), `README.md` (the Install section, Status line and a RELEASING link only), `.gitignore`
- Shared files (edit minimally, name in handoff): `project.yml`, `App/Info.plist` (only if the version keys require it)
- Must not touch: `Sources/`, `App/*.swift`, `Tests/`, `site/` (another worker), `Package.swift`
- Never: sign with the real Developer ID identity, run notarytool submit, create a GitHub release, or push. Those belong to Jarvis.

## Checks
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -30`
- `scripts/run-app.sh --build-only 2>&1 | tail -20` (Debug still builds)
- `scripts/with-timeout.sh 900 scripts/release.sh --identity - --skip-notarize 2>&1 | tail -30`, then:
  - `codesign -dvv dist/stage/HeatLens.app 2>&1 | grep -E "flags|Identifier"`, which must show `runtime`
  - `hdiutil verify dist/HeatLens.dmg`
- Launch the Release app from the stage folder (`open dist/stage/HeatLens.app`), confirm with `pgrep -x HeatLens` that it stays running for 10 s, then quit it with `osascript -e 'quit app "HeatLens"'`. Say in the handoff that clicking Scan now under the hardened runtime was **not** done (Jarvis checks it after real signing).
- `shellcheck scripts/release.sh` if installed.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
