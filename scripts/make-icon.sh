#!/usr/bin/env bash
# Regenerate the master and all macOS AppIcon slots. Requires librsvg and macOS sips.
set -euo pipefail
cd "$(dirname "$0")/.."

renderer=$(command -v rsvg-convert || true)
if [[ -z "$renderer" ]]; then
  echo "rsvg-convert is required (brew install librsvg)." >&2
  exit 1
fi

master=App/Icon/heatlens-icon-1024.png
catalog=App/Assets.xcassets/AppIcon.appiconset
mkdir -p "$catalog"
log=$(mktemp -t heatlens-icon)
trap 'rm -f "$log"' EXIT

quiet() {
  if ! "$@" >"$log" 2>&1; then
    tail -20 "$log" >&2
    return 1
  fi
}

quiet "$renderer" --width 1024 --height 1024 --output "$master" App/Icon/heatlens-icon.svg
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    suffix=""
    if [[ "$scale" -eq 2 ]]; then suffix="@2x"; fi
    output="$catalog/icon_${size}x${size}${suffix}.png"
    if [[ "$pixels" -eq 1024 ]]; then
      cp "$master" "$output"
    else
      quiet sips --resampleHeightWidth "$pixels" "$pixels" "$master" --out "$output"
    fi
  done
done
echo "Regenerated HeatLens master and 10 macOS app icon slots."
