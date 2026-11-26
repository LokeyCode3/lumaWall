#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/LokeyCode3/lumaWall.git"
APP_NAME="LumaWall.app"
INSTALL_DIR="/Applications"

echo "✨ Installing LumaWall..."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "❌ LumaWall is for macOS only."
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "❌ Swift compiler (swiftc) not found."
  echo "   Please install Xcode Command Line Tools first:"
  echo "   xcode-select --install"
  exit 1
fi

WORK_DIR="$(pwd)"
TEMP_DIR=""

if [[ ! -f "${WORK_DIR}/build.sh" ]] || [[ ! -d "${WORK_DIR}/Sources" ]]; then
  TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TEMP_DIR}"' EXIT
  echo "📦 Cloning LumaWall from GitHub..."
  git clone --depth 1 "${REPO_URL}" "${TEMP_DIR}/lumaWall"
  WORK_DIR="${TEMP_DIR}/lumaWall"
fi

cd "${WORK_DIR}"
chmod +x build.sh
echo "🔨 Building and installing ${APP_NAME} and LumaWallSaver.saver..."
pkill -x LumaWall 2>/dev/null || true
./build.sh

echo "🚀 Launching LumaWall..."
open "${INSTALL_DIR}/${APP_NAME}"

echo "✅ LumaWall is installed at ${INSTALL_DIR}/${APP_NAME}!"
