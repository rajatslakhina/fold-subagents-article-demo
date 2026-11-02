#!/usr/bin/env bash
# Builds Demo.xcodeproj for the iOS Simulator, installs and launches the app,
# and saves real screenshots of the running app to Demo/Screenshots/.
set -euo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

BUNDLE_ID="com.rajatlakhina.AgentBoundaryDemo"
OUT="Demo/Screenshots"
mkdir -p "$OUT"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, items in sorted(devices.items(), reverse=True):
    if "iOS" not in runtime:
        continue
    for d in items:
        if d["name"].startswith("iPhone") and "Pro" in d["name"] and "Max" not in d["name"]:
            print(d["udid"]); sys.exit(0)
sys.exit(1)')
echo "Using simulator $UDID"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b

xcodebuild -project Demo.xcodeproj -scheme Demo -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

APP="build/Build/Products/Debug-iphonesimulator/Demo.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true

shoot () {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@"
  sleep 8
  # Fails the job if the app crashed after launch. Written to a file first:
  # piping into `grep -q` under pipefail can fail with SIGPIPE (exit 141).
  xcrun simctl spawn "$UDID" launchctl list > "$RUNNER_TEMP/processes.txt"
  grep -q "$BUNDLE_ID" "$RUNNER_TEMP/processes.txt"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
}

shoot boundaries -tab boundaries
shoot boundaries-200k -tab boundaries -budget 200
shoot plan -tab plan
shoot gate -tab gate
ls -la "$OUT"
