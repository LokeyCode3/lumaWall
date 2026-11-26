#!/bin/bash
set -euo pipefail

APP_NAME="LumaWall"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

SAVER_NAME="LumaWallSaver"
SAVER_BUNDLE="${RESOURCES_DIR}/${SAVER_NAME}.saver"
SAVER_MACOS="${SAVER_BUNDLE}/Contents/MacOS"
SAVER_RESOURCES="${SAVER_BUNDLE}/Contents/Resources"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
mkdir -p "${SAVER_MACOS}" "${SAVER_RESOURCES}"

cp Info.plist "${CONTENTS_DIR}/Info.plist"
cp Assets/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
cp Assets/logo.png "${RESOURCES_DIR}/logo.png"
cp ScreenSaver/Info.plist "${SAVER_BUNDLE}/Contents/Info.plist"

# Build Screen Saver bundle
swiftc \
  -O \
  -emit-library \
  -Xlinker -bundle \
  -framework ScreenSaver \
  -framework AppKit \
  -framework AVFoundation \
  ScreenSaver/LumaWallSaverView.swift \
  -o "${SAVER_MACOS}/${SAVER_NAME}"

# Build Main App
swiftc \
  -O \
  -parse-as-library \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework AVKit \
  -framework UniformTypeIdentifiers \
  Sources/WallpaperEngine.swift \
  Sources/ContentView.swift \
  Sources/LumaWallApp.swift \
  -o "${MACOS_DIR}/${APP_NAME}"

codesign --force --deep --sign - "${SAVER_BUNDLE}" 2>/dev/null || true
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true

echo "Built ${APP_BUNDLE} and ${SAVER_NAME}.saver successfully!"
