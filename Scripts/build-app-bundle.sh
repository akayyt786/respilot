#!/bin/sh
# Builds ResPilotApp in release mode and packages it into a proper
# ResPilot.app bundle: a real windowed app (Dock icon, Cmd+Tab) that also
# keeps a menu bar item for quick status/restore. SwiftPM doesn't produce
# a bundled .app by itself for a plain executableTarget, so this does the
# minimal, standard packaging by hand: no Xcode project required.
set -eu

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product ResPilotApp

BIN_DIR=".build/$CONFIG"
APP_DIR="$BIN_DIR/ResPilot.app"
CONTENTS="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/ResPilotApp" "$CONTENTS/MacOS/ResPilotApp"
cp "$(dirname "$0")/Info.plist" "$CONTENTS/Info.plist"
cp "$(dirname "$0")/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "Built $APP_DIR"
