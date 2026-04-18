#!/usr/bin/env bash
# Builds AI Terminus as a distributable macOS .app bundle.
#
# Usage:
#   ./scripts/build-app.sh              # universal (arm64 + x86_64)
#   ./scripts/build-app.sh arm64        # Apple Silicon only
#   ./scripts/build-app.sh x86_64       # Intel only
#
# Output: dist/AI Terminus.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AI Terminus"
EXE_NAME="AITerminus"
BUNDLE_ID="com.joechou.AITerminus"
ARCH="${1:-universal}"

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "▶ Cleaning previous build..."
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "▶ Building ($ARCH) in release mode..."
case "$ARCH" in
  universal)
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXE_NAME"
    ;;
  arm64)
    swift build -c release --arch arm64
    BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXE_NAME"
    ;;
  x86_64)
    swift build -c release --arch x86_64
    BIN="$(swift build -c release --arch x86_64 --show-bin-path)/$EXE_NAME"
    ;;
  *)
    echo "Unknown arch: $ARCH (use universal | arm64 | x86_64)" >&2
    exit 1
    ;;
esac

if [[ ! -f "$BIN" ]]; then
  echo "✗ Build failed — binary not found at $BIN" >&2
  exit 1
fi

echo "▶ Assembling .app bundle..."
cp "$BIN" "$MACOS_DIR/$EXE_NAME"
chmod +x "$MACOS_DIR/$EXE_NAME"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# Ad-hoc code signing so Gatekeeper's translocation doesn't mangle relative paths.
echo "▶ Ad-hoc signing..."
codesign --force --deep --sign - "$APP"

echo ""
echo "✓ Built: $APP"
echo ""
echo "Run with:   open \"$APP\""
echo "Install to: cp -R \"$APP\" /Applications/"
