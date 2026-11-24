#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
APP_NAME="AI Cleaner"
EXECUTABLE_NAME="AICleanerApp"
BUNDLE_ID="com.qiyuanjuzheng.ai-cleaner"
VERSION="0.1.0"
BUILD_NUMBER="1"

if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
elif [[ "${1:-}" == "--release" || -z "${1:-}" ]]; then
  CONFIG="release"
else
  echo "用法: $0 [--release | --debug]" >&2
  exit 1
fi

echo "==> 正在构建 ${EXECUTABLE_NAME} (${CONFIG})..."
cd "${ROOT_DIR}"
swift build -c "${CONFIG}" --product "${EXECUTABLE_NAME}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${EXECUTABLE_NAME}"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "错误: 未找到构建产物 ${BIN_PATH}" >&2
  exit 1
fi

DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

# 生成高分辨率 macOS 应用图标 (AppIcon.icns)
ICON_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${ICON_TMP_DIR}"' EXIT
ICON_MASTER_PNG="${ICON_TMP_DIR}/AppIcon-1024.png"
ICONSET_DIR="${ICON_TMP_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

if [[ -f "${ROOT_DIR}/scripts/generate-icon.swift" ]] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  echo "==> 正在生成专属应用图标 AppIcon.icns..."
  swift "${ROOT_DIR}/scripts/generate-icon.swift" "${ICON_MASTER_PNG}"
  for sz in 16 32 128 256 512; do
    sips -z "${sz}" "${sz}" "${ICON_MASTER_PNG}" --out "${ICONSET_DIR}/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -z "${sz2}" "${sz2}" "${ICON_MASTER_PNG}" --out "${ICONSET_DIR}/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
  echo "==> 正在进行本地 ad-hoc 签名..."
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true
fi

echo "==> 打包完成: ${APP_DIR}"
echo "可直接双击打开，或运行: open \"${APP_DIR}\""
