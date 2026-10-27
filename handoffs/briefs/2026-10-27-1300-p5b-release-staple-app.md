# Phase 5b: release.sh staples the app itself and gives the DMG a volume icon
worker: claude
model: claude-opus-5-5
effort: medium
started: 2026-10-27 12:13 · terminal: 4f87ee45-cfba-4f02-ab9f-d7484c6fd537

## Goal
In v1.0.0, only the DMG was stapled: `stapler validate` on the app inside it says "does not have a ticket stapled", so the first launch needs Gatekeeper's online lookup. Change `scripts/release.sh` to:
- notarize and staple the **app** before building the DMG
- give the DMG a volume icon taken from the app's `AppIcon.icns`, when that file exists (another worker is adding the icon now)

Done means the script still passes its ad-hoc dry run, and the new notarization path is written exactly the way the existing DMG path is.

## Context
- Previous phase: `handoffs/merged/2026-10-27-1145-p4a-release-pipeline.md`. The script is `scripts/release.sh` and its doc is `docs/RELEASING.md`.
- **Pattern to copy:** the script's existing DMG notarization block (`notarytool submit --wait --output-format plist`; on failure, print the output and `notarytool log`; then staple). Factor it into a function `notarize <file>` and call it twice.
- New order:
  1. sign the app
  2. if notarizing: `ditto -c -k --keepParent dist/stage/HeatLens.app dist/stage/HeatLens.zip`, then `notarize` the zip, `xcrun stapler staple dist/stage/HeatLens.app`, and `stapler validate` it
  3. build the DMG from the stapled app
  4. sign the DMG
  5. `notarize` the DMG, then staple it
  6. run the spctl assessment of the DMG, and also `spctl -a -t exec -vv` of the staged app
- **Volume icon:** if `dist/stage/HeatLens.app/Contents/Resources/AppIcon.icns` exists, copy it to `$dmgroot/.VolumeIcon.icns`, then run `SetFile -a C "$dmgroot"` before `hdiutil create`. `SetFile` comes from Xcode, via `xcrun SetFile`. If the icon is missing, skip this with a one-line note; don't fail.
- Keep these unchanged: `--skip-notarize`, `--identity -` and the output names (`dist/HeatLens-<v>.dmg`, `dist/HeatLens.dmg`, `SHA256SUMS`).

## Scope
- May touch: `scripts/release.sh`, `docs/RELEASING.md` (a single line about the two submissions and the volume icon)
- Must not touch: `project.yml`, `App/`, `Sources/`, `Tests/`, `site/`, `README.md`, `CLAUDE.md`, `AGENTS.md`
- Never: sign with the real Developer ID, run notarytool, create a release, or push. Those are Jarvis's.

## Checks
- `scripts/with-timeout.sh 900 scripts/release.sh --identity - --skip-notarize 2>&1 | tail -30` passes.
- `shellcheck scripts/release.sh` is clean.
- To exercise the volume icon branch before the icon lands, temporarily copy any `.icns` (for example `/System/Applications/Utilities/Activity Monitor.app/Contents/Resources/AppIcon.icns`) into the staged app **inside a copy of the script's flow in your scratch folder**, not the repo. Mount the DMG and check that `.VolumeIcon.icns` is present and `GetFileInfo -a` on the volume shows `C`. Say what you ran.
- In the handoff, say plainly that the real notarize path (two submissions) has not been run. Jarvis runs it.

## Questions first
Put every question in one first handoff (`status: blocked`) and stop. After the answers arrive on your terminal, finish this phase without stopping again. If you have no questions, build straight through.
