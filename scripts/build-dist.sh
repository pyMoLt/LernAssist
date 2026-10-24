#!/bin/zsh
# Builds an ad-hoc signed Release Lernassist.app (arm64, hardened runtime, no App Sandbox),
# updates /Applications/Lernassist.app (unless --no-install is passed), and packages
# ../releases/LernAssist-4.0.0-macos-arm64.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
RELEASES_DIR="$(cd "$ROOT/.." && pwd)/releases"
DERIVED="/private/tmp/LernAssist-Release-DD"
VERSION="4.0.0"
ZIP_NAME="LernAssist-${VERSION}-macos-arm64.zip"

echo "Building Lernassist.app (Release, arm64, ad-hoc signed)..."
xcodebuild -project "$ROOT/Lernassist.xcodeproj" \
  -scheme Lernassist \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_STYLE=Manual \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

APP="$DERIVED/Build/Products/Release/Lernassist.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }

codesign --verify --deep --strict "$APP"

mkdir -p "$RELEASES_DIR"
rm -rf "$RELEASES_DIR/Lernassist.app" "$RELEASES_DIR/$ZIP_NAME"
cp -R "$APP" "$RELEASES_DIR/Lernassist.app"
ditto -c -k --sequesterRsrc --keepParent "$RELEASES_DIR/Lernassist.app" "$RELEASES_DIR/$ZIP_NAME"
echo "Packaged: $RELEASES_DIR/$ZIP_NAME ($(du -sh "$RELEASES_DIR/$ZIP_NAME" | cut -f1))"

if [[ "${1:-}" != "--no-install" ]]; then
  TARGET="/Applications/Lernassist.app"
  STAGED="/Applications/.Lernassist.app.new"
  rm -rf "$STAGED"
  cp -R "$RELEASES_DIR/Lernassist.app" "$STAGED"
  codesign --verify --deep --strict "$STAGED"
  osascript -e 'tell application "Lernassist" to quit' >/dev/null 2>&1 || true
  for _ in {1..10}; do pgrep -f "$TARGET/Contents/MacOS/" >/dev/null || break; sleep 1; done
  if [[ -d "$TARGET" ]]; then
    rm -rf "$TARGET.old"
    mv "$TARGET" "$TARGET.old"
  fi
  if mv "$STAGED" "$TARGET"; then
    rm -rf "$TARGET.old"
    echo "Updated $TARGET"
  else
    [[ -d "$TARGET.old" ]] && mv "$TARGET.old" "$TARGET"
    echo "Failed to update $TARGET; restored previous version." >&2
    exit 1
  fi
fi
