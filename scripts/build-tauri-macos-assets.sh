#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/apps/desktop"
BUNDLE_ID="com.qiyuanjuzheng.ai-cleaner"
APP_NAME="AI Cleaner"
REPOSITORY="${GITHUB_REPOSITORY:-qiyuanjuzheng/ai-cleaner}"
LEGACY_VERSION=0.4.0
# Public key shipped in the signed Sparkle feeds and macOS bundles for v0.3.2 and v0.4.0.
LEGACY_PUBLIC_KEY="5WoYA4Y0OySQHM60P5QfrvjkGaZ/5dtNJGNWeggHZbI="

usage() {
  echo "用法: $0 --tag vX.Y.Z [--local]"
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  usage
  exit 0
fi
if [[ $# -lt 2 || $# -gt 3 || "$1" != --tag || ( $# -eq 3 && "$3" != --local ) ]]; then
  usage >&2
  exit 2
fi
TAG="$2"
if ! [[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  usage >&2
  exit 2
fi
VERSION="${TAG#v}"
python3 - "$VERSION" "$LEGACY_VERSION" <<'PY'
import sys

version, legacy = (tuple(map(int, value.split("."))) for value in sys.argv[1:])
if version <= legacy:
    sys.exit(f"错误: Tauri 版本必须高于 v{sys.argv[2]}。")
PY

LOCAL=false
if [[ ${3:-} == --local ]]; then
  LOCAL=true
  export APPLE_SIGNING_IDENTITY="-"
  SIGNING_KEY="$(openssl rand -base64 32)"
else
  : "${APPLE_SIGNING_IDENTITY:?需要 Developer ID Application 签名身份}"
  SIGNING_KEY="${SPARKLE_PRIVATE_ED_KEY:?需要旧版 Sparkle 签名私钥}"
  if [[ "$APPLE_SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
    echo "错误: 正式产物必须使用 Developer ID Application 签名。" >&2
    exit 2
  fi
fi
unset SPARKLE_PRIVATE_ED_KEY
PUBLIC_KEY="$(printf '%s\n' "$SIGNING_KEY" | swift "$ROOT_DIR/scripts/sparkle-public-key.swift")"
if [[ "$LOCAL" == false && "$PUBLIC_KEY" != "$LEGACY_PUBLIC_KEY" ]]; then
  echo "错误: Sparkle 私钥与旧版应用内的公钥不匹配。" >&2
  exit 2
fi

DESTINATION="$ROOT_DIR/dist/tauri-release/$TAG"
if [[ "$LOCAL" == true ]]; then
  DESTINATION="$ROOT_DIR/dist/tauri-local/$TAG"
fi
if [[ -e "$DESTINATION" ]]; then
  echo "错误: 产物目录已存在: $DESTINATION" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")"
STAGING="$(mktemp -d "$(dirname "$DESTINATION")/.build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ASSETS="$STAGING/assets"
mkdir "$ASSETS"
NOTES="$STAGING/release-notes.md"
if [[ "$LOCAL" == true ]]; then
  printf '本地验证 Tauri macOS 打包与 Sparkle 更新格式。\n' > "$NOTES"
else
  "$ROOT_DIR/scripts/generate-release-notes.sh" --changes-only "$TAG" > "$NOTES"
fi

python3 - "$STAGING" "$VERSION" "$PUBLIC_KEY" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

staging, version, public_key = sys.argv[1:]
staging = Path(staging)
plist = staging / "SparkleMigration.plist"
with plist.open("wb") as stream:
    plistlib.dump({
        "SUPublicEDKey": public_key,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }, stream)
(staging / "bundle.json").write_text(json.dumps({
    "version": version,
    "bundle": {"macOS": {"infoPlist": str(plist), "bundleVersion": version}},
}), encoding="utf-8")
PY

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
test "$(plist_value SUPublicEDKey)" = "$PUBLIC_KEY"
test "$(plist_value SURequireSignedFeed)" = true
test "$(plist_value SUVerifyUpdateBeforeExtraction)" = true
test ! -e "$APP/Contents/Frameworks/Sparkle.framework"
lipo "$APP/Contents/MacOS/$(plist_value CFBundleExecutable)" -verify_arch arm64 x86_64
lipo "$APP/Contents/MacOS/aicleaner-core" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
if [[ "$LOCAL" == false ]]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

DMG="AI-Cleaner-${TAG}-macOS.dmg"
ZIP="AI-Cleaner-${TAG}-macOS.zip"
cp "$BUNDLE/dmg/${APP_NAME}_${VERSION}_universal.dmg" "$ASSETS/$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ASSETS/$ZIP"
SPARKLE_PRIVATE_ED_KEY="$SIGNING_KEY" \
  bash "$ROOT_DIR/scripts/generate-update-feed.sh" "$TAG" "$REPOSITORY" "$ASSETS" "$NOTES"
(
  cd "$ASSETS"
  shasum -a 256 "$DMG" "$ZIP" appcast.xml > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)

if [[ -e "$DESTINATION" ]]; then
  echo "错误: 产物目录已存在: $DESTINATION" >&2
  exit 1
fi
mv "$ASSETS" "$DESTINATION"
echo "macOS 产物已写入 $DESTINATION"
