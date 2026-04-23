#!/usr/bin/env bash
# Creates a DMG installer with drag-to-Applications layout.
# Usage: ./scripts/create-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AI Terminus"
DMG_NAME="AI-Terminus-v1.0.0-macOS"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$DMG_NAME.dmg"
STAGING="$DIST/dmg-staging"

if [[ ! -d "$APP" ]]; then
  echo "✗ $APP not found. Run ./scripts/build-app.sh first." >&2
  exit 1
fi

echo "▶ Preparing DMG staging area..."
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"

# Copy app
cp -R "$APP" "$STAGING/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$STAGING/Applications"

# Remove quarantine attributes
xattr -cr "$STAGING/$APP_NAME.app" 2>/dev/null || true

echo "▶ Creating DMG..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

# Clean up staging
rm -rf "$STAGING"

echo ""
echo "✓ Created: $DMG"
echo ""
echo "Users: Open DMG → drag '$APP_NAME' to Applications folder"
