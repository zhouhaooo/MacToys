#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/MacToys.app"
DESTINATION="/Applications/MacToys.app"
codesign --verify --deep --strict "$APP"
STAGING="$(mktemp -d /Applications/.MacToys-install.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/MacToys.app"
codesign --verify --deep --strict "$STAGING/MacToys.app"
WAS_RUNNING=false
if pgrep -x MacToys >/dev/null; then
    WAS_RUNNING=true
    osascript -e 'tell application id "app.mactoys.MacToys" to quit'
    for attempt in {1..50}; do
        if ! pgrep -x MacToys >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x MacToys >/dev/null; then
        echo "MacToys is still running; installation cancelled." >&2
        exit 1
    fi
fi
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGING/Previous.app"; fi
if ! mv "$STAGING/MacToys.app" "$DESTINATION"; then
    if [[ -e "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" "$DESTINATION"; fi
    exit 1
fi
if [[ "$WAS_RUNNING" == true ]]; then open "$DESTINATION"; fi
echo "Installed $DESTINATION"
