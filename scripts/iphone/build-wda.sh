#!/bin/zsh
# Build + sign WebDriverAgent for your iPhone. Run it from a real Terminal window.
#
#   APPLE_TEAM_ID=ABCDE12345 WDA_BUNDLE_ID=com.yourname.WebDriverAgentRunner ./build-wda.sh
#
# Needs: Xcode installed and signed into your Apple ID (Xcode > Settings > Accounts),
# and the WebDriverAgent source next to it:  git clone https://github.com/appium/WebDriverAgent ~/Developer/WebDriverAgent
#
# Use YOUR OWN bundle id. Facebook's default id cannot be registered to your team.
# A free Apple ID signs it too (the app expires after 7 days, then re-run this).

set -u

TEAM="${APPLE_TEAM_ID:?set APPLE_TEAM_ID to your 10-character Apple team id}"
BUNDLE="${WDA_BUNDLE_ID:-com.example.WebDriverAgentRunner}"
SRC="${WDA_SRC:-$HOME/Developer/WebDriverAgent}"
DD="${WDA_DERIVED:-$HOME/Developer/wda-build}"
LOG="$DD.log"

echo "=== WDA build starting $(date) (team $TEAM, bundle $BUNDLE) ==="
rm -rf "$DD"
cd "$SRC" || { echo "WebDriverAgent source not found at $SRC"; exit 1; }

xcodebuild build-for-testing \
  -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "generic/platform=iOS" \
  -allowProvisioningUpdates \
  -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM="$TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" \
  CODE_SIGN_STYLE=Automatic \
  > "$LOG" 2>&1

RC=$?
echo "=== xcodebuild exit: $RC (log: $LOG) ==="

if [ $RC -ne 0 ]; then
  echo "--- errors ---"
  grep -iE "error:|Signing for|requires a provisioning" "$LOG" | head -20
fi

APP=$(find "$DD/Build/Products" -maxdepth 2 -name "WebDriverAgentRunner-Runner.app" 2>/dev/null | head -1)
echo "RUNNER_APP=$APP"
if [ -n "$APP" ]; then
  echo "--- signature ---"
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier"
  echo
  echo "Next: export WDA_BUNDLE_ID=$BUNDLE and run  python3 wda.py up"
fi
echo "=== WDA BUILD DONE rc=$RC ==="
