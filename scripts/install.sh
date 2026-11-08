#!/usr/bin/env bash
# Rebuilds and reinstalls the iPad app. Run before each game: free-account installs last 7 days.
# The iPad must be unlocked, paired with this Mac, and connected or on the same network.
# Pass --with-tv to also install the fallback Apple TV app.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet

devices_json=$(mktemp)
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --quiet --json-output "$devices_json" >/dev/null

find_udid() {
  python3 -I - "$devices_json" "$1" <<'PY'
import json, sys
wanted = sys.argv[2].lower()
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    hardware = device["hardwareProperties"]
    if hardware.get("reality") == "physical" and hardware.get("deviceType", "").lower() == wanted:
        print(hardware["udid"])
        break
PY
}

install() { # scheme, device type, products folder
  local scheme=$1 device_type=$2 products=$3 udid
  udid=$(find_udid "$device_type")
  if [ -z "$udid" ]; then
    echo "SKIP $scheme: no paired $device_type found. Pair it in Xcode > Window > Devices and Simulators." >&2
    return 1
  fi
  echo "== $scheme -> $udid"
  xcodebuild -quiet -project MirageArcane.xcodeproj -scheme "$scheme" -configuration Debug \
    -destination "id=$udid" -derivedDataPath build -allowProvisioningUpdates build
  xcrun devicectl device install app --device "$udid" "build/Build/Products/$products/$scheme.app"
}

install MirageIPad iPad Debug-iphoneos
# The Apple TV app is a fallback. The normal projector path is AirPlay from the iPad.
if [ "${1:-}" = "--with-tv" ]; then
  install MirageTV appleTV Debug-appletvos
fi
