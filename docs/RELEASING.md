# Releasing HeatLens

HeatLens ships outside the App Store as a Developer ID–signed, notarized DMG on
[GitHub Releases](https://github.com/gorock007/heatlens/releases). The version comes from
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`; bump them before a release.

## One-time setup

Store notary credentials in the keychain as the `heatlens-notary` profile (use an
app-specific password from appleid.apple.com when prompted):

```
xcrun notarytool store-credentials heatlens-notary --apple-id <apple-id> --team-id 9PXJ82UU32
```

The `Developer ID Application: Gorakh Shetty (9PXJ82UU32)` certificate must be in the login
keychain (`security find-identity -v -p codesigning`).

## Cut a release

```
scripts/release.sh
```

This builds Release, signs the app with the hardened runtime, builds and signs
`dist/HeatLens-<version>.dmg`, notarizes and staples it, runs a Gatekeeper check, and writes
`dist/HeatLens.dmg` (the stable name the site links to) and `dist/SHA256SUMS`.

Options: `--identity <name|->` (default `Developer ID Application`; `-` signs ad-hoc),
`--skip-notarize`, `--notary-profile <name>` (default `heatlens-notary`). A dry run with no
Apple credentials: `scripts/release.sh --identity - --skip-notarize`.

## Verify

```
spctl -a -t open --context context:primary-signature -vv dist/HeatLens.dmg   # accepted, source=Notarized Developer ID
xcrun stapler validate dist/HeatLens.dmg                                     # The validate action worked!
codesign -dvv dist/stage/HeatLens.app 2>&1 | grep -E "Authority|flags"       # Developer ID, runtime
```

Then mount the DMG, drag HeatLens to Applications, launch it, and click **Scan now**.

## Publish

```
gh release create v<version> dist/HeatLens-<version>.dmg dist/HeatLens.dmg dist/SHA256SUMS
```
