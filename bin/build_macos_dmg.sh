#!/bin/bash
# DMG для дизайнера: Lottie Developer.app (внутри — MCP-сервер lottie-mcp) + ярлык Applications + инструкция.
# Universal (arm64 + x86_64), Release.
# Подпись: Developer ID Application, если он есть в keychain (тогда в конце — команды нотаризации),
# иначе ad-hoc — дизайнеру один раз нужно разрешить запуск в «Конфиденциальность и безопасность».
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/macos"
NAME="Lottie Developer"
TEAM="LWV5ZRPC43"
VERSION="$(grep -m1 'MARKETING_VERSION' "$ROOT/project.yml" | sed 's/.*: *//')"

IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
if [[ -n "$IDENTITY" ]]; then SIGN="$IDENTITY"; MODE="developer-id"; TS="--timestamp"; else SIGN="-"; MODE="ad-hoc"; TS=""; fi
echo "==> Signing: $MODE ${IDENTITY:+($IDENTITY)}"

rm -rf "$OUT"; mkdir -p "$OUT"
command -v xcodegen >/dev/null && (cd "$ROOT" && xcodegen generate >/dev/null)

echo "==> [1/4] Build Release (universal)"
xcodebuild -project "$ROOT/LottieDeveloper.xcodeproj" -scheme LottieDeveloperMac -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$OUT/dd" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="$TS" \
  build -quiet

SRC="$OUT/dd/Build/Products/Release/LottieDeveloperMac.app"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$SRC" "$STAGE/$NAME.app"

echo "==> [2/4] Verify"
lipo -archs "$STAGE/$NAME.app/Contents/MacOS/lottie-mcp"
codesign --verify --deep --strict "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/DESIGNER_SETUP.md" "$STAGE/Как начать.md"

echo "==> [3/4] DMG"
DMG="$OUT/LottieDeveloper-$VERSION.dmg"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
[[ "$MODE" == "developer-id" ]] && codesign --sign "$SIGN" --timestamp "$DMG"

echo "==> [4/4] Done: $DMG ($(du -h "$DMG" | cut -f1))"
if [[ "$MODE" == "developer-id" ]]; then
  echo "Notarize (your Apple ID + app-specific password):"
  echo "  xcrun notarytool submit \"$DMG\" --apple-id <id> --team-id $TEAM --password <app-specific-pw> --wait"
  echo "  xcrun stapler staple \"$DMG\""
else
  echo "Ad-hoc signed: the designer allows it once in System Settings → Privacy & Security → Open Anyway."
fi
