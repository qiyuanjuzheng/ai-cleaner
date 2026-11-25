#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-}"
REPOSITORY="${2:-}"
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "用法: $0 vX.Y.Z OWNER/REPO" >&2
  exit 2
fi
if [[ -z "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
  echo "错误: 缺少 Sparkle EdDSA 签名私钥。" >&2
  exit 2
fi

TOOLS="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
RELEASE_DIR="${ROOT_DIR}/dist/release"
ZIP="AI-Cleaner-${TAG}-macOS.zip"
RELEASE_URL="https://github.com/${REPOSITORY}/releases"
DOWNLOAD_PREFIX="${RELEASE_URL}/download/${TAG}/"
STAGING_DIR="$(mktemp -d "${RELEASE_DIR}/.appcast.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ln "$RELEASE_DIR/$ZIP" "$STAGING_DIR/$ZIP"
NOTES_FILE="$STAGING_DIR/${ZIP%.zip}.md"
"$ROOT_DIR/scripts/generate-release-notes.sh" --changes-only "$TAG" > "$NOTES_FILE"

printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$TOOLS/generate_appcast" \
  --ed-key-file - --maximum-deltas 0 --download-url-prefix "$DOWNLOAD_PREFIX" --embed-release-notes \
  --full-release-notes-url "${RELEASE_URL}/tag/${TAG}" \
  -o "$STAGING_DIR/appcast.xml" "$STAGING_DIR"

# generate_appcast 可能在公钥与私钥不匹配时输出缺少更新包签名的条目。
signature="$(python3 - "$STAGING_DIR/appcast.xml" "$RELEASE_DIR/$ZIP" "$DOWNLOAD_PREFIX$ZIP" "${TAG#v}" "$NOTES_FILE" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

feed, archive, expected_url, expected_version, notes_file = sys.argv[1:]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(feed).findall("./channel/item")
if len(items) != 1:
    sys.exit("错误: 更新源应当包含一个正式版本。")

item = items[0]
enclosure = item.find("enclosure")
if (enclosure is None or enclosure.get("url") != expected_url
        or enclosure.get("length") != str(Path(archive).stat().st_size)
        or item.findtext(f"{sparkle}version") != expected_version):
    sys.exit("错误: 更新源与发布版本或 ZIP 不匹配。")

description = item.find("description")
if (description is None or description.get(f"{sparkle}format") != "markdown"
        or (description.text or "").strip() != Path(notes_file).read_text(encoding="utf-8").strip()):
    sys.exit("错误: 更新源未内嵌当前版本的 Markdown 更新日志。")

signature = enclosure.get(f"{sparkle}edSignature")
if not signature:
    sys.exit("错误: 更新包没有 EdDSA 签名，请核对发布私钥与应用内公钥。")
print(signature)
PY
)"
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$TOOLS/sign_update" --ed-key-file - --verify "$STAGING_DIR/appcast.xml"
printf '%s\n' "$SPARKLE_PRIVATE_ED_KEY" | "$TOOLS/sign_update" --ed-key-file - --verify "$RELEASE_DIR/$ZIP" "$signature"
mv -f "$STAGING_DIR/appcast.xml" "$RELEASE_DIR/appcast.xml"
