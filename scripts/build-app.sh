#!/usr/bin/env bash
# Builds AI Terminus as a distributable macOS .app bundle using Xcode's Release build.
#
# Usage:
#   ./scripts/build-app.sh              # native arch (auto-detect)
#   ./scripts/build-app.sh arm64        # Apple Silicon only
#   ./scripts/build-app.sh x86_64       # Intel only
#   ./scripts/build-app.sh universal    # universal build
#
# Output: dist/AI Terminus.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AI Terminus"
SCHEME_NAME="AITerminus"
EXE_NAME="AITerminus"
ARCH="${1:-native}"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
BUILD_ROOT="$PWD/.build"

echo "▶ Cleaning previous build..."
rm -rf "$APP"
mkdir -p "$BUILD_ROOT"

DERIVED_DATA="$(mktemp -d "$BUILD_ROOT/xcodebuild.XXXXXX")"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Release"
BIN="$PRODUCTS_DIR/$EXE_NAME"
trap 'rm -rf "$DERIVED_DATA"' EXIT

echo "▶ Building ($ARCH) with xcodebuild Release..."
case "$ARCH" in
  native)
    xcodebuild \
      -scheme "$SCHEME_NAME" \
      -configuration Release \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      build
    ;;
  arm64)
    xcodebuild \
      -scheme "$SCHEME_NAME" \
      -configuration Release \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      build
    ;;
  x86_64)
    xcodebuild \
      -scheme "$SCHEME_NAME" \
      -configuration Release \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
      build
    ;;
  universal)
    xcodebuild \
      -scheme "$SCHEME_NAME" \
      -configuration Release \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED_DATA" \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
      build
    ;;
  *)
    echo "Unknown arch: $ARCH (use native | universal | arm64 | x86_64)" >&2
    exit 1
    ;;
esac

if [[ ! -f "$BIN" ]]; then
  echo "✗ Build failed — executable not found at $BIN" >&2
  exit 1
fi

echo "▶ Assembling .app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$BIN" "$MACOS_DIR/$EXE_NAME"
chmod +x "$MACOS_DIR/$EXE_NAME"
cp Resources/Info.plist "$CONTENTS/Info.plist"

if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
fi

if [[ -d "$PRODUCTS_DIR/PackageFrameworks" ]]; then
  cp -R "$PRODUCTS_DIR/PackageFrameworks/." "$FRAMEWORKS_DIR/"
fi

find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.bundle' -exec cp -R {} "$RESOURCES_DIR/" \;

# Strip extended attributes (xcodebuild copies leave resource forks that
# codesign rejects with "resource fork, Finder information, or similar
# detritus not allowed"), then ad-hoc sign so Gatekeeper's translocation
# doesn't mangle relative paths.
echo "▶ Stripping extended attributes..."
xattr -cr "$APP"
echo "▶ Ad-hoc signing..."
codesign --force --deep --sign - "$APP"

echo ""
echo "✓ Built: $APP"
echo ""
echo "Run with:   open \"$APP\""
echo "Install to: cp -R \"$APP\" /Applications/"
