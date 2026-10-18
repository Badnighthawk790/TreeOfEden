#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SteamXBridge"
BUNDLE_ID="com.stemnet.steamxbridge"
MIN_MACOS="14.0"
CONFIGURATION="release"
# Overridable by the release workflow (e.g. from a git tag). Defaults keep local
# packaging working with no arguments.
APP_VERSION="${APP_VERSION:-2.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# Both end up in Info.plist; refuse anything that is not a plain version.
if [[ ! "${APP_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "APP_VERSION must look like 2.0.0 (got '${APP_VERSION}')." >&2
  exit 1
fi
if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be a whole number (got '${BUILD_NUMBER}')." >&2
  exit 1
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-macOS.zip"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packaging script must be run on macOS (Darwin)."
  exit 1
fi

pushd "${ROOT_DIR}" >/dev/null
swift build -c "${CONFIGURATION}"
# Resolve the binary path canonically (handles arch-specific build dirs).
BIN_PATH="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
popd >/dev/null

BUILD_BIN="${BIN_PATH}/${APP_NAME}"
if [[ ! -f "${BUILD_BIN}" ]]; then
  echo "Could not find built binary at ${BUILD_BIN}" >&2
  exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BUILD_BIN}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleDisplayName</key>
  <string>Steam X Bridge</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.games</string>
  <key>NSHumanReadableCopyright</key>
  <string>SteamXBridge drives Wine engines you install separately; it bundles none.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Windows games and programs you run in a bottle can use the microphone, for example for Steam or in-game voice chat.</string>
  <key>NSCameraUsageDescription</key>
  <string>Windows programs you run in a bottle can use the camera.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for arm64 code to run at all. It is not a
# Developer ID signature, so a downloaded copy still needs Gatekeeper's
# "Open Anyway" step (see README). Signing failures are fatal.
codesign --force --sign - --timestamp=none "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"
# Wine children are attributed to this app for privacy checks; without these
# strings macOS kills a game the moment it opens the microphone.
plutil -extract NSMicrophoneUsageDescription raw "${CONTENTS_DIR}/Info.plist" >/dev/null

rm -f "${ZIP_PATH}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "Built app bundle: ${APP_DIR}"
echo "Built installer archive: ${ZIP_PATH}"
