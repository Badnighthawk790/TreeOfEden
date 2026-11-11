#!/usr/bin/env bash
# CI check: starts the packaged app the way a user does (through LaunchServices)
# and waits for its first-launch setup to install the built-in engine.
set -euo pipefail

APP="${1:-dist/SteamXBridge.app}"
SUPPORT="${HOME}/Library/Application Support/SteamXBridge"
SHOT="${RUNNER_TEMP:-/tmp}/steamxbridge-first-launch.png"

rm -rf "${SUPPORT}/Runtime"
open -n "${APP}"

installed=""
for _ in $(seq 1 120); do
  if ! pgrep -x SteamXBridge >/dev/null; then
    echo "::error::SteamXBridge exited during its first launch"
    exit 1
  fi
  if compgen -G "${SUPPORT}/Runtime/*/.installed.json" >/dev/null; then
    installed="yes"
    break
  fi
  sleep 2
done

screencapture -x "${SHOT}" 2>/dev/null || echo "No screenshot (screen capture is not available here)."
if [[ -z "${installed}" ]]; then
  echo "::error::The built-in engine was not installed within 4 minutes"
  pkill -x SteamXBridge || true
  exit 1
fi

echo "First launch installed: $(ls -d "${SUPPORT}"/Runtime/*/)"
du -sh "${SUPPORT}/Runtime" | sed 's/^/Runtime size: /'
sleep 3 # the window settles on its ready state
screencapture -x "${SHOT}" 2>/dev/null || true
pgrep -x SteamXBridge >/dev/null || { echo "::error::SteamXBridge crashed after setting up the engine"; exit 1; }
osascript -e 'tell application "SteamXBridge" to quit' 2>/dev/null || pkill -x SteamXBridge || true
