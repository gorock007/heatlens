# Phase 4a: Developer ID release pipeline (hardened runtime, DMG, notarize script), v1.0.0
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1126-p4a-release-pipeline.md
## What the user asked
A `scripts/release.sh` that turns the checkout into a signed, notarized, stapled
`dist/HeatLens-<version>.dmg`, proven end to end with an ad-hoc identity and no notarization;
hardened runtime and v1.0.0 in `project.yml`; `docs/RELEASING.md`; an Install section in the README.
## What changed
- **Hardened runtime on, version 1.0.0 (build 1).** `CODE_SIGN_IDENTITY: "-"` kept, so Debug and
  `scripts/run-app.sh` still build unsigned. No entitlements file: nothing broke under the
  hardened runtime (the app launched and stayed up; it spawns `/bin/ps`/`pmset` and reads libproc,
  none of which need a runtime exception). No questions were needed.
- **`scripts/release.sh [--identity <name|->] [--skip-notarize] [--notary-profile <name>]`**
  (defaults `Developer ID Application`, `heatlens-notary`). Steps: xcodegen → Release build into
  `.build/xcode` (quiet, tail on failure) → version read from the built app's Info.plist → ditto to
  `dist/stage/HeatLens.app` → sign nested code deepest-first (none exists today; HeatLensCore links
  statically), then the app, with `--force --options runtime [--timestamp]` and no `--deep` →
  `codesign --verify --strict` → UDZO DMG with the app and an `/Applications` symlink, volume name
  `HeatLens <version>` → sign the DMG → unless `--skip-notarize`: `notarytool submit --wait`
  (plist output); if it exits non-zero or the status isn't `Accepted`, prints the submit output and
  `notarytool log <id>`, then fails; otherwise `stapler staple` → `spctl` assessment (a rejection only
  warns with `-`, fails otherwise) → `dist/HeatLens.dmg` copy → `dist/SHA256SUMS` (both DMGs).
  `--timestamp` is left off for `-`. Re-signing without `--entitlements` also drops any
  `get-task-allow`, which notarization would reject.
- **`.gitignore`**: `dist/`.
- **`docs/RELEASING.md`**: one-time `notarytool store-credentials`, `scripts/release.sh` with its
  options, verification (`spctl`, `stapler validate`, `codesign -dvv`), and the `gh release create` command.
- **README**: Install section (above Requirements, so above "Build and run the app") linking
  `releases/latest`, macOS 14+, Apple Silicon, plus a RELEASING link; Status line now reads "signed
  and notarized from v1.0.0"; RELEASING.md also added to the Documentation list.
## Files
- scripts/release.sh — created
- docs/RELEASING.md — created
- README.md — modified
- .gitignore — modified
- project.yml — modified
- handoffs/2026-10-27-1145-p4a-release-pipeline.md — created
## Checks run
- `swift build` — Build complete. `swift test` — 99 tests in 18 suites passed.
- `scripts/run-app.sh --build-only` — Debug builds (`.build/xcode/Build/Products/Debug/HeatLens.app`).
- `scripts/with-timeout.sh 900 scripts/release.sh --identity - --skip-notarize` — succeeded:
  `HeatLens 1.0.0 (1)`, app `valid on disk` / `satisfies its Designated Requirement`, DMG signed and
  verified, spctl `rejected` → warning (expected for ad-hoc), DMG and SHA256SUMS written.
- `codesign -dvv dist/stage/HeatLens.app` — `Identifier=dev.heatlens.HeatLens`,
  `flags=0x10002(adhoc,runtime)`, no entitlements.
- `hdiutil verify dist/HeatLens.dmg` — checksum VALID. Mounted read-only: contains `HeatLens.app`
  and `Applications -> /Applications`.
- `open dist/stage/HeatLens.app` — the same PID stayed running for 10 s (runtime flag confirmed on
  the running binary), then `osascript -e 'quit app "HeatLens"'` quit it cleanly.
- `shellcheck scripts/release.sh` — clean. A bad flag prints usage and exits 2.
- **Not checked:** clicking **Scan now** under the hardened runtime (Jarvis checks this after real
  signing); signing with the real Developer ID; `notarytool submit`/`log` and `stapler`
  (that code path has never run, so a first real run may show up a mistake in it); `spctl`
  acceptance of a notarized DMG.
- The Debug app still shows `adhoc` without `runtime` in `codesign -dvv`. That's how Xcode signs
  Debug here and it doesn't affect Release.
## Processes left running
none
## Questions for the user
none
## Notes for Jarvis
- Shared file edited: `project.yml` (two settings changed on the HeatLens target:
  `ENABLE_HARDENED_RUNTIME: YES`, `MARKETING_VERSION: "1.0.0"`). `App/Info.plist` untouched, since it
  already reads `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`.
- Yours to do: have the user run `xcrun notarytool store-credentials heatlens-notary --apple-id <id>
  --team-id 9PXJ82UU32`, then run `scripts/release.sh` (real identity + notarization), check with
  `spctl` / `stapler validate`, install from the DMG, click Scan now, then
  `gh release create v1.0.0 dist/HeatLens-1.0.0.dmg dist/HeatLens.dmg dist/SHA256SUMS`.
- If more than one "Developer ID Application" identity ever ends up in the keychain, pass the full
  name: `--identity "Developer ID Application: Gorakh Shetty (9PXJ82UU32)"`.
- `dist/` currently holds the ad-hoc artifacts (gitignored). The real run overwrites them.
- Suggested commit: `feat(release): Developer ID release pipeline with hardened runtime, DMG and notarization (v1.0.0)`
