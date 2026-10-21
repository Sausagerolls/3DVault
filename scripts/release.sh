#!/bin/zsh
# Archives the Mac or iOS app for the App Store.
#
#   scripts/release.sh ios            archive and export an .ipa to dist/ios
#   scripts/release.sh mac            archive and export a .pkg to dist/mac
#   scripts/release.sh ios --upload   archive and upload straight to App Store Connect
#
# Uploading needs the app record to exist in App Store Connect. Signing and uploading use the
# Apple ID in Xcode > Settings > Accounts, or an App Store Connect API key when ASC_KEY_PATH,
# ASC_KEY_ID and ASC_ISSUER are set. The build number is a timestamp, so every run is unique.
set -euo pipefail

platform=${1:?usage: release.sh ios|mac [--upload]}
upload=${2:-}
root=${0:A:h:h}
team=$(awk '/DEVELOPMENT_TEAM:/ {print $2; exit}' "$root/$platform/project.yml")
build=$(date -u +%Y%m%d%H%M)

case $platform in
  ios) project=3DVault-iOS.xcodeproj; destination="generic/platform=iOS" ;;
  mac) project=3DVault.xcodeproj; destination="generic/platform=macOS" ;;
  *) echo "unknown platform: $platform" >&2; exit 1 ;;
esac

auth=()
if [[ -n ${ASC_KEY_PATH:-} ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")
fi

out="$root/dist/$platform"
archive="$out/3DVault.xcarchive"
rm -rf "$out"
mkdir -p "$out"

cd "$root/$platform"
xcodegen -q

xcodebuild archive \
  -project "$project" -scheme 3DVault -configuration Release \
  -destination "$destination" -archivePath "$archive" \
  -allowProvisioningUpdates $auth \
  CURRENT_PROJECT_VERSION="$build" > "$out/archive.log" 2>&1 \
  || { tail -30 "$out/archive.log" >&2; echo "archive failed, full log: $out/archive.log" >&2; exit 1; }

opts="$out/ExportOptions.plist"
cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$([[ $upload == --upload ]] && echo upload || echo export)</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
  -exportOptionsPlist "$opts" -allowProvisioningUpdates $auth

version=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$archive/Info.plist")
echo "3DVault $platform $version ($build) -> $out"
