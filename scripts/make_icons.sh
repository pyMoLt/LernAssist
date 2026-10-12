#!/bin/zsh
# Rendert design/icon/preview_flat.svg in alle AppIcon.appiconset-Größen.
# Die Einzel-Ebenen (1_background, 2_viewfinder, 3_glass_cap) sind für Icon Composer gedacht.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RSVG="$(command -v rsvg-convert || echo /Volumes/Arbeitsmedium1TB/Apps/FSL/bin/rsvg-convert)"
SRC="$ROOT/design/icon/preview_flat.svg"
OUT="$ROOT/Lernassist/Lernassist/Assets.xcassets/AppIcon.appiconset"
find "$OUT" -maxdepth 1 \( -name "*.png" -o -name "*.jpeg" -o -name "*.jpg" \) -delete
cd "$ROOT/design/icon"
images=""
for s in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((s * scale)); name="icon_${s}x${s}@${scale}x.png"
    "$RSVG" -w $px -h $px "$SRC" -o "$OUT/$name"
    images="$images{\"idiom\":\"mac\",\"size\":\"${s}x${s}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
  done
done
echo "{\"images\":[${images%,}],\"info\":{\"version\":1,\"author\":\"make_icons.sh\"}}" > "$OUT/Contents.json"
echo "Icons erzeugt: $OUT"
