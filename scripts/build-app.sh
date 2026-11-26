#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="T3Bar"
BUNDLE_PATH="/Applications/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "==> Building ${APP_NAME} (release)..."
cd "${ROOT_DIR}"
swift build -c release

BIN_PATH="${ROOT_DIR}/.build/release/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Error: compiled binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Stopping running ${APP_NAME} (if any)..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5

echo "==> Packaging ${BUNDLE_PATH}..."
rm -rf "${BUNDLE_PATH}"
mkdir -p "${MACOS_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>T3Bar</string>
  <key>CFBundleExecutable</key>
  <string>T3Bar</string>
  <key>CFBundleIdentifier</key>
  <string>com.juliusrook.t3bar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>T3Bar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.5.0</string>
  <key>CFBundleVersion</key>
  <string>6</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing ${BUNDLE_PATH}..."
codesign --force --deep --sign - "${BUNDLE_PATH}" >/dev/null 2>&1 || true

echo "==> Done! Installed ${BUNDLE_PATH}"
echo "    Launch with: open \"${BUNDLE_PATH}\""
