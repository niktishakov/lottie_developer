#!/bin/bash
# Сборка распространяемого macOS-приложения: Release → Developer ID подпись → DMG.
# Нотаризация (submit/staple) — отдельный шаг, его запускаешь ТЫ со своими Apple ID креденшлами
# (см. вывод в конце): это outward-действие, требующее app-specific password.
#
# Требования: Developer ID Application сертификат в keychain (team LWV5ZRPC43).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="LottieDeveloperMac"
APP="LottieDeveloperMac"
TEAM="LWV5ZRPC43"
OUT="$ROOT/build/macos"
PKGS="$ROOT/.packages"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> [1/4] Archive (Release, Developer ID, hardened runtime)"
xcrun xcodebuild archive \
  -project "$ROOT/LottieDeveloper.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$OUT/$APP.xcarchive" \
  -derivedDataPath "$OUT/dd" \
  -clonedSourcePackagesDirPath "$PKGS" \
  -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

echo "==> [2/4] Export Developer ID app"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

xcrun xcodebuild -exportArchive \
  -archivePath "$OUT/$APP.xcarchive" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist"

echo "==> [3/4] Create DMG"
hdiutil create -volname "Lottie Developer" \
  -srcfolder "$OUT/export/$APP.app" \
  -ov -format UDZO \
  "$OUT/$APP.dmg"

echo "==> [4/4] Done. App + DMG at: $OUT"
echo ""
echo "NEXT — notarize (run with YOUR Apple ID + app-specific password):"
echo "  xcrun notarytool submit \"$OUT/$APP.dmg\" \\"
echo "    --apple-id <your-apple-id> --team-id $TEAM --password <app-specific-password> --wait"
echo "  xcrun stapler staple \"$OUT/$APP.dmg\""
echo ""
echo "(Сохранить креды один раз: xcrun notarytool store-credentials \"lottie-notary\" \\"
echo "   --apple-id <id> --team-id $TEAM --password <app-specific-pw>, затем --keychain-profile lottie-notary)"
