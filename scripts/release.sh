#!/usr/bin/env bash
# Build a signed, notarized, stapled dist/HeatLens-<version>.dmg.
# Usage: scripts/release.sh [--identity <name|->] [--skip-notarize] [--notary-profile <name>]
#   --identity        codesign identity (default "Developer ID Application"; "-" signs ad-hoc)
#   --skip-notarize   skip notarytool submit and stapling
#   --notary-profile  notarytool keychain profile (default heatlens-notary)
# See docs/RELEASING.md.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

identity="Developer ID Application"
notarize=1
profile="heatlens-notary"

usage() {
  echo "usage: $0 [--identity <name|->] [--skip-notarize] [--notary-profile <name>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) [[ $# -ge 2 ]] || usage; identity=$2; shift 2 ;;
    --skip-notarize) notarize=0; shift ;;
    --notary-profile) [[ $# -ge 2 ]] || usage; profile=$2; shift 2 ;;
    *) usage ;;
  esac
done

cd "$(dirname "$0")/.."

step() { echo "==> $*"; }

sign_args=(--force --options runtime --sign "$identity")
if [[ "$identity" != "-" ]]; then
  sign_args+=(--timestamp)
fi

step "Generating project"
XCODEGEN=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
"$XCODEGEN" generate --quiet

step "Building Release"
log=$(mktemp -t heatlens-release)
trap 'rm -f "$log"' EXIT
if ! xcodebuild -project HeatLens.xcodeproj -scheme HeatLens -configuration Release \
    -derivedDataPath .build/xcode build -quiet >"$log" 2>&1; then
  tail -40 "$log" >&2
  echo "xcodebuild failed" >&2
  exit 1
fi

built="$PWD/.build/xcode/Build/Products/Release/HeatLens.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$built/Contents/Info.plist")
echo "HeatLens $version ($build)"

step "Staging app"
rm -rf dist/stage
mkdir -p dist/stage
ditto "$built" dist/stage/HeatLens.app
app="dist/stage/HeatLens.app"

step "Signing app with \"$identity\""
# Nested code first, deepest paths first; no --deep.
nested=()
while IFS= read -r path; do
  nested+=("$path")
done < <(find "$app/Contents" -mindepth 2 \( -name '*.framework' -o -name '*.dylib' \
    -o -name '*.bundle' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -print \
  | awk '{ print gsub("/", "/") "\t" $0 }' | sort -rn | cut -f2-)
for path in ${nested[@]+"${nested[@]}"}; do
  codesign "${sign_args[@]}" "$path"
done
codesign "${sign_args[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"

dmg="dist/HeatLens-$version.dmg"
step "Building $dmg"
dmgroot="dist/stage/dmg"
mkdir -p "$dmgroot"
ditto "$app" "$dmgroot/HeatLens.app"
ln -s /Applications "$dmgroot/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "HeatLens $version" -srcfolder "$dmgroot" -ov -format UDZO "$dmg"
rm -rf "$dmgroot"

step "Signing DMG"
dmg_sign_args=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  dmg_sign_args+=(--timestamp)
fi
codesign "${dmg_sign_args[@]}" "$dmg"
codesign --verify --verbose=2 "$dmg"

if [[ $notarize -eq 1 ]]; then
  step "Notarizing (profile $profile)"
  submit_out=$(mktemp -t heatlens-notary)
  trap 'rm -f "$log" "$submit_out"' EXIT
  rc=0
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait \
    --output-format plist >"$submit_out" || rc=$?
  submission=$(/usr/libexec/PlistBuddy -c "Print :id" "$submit_out" 2>/dev/null || true)
  status=$(/usr/libexec/PlistBuddy -c "Print :status" "$submit_out" 2>/dev/null || true)
  echo "submission ${submission:-?}: ${status:-?}"
  if [[ $rc -ne 0 || "$status" != "Accepted" ]]; then
    cat "$submit_out" >&2
    if [[ -n "$submission" ]]; then
      xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
    fi
    echo "notarization failed" >&2
    exit 1
  fi
  step "Stapling"
  xcrun stapler staple "$dmg"
else
  step "Skipping notarization"
fi

step "Gatekeeper assessment"
if ! spctl -a -t open --context context:primary-signature -vv "$dmg"; then
  if [[ "$identity" == "-" ]]; then
    echo "warning: spctl rejected the ad-hoc signed DMG (expected)" >&2
  else
    echo "spctl rejected $dmg" >&2
    exit 1
  fi
fi

cp "$dmg" dist/HeatLens.dmg
(cd dist && shasum -a 256 "HeatLens-$version.dmg" HeatLens.dmg >SHA256SUMS)

step "Done"
echo "$PWD/$dmg"
echo "$PWD/dist/HeatLens.dmg"
cat dist/SHA256SUMS
