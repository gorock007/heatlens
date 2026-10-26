#!/usr/bin/env bash
# Build HeatLens.app with xcodegen + xcodebuild, then launch it.
# Usage: scripts/run-app.sh [--build-only]
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

build_only=0
for arg in "$@"; do
  case "$arg" in
    --build-only) build_only=1 ;;
    *) echo "usage: $0 [--build-only]" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

XCODEGEN=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
"$XCODEGEN" generate --quiet

log=$(mktemp -t heatlens-xcodebuild)
trap 'rm -f "$log"' EXIT
if ! xcodebuild -project HeatLens.xcodeproj -scheme HeatLens -configuration Debug \
    -derivedDataPath .build/xcode build -quiet >"$log" 2>&1; then
  tail -40 "$log" >&2
  echo "xcodebuild failed" >&2
  exit 1
fi

app="$PWD/.build/xcode/Build/Products/Debug/HeatLens.app"
echo "$app"

if [[ $build_only -eq 0 ]]; then
  open "$app"
fi
