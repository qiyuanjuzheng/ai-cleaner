#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "用法: $0 --tag vX.Y.Z"
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  usage
  exit 0
fi
if [[ $# -ne 2 || "$1" != --tag || ! "$2" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  usage >&2
  exit 2
fi

TAG="v${2#v}"
APP_NAME="AI Cleaner"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
RELEASE_DIR="${ROOT_DIR}/dist/release"
DMG="AI-Cleaner-${TAG}-macOS.dmg"
ZIP="AI-Cleaner-${TAG}-macOS.zip"

"${ROOT_DIR}/scripts/package-app.sh" --release --arch universal --version "$TAG"

mkdir -p "$RELEASE_DIR"
WORK_DIR="$(mktemp -d "${RELEASE_DIR}/.build.XXXXXX")"
SOURCE_DIR="${WORK_DIR}/source"
MOUNT_DIR="${WORK_DIR}/mount"
MOUNTED=false

cleanup() {
  if [[ "$MOUNTED" == true ]]; then
    hdiutil detach "$MOUNT_DIR" || hdiutil detach -force "$MOUNT_DIR" || return 1
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$SOURCE_DIR" "$MOUNT_DIR"
ditto "$APP_DIR" "${SOURCE_DIR}/${APP_NAME}.app"
ln -s /Applications "${SOURCE_DIR}/Applications"

for attempt in 1 2 3; do
  if hdiutil create -ov -fs HFS+ -format UDZO -volname "$APP_NAME" -srcfolder "$SOURCE_DIR" "${WORK_DIR}/${DMG}"; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo "错误: 三次尝试后仍无法创建磁盘映像。" >&2
    exit 1
  fi
  sleep "$((attempt * 2))"
done

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "${WORK_DIR}/${DMG}"
MOUNTED=true
test "$(readlink "${MOUNT_DIR}/Applications")" = /Applications
codesign --verify --deep --strict "${MOUNT_DIR}/${APP_NAME}.app"
hdiutil detach "$MOUNT_DIR"
MOUNTED=false

ditto -c -k --sequesterRsrc --keepParent "${SOURCE_DIR}/${APP_NAME}.app" "${WORK_DIR}/${ZIP}"
(
  cd "$WORK_DIR"
  shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS.txt
)

mv -f "${WORK_DIR}/${DMG}" "${WORK_DIR}/${ZIP}" "${WORK_DIR}/SHA256SUMS.txt" "$RELEASE_DIR/"
echo "==> 发布产物已写入 ${RELEASE_DIR}"
