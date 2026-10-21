#!/bin/sh
# Build a signed, notarised 3DVault.dmg.
# One-time setup:
#   1. Set DEVELOPMENT_TEAM in project.yml (or export TEAM_ID) and run `xcodegen generate`.
#   2. Store notary credentials:
#      xcrun notarytool store-credentials 3dvault-notary --apple-id you@example.com --team-id TEAMID
set -eu
cd "$(dirname "$0")/.."
TEAM_ID="${TEAM_ID:?export TEAM_ID=<your Apple team ID>}"
PROFILE="${NOTARY_PROFILE:-3dvault-notary}"
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

xcodegen generate
xcodebuild -project 3DVault.xcodeproj -scheme 3DVault -configuration Release \
  -archivePath "$OUT/3DVault.xcarchive" DEVELOPMENT_TEAM="$TEAM_ID" archive

cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/3DVault.xcarchive" -exportPath "$OUT" -exportOptionsPlist "$OUT/export.plist"

hdiutil create -volname 3DVault -srcfolder "$OUT/3DVault.app" -ov -format UDZO "$OUT/3DVault.dmg"
xcrun notarytool submit "$OUT/3DVault.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/3DVault.dmg"
echo "Done: $OUT/3DVault.dmg"
