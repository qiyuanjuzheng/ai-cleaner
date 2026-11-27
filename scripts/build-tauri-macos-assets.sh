#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/apps/desktop"
BUNDLE_ID="com.qiyuanjuzheng.ai-cleaner"
APP_NAME="AI Cleaner"
REPOSITORY="${GITHUB_REPOSITORY:-qiyuanjuzheng/ai-cleaner}"

usage() {
  echo "用法: $0 --tag vX.Y.Z [--local | --ad-hoc]"
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  usage
  exit 0
fi
if [[ $# -lt 2 || $# -gt 3 || "$1" != --tag || ( $# -eq 3 && "$3" != --local && "$3" != --ad-hoc ) ]]; then
  usage >&2
  exit 2
fi
TAG="$2"
if ! [[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  usage >&2
  exit 2
fi
VERSION="${TAG#v}"

LOCAL=false
DESTINATION="$ROOT_DIR/dist/tauri-release/$TAG"
if [[ ${3:-} == --local ]]; then
  LOCAL=true
  DESTINATION="$ROOT_DIR/dist/tauri-local/$TAG"
else
  : "${TAURI_SIGNING_PRIVATE_KEY:?需要 Tauri 更新签名私钥}"
fi

# Ad-hoc signing applies to release and local builds. Clear inherited notarization credentials.
unset APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD
unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH
export APPLE_SIGNING_IDENTITY="-"

if [[ -e "$DESTINATION" ]]; then
  echo "错误: 产物目录已存在: $DESTINATION" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")"
STAGING="$(mktemp -d "$(dirname "$DESTINATION")/.build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ASSETS="$STAGING/assets"
mkdir "$ASSETS"

if [[ "$LOCAL" == true ]]; then
  if [[ -z ${TAURI_UPDATER_PUBLIC_KEY:-} ]]; then
    if ! (cd "$DESKTOP_DIR" && npm run tauri -- signer generate --ci --write-keys "$STAGING/updater.key") >/dev/null 2>&1; then
      echo "错误: 无法生成临时 Tauri 更新签名密钥。" >&2
      exit 1
    fi
    export TAURI_UPDATER_PUBLIC_KEY="$(cat "$STAGING/updater.key.pub")"
    export TAURI_SIGNING_PRIVATE_KEY="$STAGING/updater.key"
    export TAURI_SIGNING_PRIVATE_KEY_PASSWORD=""
  fi
  python3 "$ROOT_DIR/scripts/tauri-build-config.py" "$TAG" "$REPOSITORY" "$STAGING/bundle.json"
else
  python3 "$ROOT_DIR/scripts/tauri-build-config.py" "$TAG" "$REPOSITORY" "$STAGING/bundle.json" --release
fi

cd "$ROOT_DIR"
swift build -c release --product aicleaner-core --arch arm64 --arch x86_64
SWIFT_BIN="$(swift build -c release --show-bin-path --arch arm64 --arch x86_64)/aicleaner-core"
lipo "$SWIFT_BIN" -verify_arch arm64 x86_64
BINARIES="$DESKTOP_DIR/src-tauri/binaries"
mkdir -p "$BINARIES"
install -m 755 "$SWIFT_BIN" "$BINARIES/aicleaner-core-universal-apple-darwin"
lipo "$SWIFT_BIN" -thin arm64 -output "$BINARIES/aicleaner-core-aarch64-apple-darwin"
lipo "$SWIFT_BIN" -thin x86_64 -output "$BINARIES/aicleaner-core-x86_64-apple-darwin"
chmod +x "$BINARIES/aicleaner-core-aarch64-apple-darwin" "$BINARIES/aicleaner-core-x86_64-apple-darwin"

export CARGO_TARGET_DIR="$DESKTOP_DIR/src-tauri/target"
cd "$DESKTOP_DIR"
npm run tauri build -- --ci --target universal-apple-darwin --bundles app,dmg \
  --config "$DESKTOP_DIR/src-tauri/tauri.release.conf.json" --config "$STAGING/bundle.json" -- --locked

BUNDLE="$CARGO_TARGET_DIR/universal-apple-darwin/release/bundle"
APP="$BUNDLE/macos/$APP_NAME.app"
INFO="$APP/Contents/Info.plist"
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"
}
test "$(plist_value CFBundleIdentifier)" = "$BUNDLE_ID"
test "$(plist_value CFBundleVersion)" = "$VERSION"
test "$(plist_value CFBundleShortVersionString)" = "$VERSION"
test "$(plist_value LSMinimumSystemVersion)" = "14.0"
lipo "$APP/Contents/MacOS/$(plist_value CFBundleExecutable)" -verify_arch arm64 x86_64
lipo "$APP/Contents/MacOS/aicleaner-core" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"

DMG="AI-Cleaner-${TAG}-macOS.dmg"
ZIP="AI-Cleaner-${TAG}-macOS.zip"
UPDATE="AI-Cleaner-${TAG}-macOS.app.tar.gz"
cp "$BUNDLE/dmg/${APP_NAME}_${VERSION}_universal.dmg" "$ASSETS/$DMG"
cp "$BUNDLE/macos/$APP_NAME.app.tar.gz" "$ASSETS/$UPDATE"
cp "$BUNDLE/macos/$APP_NAME.app.tar.gz.sig" "$ASSETS/$UPDATE.sig"
files=("$DMG" "$UPDATE" "$UPDATE.sig")
if [[ "$LOCAL" == true ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ASSETS/$ZIP"
  files+=("$ZIP")
fi
(
  cd "$ASSETS"
  shasum -a 256 "${files[@]}" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)

if [[ -e "$DESTINATION" ]]; then
  echo "错误: 产物目录已存在: $DESTINATION" >&2
  exit 1
fi
mv "$ASSETS" "$DESTINATION"
echo "macOS 产物已写入 $DESTINATION"
