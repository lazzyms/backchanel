#!/bin/zsh
# Builds Foresight with xcodebuild (needed so MLX Metal shaders compile) and
# assembles build/Foresight.app. Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
DERIVED="build/DerivedData"
APP="build/Foresight.app"

# FORESIGHT_NO_MLX=1 skips EmbeddingGemma 2 (no Metal Toolchain needed); see Package.swift.
xcodebuild -scheme Foresight -configuration "${(C)CONFIG}" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO build | grep -E "error:|warning: unre|BUILD" || true

PRODUCTS="$DERIVED/Build/Products/${(C)CONFIG}"
[[ -x "$PRODUCTS/Foresight" ]] || { echo "build failed: no executable in $PRODUCTS"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Foresight" "$APP/Contents/MacOS/Foresight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (e.g. MLX metallib) are looked up next to the executable or in Resources.
for b in "$PRODUCTS"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
# App icon: an Icon Composer bundle compiled by actool into AppIcon.icns + Assets.car.
if [[ -d Resources/AppIcon.icon ]]; then
  actool --app-icon AppIcon --include-all-app-icons --platform macosx --minimum-deployment-target 27.0 \
    --output-partial-info-plist "$DERIVED/icon.plist" --compile "$APP/Contents/Resources" \
    Resources/AppIcon.icon >/dev/null
fi
codesign --force --sign - --entitlements Resources/Foresight.entitlements --identifier dev.maulik.foresight "$APP"
echo "built $APP"
