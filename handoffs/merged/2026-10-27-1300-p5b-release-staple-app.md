# Phase 5b: release.sh staples the app itself and gives the DMG a volume icon
status: done
agent: claude claude-opus-5-5
brief: handoffs/briefs/2026-10-27-1300-p5b-release-staple-app.md
## What the user asked
In v1.0.0 only the DMG was stapled, so the app inside it had no ticket. The release script should notarize and staple the app before building the DMG, and give the DMG a volume icon from `AppIcon.icns` when the app has one.
## What changed
- `scripts/release.sh`:
  - The DMG notarization block is now a function, `notarize <file>`, with the same logic: `notarytool submit --wait --output-format plist`, print id and status, and on failure print the output plus `notarytool log`, then exit. It is called twice.
  - New order:
    1. Sign the app.
    2. If notarizing: `ditto -c -k --keepParent` the app to `dist/stage/HeatLens.zip`, notarize the zip, delete it, then `stapler staple` and `stapler validate` the app.
    3. Build the DMG from the stapled app.
    4. Sign the DMG.
    5. Notarize and staple the DMG.
    6. Run spctl on the DMG (unchanged) and then `spctl -a -t exec -vv` on the staged app. With `--identity -` a rejection is only a warning, as it already was for the DMG.
  - Volume icon: if `dist/stage/HeatLens.app/Contents/Resources/AppIcon.icns` exists, the script copies it to `.VolumeIcon.icns`. If it's missing, the script prints a one-line note and builds the DMG as before.
  - **This departs from the brief, for a reason.** Running `SetFile -a C` on the source folder before `hdiutil create -srcfolder` does not work. I tested it: the mounted volume showed `.VolumeIcon.icns`, but `GetFileInfo -a` printed a lowercase `c`, meaning the custom-icon flag was dropped. So the icon branch builds a UDRW image, mounts it at `dist/stage/mnt`, runs `xcrun SetFile -a C` on the mounted volume, detaches, and converts to UDZO. If SetFile fails, it detaches before exiting. The no-icon branch is the original single `hdiutil create -format UDZO`.
  - Unchanged: `--skip-notarize`, `--identity -`, `--notary-profile`, and the outputs (`dist/HeatLens-<v>.dmg`, `dist/HeatLens.dmg`, `dist/SHA256SUMS`).
- `docs/RELEASING.md`: one added line about the two notary submissions and the volume icon.
## Files
- scripts/release.sh — modified
- docs/RELEASING.md — modified
- handoffs/2026-10-27-1300-p5b-release-staple-app.md — created
## Checks run
- `shellcheck scripts/release.sh`: clean.
- `scripts/with-timeout.sh 900 scripts/release.sh --identity - --skip-notarize`: exit 0. The app isn't in the repo yet, so this run took the no-icon branch ("note: no …AppIcon.icns"). Both spctl checks were rejected as expected for ad-hoc signing, with warnings only. The script wrote both DMGs and SHA256SUMS.
- Icon branch, in a scratch copy of the DMG block (`scratchpad/icontest/flow.sh`, same commands with scratch paths): I put Activity Monitor's `AppIcon.icns` into a copy of the staged app and ran the block. I then mounted the DMG read-only:
  - `ls -A` showed `.VolumeIcon.icns`, `Applications`, `HeatLens.app`.
  - `.VolumeIcon.icns` is byte-identical to the source icon (`cmp`).
  - `GetFileInfo -a` on the volume gave `avbstClinmedz`, an uppercase C, so the flag is set.
  - `hdiutil imageinfo` gave Format: UDZO.
  - I detached it and nothing is left mounted.
- **Not run: the real notarize path (two submissions, app staple and validate, DMG staple).** It needs the Developer ID and the notary profile, so Jarvis runs it. The real icon branch inside `release.sh` hasn't run either; it will run once the app icon from p5a lands.
- I didn't run `swift build`/`swift test` or `run-app.sh`. This change touches only the release script and doc, and the release dry run does a full Release xcodebuild.
## Processes left running
none
## Notes for Jarvis
- Real run: `scripts/release.sh`. Then check:
  - `xcrun stapler validate dist/stage/HeatLens.app` should say "The validate action worked!"
  - Mount the DMG and run `xcrun stapler validate /Volumes/HeatLens*/HeatLens.app`.
  - `spctl -a -t exec -vv dist/stage/HeatLens.app` should report source=Notarized Developer ID.
  - Expect two notary waits.
- You may want to add the app-validate line to the Verify section of RELEASING.md. I kept the doc change to the one line the brief allowed.
- Suggested commit: `feat(release): notarize and staple the app before the DMG; DMG volume icon from AppIcon.icns`
