#!/bin/zsh
# Takes App Store screenshots on the iPhone 6.9" and iPad 13" simulators.
#
#   VAULT_TEST_SERVER=http://192.168.1.10:8000 VAULT_TEST_USER=me VAULT_TEST_PASSWORD=... \
#     VAULT_TEST_MODEL=12 scripts/screenshots.sh
#
# Signs in with a Debug build (the auto sign-in only exists in Debug). VAULT_TEST_MODEL picks
# the model shown on the detail screenshot. Output goes to dist/screenshots.
set -euo pipefail
: ${VAULT_TEST_SERVER:?} ${VAULT_TEST_USER:?} ${VAULT_TEST_PASSWORD:?} ${VAULT_TEST_MODEL:?}

root=${0:A:h:h}
out="$root/dist/screenshots"
mkdir -p "$out"
devices=("iPhone 17 Pro Max" "iPad Pro 13-inch (M5)")

cd "$root/ios"
xcodegen -q
xcodebuild build -project 3DVault-iOS.xcodeproj -scheme 3DVault -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath build > "$out/build.log" 2>&1 \
  || { tail -30 "$out/build.log" >&2; exit 1; }
app="$root/ios/build/Build/Products/Debug-iphonesimulator/3DVault.app"

shoot() {  # device, file name, model id or empty
  xcrun simctl terminate "$1" com.3dvault.ios 2>/dev/null || true
  SIMCTL_CHILD_VAULT_TEST_SERVER=$VAULT_TEST_SERVER SIMCTL_CHILD_VAULT_TEST_USER=$VAULT_TEST_USER \
    SIMCTL_CHILD_VAULT_TEST_PASSWORD=$VAULT_TEST_PASSWORD SIMCTL_CHILD_VAULT_TEST_MODEL=$3 \
    xcrun simctl launch "$1" com.3dvault.ios > /dev/null
  sleep ${WAIT:-10}
  xcrun simctl io "$1" screenshot "$out/$2.png" > /dev/null 2>&1
  echo "$out/$2.png"
}

for d in $devices; do
  name=${${d%% *}:l}
  xcrun simctl boot "$d" 2>/dev/null || true
  xcrun simctl bootstatus "$d" -b > /dev/null
  xcrun simctl status_bar "$d" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 --dataNetwork wifi
  xcrun simctl install "$d" "$app"
  for appearance in light dark; do
    xcrun simctl ui "$d" appearance $appearance
    shoot "$d" "$name-library-$appearance" ""
    shoot "$d" "$name-model-$appearance" "$VAULT_TEST_MODEL"
  done
  xcrun simctl status_bar "$d" clear
done
