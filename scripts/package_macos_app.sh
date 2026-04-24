#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SteamXBridge"
BUNDLE_ID="com.stemnet.steamxbridge"
MIN_MACOS="14.0"
CONFIGURATION="release"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BUILD_BIN="${ROOT_DIR}/.build/${CONFIGURATION}/${APP_NAME}"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-macOS.zip"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packaging script must be run on macOS (Darwin)."
  exit 1
fi

pushd "${ROOT_DIR}" >/dev/null
swift build -c "${CONFIGURATION}"
popd >/dev/null

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
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "${APP_DIR}" || true
fi

rm -f "${ZIP_PATH}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "Built app bundle: ${APP_DIR}"
echo "Built installer archive: ${ZIP_PATH}"
