#!/bin/bash
# Publishes an update: builds the app, zips it into dist/, and writes version.json.
# Bump app/VERSION first, run this, then commit and push. Running copies of the app
# find the new version through "Check for Updates…".
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION="$(cat VERSION)"
mkdir -p ../dist
rm -f ../dist/AsteraMidiBridge.zip
/usr/bin/ditto -c -k --keepParent "../build/Astera MIDI Bridge.app" ../dist/AsteraMidiBridge.zip
NOTES="${1:-}"
/usr/bin/python3 - "$VERSION" "$NOTES" <<'EOF'
import json, sys
json.dump({"version": sys.argv[1],
           "zip": "https://raw.githubusercontent.com/jonpikereally/AsteraMidiBridge/main/dist/AsteraMidiBridge.zip",
           "notes": sys.argv[2]}, open("../version.json", "w"), indent=2)
EOF
echo "Release $VERSION ready: dist/AsteraMidiBridge.zip + version.json. Commit and push to publish."
