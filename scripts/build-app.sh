#!/usr/bin/env bash
# Builds build/AWSContext.app (universal binary, ad-hoc signed unless CODESIGN_IDENTITY is set).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
APP="build/AWSContext.app"
ARCHS=(--arch arm64 --arch x86_64)
[[ "${UNIVERSAL:-1}" == "0" ]] && ARCHS=()

swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AWSContext" "$APP/Contents/MacOS/AWSContext"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp=none --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"
