#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
APP_NAME="AI Cleaner"
EXECUTABLE_NAME="AICleanerApp"
BUNDLE_ID="com.qiyuanjuzheng.ai-cleaner"
DEFAULT_VERSION="0.1.0"
if [[ -f "${ROOT_DIR}/CHANGELOG.md" ]]; then
  CHANGELOG_VERSION="$(awk '/^## \[v?[0-9]+\.[0-9]+\.[0-9]+\]/ {gsub(/[][]/, "", $2); sub(/^v/, "", $2); print $2; exit}' "${ROOT_DIR}/CHANGELOG.md")"
  if [[ -n "$CHANGELOG_VERSION" ]]; then
    DEFAULT_VERSION="$CHANGELOG_VERSION"
  fi
fi
VERSION="${APP_VERSION:-${DEFAULT_VERSION}}"
BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
ARCH=""

usage() {
  echo "用法: $0 [--release | --debug] [--version VERSION] [--build NUMBER] [--arch native|universal|arm64|x86_64]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) CONFIG="release" ;;
    --debug) CONFIG="debug" ;;
    --version|--build|--arch)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        usage >&2
        exit 2
      fi
      case "$1" in
        --version) VERSION="$2" ;;
        --build) BUILD_NUMBER="$2" ;;
        --arch) ARCH="$2" ;;
      esac
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "版本号须为 X.Y.Z（可带 v 前缀），构建号须为一至三段数字。" >&2
  exit 2
fi

if [[ -z "$ARCH" ]]; then
  if [[ "$CONFIG" == "release" ]]; then
    ARCH="universal"
  else
    ARCH="native"
  fi
fi

case "$ARCH" in
  native) set -- ;;
  universal) set -- --arch arm64 --arch x86_64 ;;
  arm64|x86_64) set -- --arch "$ARCH" ;;
  *) usage >&2; exit 2 ;;
esac

echo "==> 正在构建 ${EXECUTABLE_NAME} (${CONFIG}, ${ARCH})..."
cd "${ROOT_DIR}"
swift build -c "${CONFIG}" --product "${EXECUTABLE_NAME}" "$@"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path "$@")"
BIN_PATH="${BIN_DIR}/${EXECUTABLE_NAME}"
SWIFTPM_BUNDLE="${BIN_DIR}/AICleaner_AICleanerApp.bundle"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "错误: 未找到构建产物 ${BIN_PATH}" >&2
  exit 1
fi
if [[ ! -d "${SWIFTPM_BUNDLE}/Contents/Resources/ClientLogos" && ! -d "${SWIFTPM_BUNDLE}/ClientLogos" ]]; then
  echo "错误: 未找到客户端标识资源包 ${SWIFTPM_BUNDLE}" >&2
  exit 1
fi

case "$ARCH" in
  universal) lipo "${BIN_PATH}" -verify_arch arm64 x86_64 ;;
  arm64|x86_64) lipo "${BIN_PATH}" -verify_arch "${ARCH}" ;;
esac

DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
mkdir -p "${DIST_DIR}"
STAGING_DIR="$(mktemp -d "${DIST_DIR}/.package-app.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT
STAGED_APP="${STAGING_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${STAGED_APP}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

# 复制随应用分发的客户端品牌标识资源包
ditto "${SWIFTPM_BUNDLE}" "${RESOURCES_DIR}/AICleaner_AICleanerApp.bundle"

# 生成高分辨率 macOS 应用图标 (AppIcon.icns)
ICON_MASTER_PNG="${STAGING_DIR}/AppIcon-1024.png"
ICONSET_DIR="${STAGING_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

echo "==> 正在生成专属应用图标 AppIcon.icns..."
swift "${ROOT_DIR}/scripts/generate-icon.swift" "${ICON_MASTER_PNG}"
for sz in 16 32 128 256 512; do
  sips -z "${sz}" "${sz}" "${ICON_MASTER_PNG}" --out "${ICONSET_DIR}/icon_${sz}x${sz}.png" >/dev/null
  sz2=$((sz * 2))
  sips -z "${sz2}" "${sz2}" "${ICON_MASTER_PNG}" --out "${ICONSET_DIR}/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

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

echo "==> 正在签名并验证应用..."
codesign --force --deep --sign "${SIGNING_IDENTITY}" "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"

rm -rf "${APP_DIR}"
mv "${STAGED_APP}" "${APP_DIR}"

echo "==> 打包完成: ${APP_DIR}"
echo "可直接双击打开，或运行: open \"${APP_DIR}\""
