#!/usr/bin/env bash
# Downloads the iOS Firebase config and writes the Google sign-in URL scheme.
# Both outputs are gitignored. Run once after the Firebase project exists.
set -euo pipefail
cd "$(dirname "$0")/.."

firebase() { pnpm dlx firebase-tools@latest "$@"; }

apps_json=$(mktemp)
trap 'rm -f "$apps_json"' EXIT
firebase apps:list IOS --json > "$apps_json"
app_id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"][0]["appId"])' "$apps_json")

rm -f iPad/GoogleService-Info.plist
firebase apps:sdkconfig IOS "$app_id" --out iPad/GoogleService-Info.plist

if ! reversed=$(/usr/libexec/PlistBuddy -c 'Print :REVERSED_CLIENT_ID' iPad/GoogleService-Info.plist 2>/dev/null); then
  echo "No REVERSED_CLIENT_ID. Enable Google sign-in in the Firebase console, then run this again." >&2
  exit 1
fi
printf 'REVERSED_CLIENT_ID = %s\n' "$reversed" > iPad/Firebase.local.xcconfig
xcodegen generate --quiet
echo "Firebase config written."
