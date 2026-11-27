#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_URL="${RELEASE_REPO_URL:-https://github.com/${GITHUB_REPOSITORY:-qiyuanjuzheng/ai-cleaner}}"
CHANGES_ONLY=false
case "${1:-}" in
  --changes-only) CHANGES_ONLY=true; shift ;;
  --tauri) shift ;;
esac

if [[ $# -ne 1 || ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "用法: $0 [--changes-only | --tauri] vX.Y.Z" >&2
  exit 2
fi

TAG="$1"
VERSION="${TAG#v}"
cd "$ROOT_DIR"

NOTES="$(awk -v tagged="[$TAG]" -v untagged="[$VERSION]" '
  /^##[[:space:]]/ {
    if (found) exit
    found = ($2 == tagged || $2 == untagged)
    next
  }
  found { print }
' CHANGELOG.md | awk '
  { lines[NR] = $0 }
  END {
    start = 1
    while (start <= NR && lines[start] ~ /^[[:space:]]*$/) start++
    end = NR
    while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
    for (i = start; i <= end; i++) print lines[i]
  }
')"
if [[ ! "$NOTES" =~ [^[:space:]] ]]; then
  echo "错误: CHANGELOG.md 中缺少 ${TAG} 的版本说明。" >&2
  exit 1
fi
if [[ "$CHANGES_ONLY" == true ]]; then
  printf '%s\n' "$NOTES"
  exit 0
fi

# 标签尚未创建时，用当前提交预览说明。正式发布时比较标签所指向的提交。
TARGET="HEAD"
if git show-ref --verify --quiet "refs/tags/${TAG}"; then
  TARGET="refs/tags/${TAG}"
fi
PREVIOUS_TAG="$(git tag --merged "$TARGET" --sort=-version:refname | awk -v current="$VERSION" '
  BEGIN { split(current, version, ".") }
  /^v[0-9]+\.[0-9]+\.[0-9]+$/ && !previous {
    split(substr($0, 2), candidate, ".")
    for (i = 1; i <= 3; i++) {
      if (candidate[i] + 0 < version[i] + 0) { previous = $0; break }
      if (candidate[i] + 0 > version[i] + 0) break
    }
  }
  END { if (previous) print previous }
')"

if [[ -z "$PREVIOUS_TAG" ]]; then
  printf '## 首版核心功能\n\n'
else
  printf '## 版本变化\n\n'
fi
printf '%s\n' "$NOTES"

if [[ -n "$PREVIOUS_TAG" ]]; then
  printf '\n## 与上一版本（`%s`）的区别\n\n' "$PREVIOUS_TAG"
  COMMIT_LIST="$(git log --first-parent --format='%h%x1f%s%x1f%b%x1e' "refs/tags/${PREVIOUS_TAG}..${TARGET}" -- | awk '
    BEGIN { RS = "\036"; FS = "\037" }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 == "") next
      sha = $1
      subj = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", subj)
      body = $3
      if (subj ~ /^[Cc][Hh][Oo][Rr][Ee]\(release\):/ ||
          subj ~ /^Merge pull request #[0-9]+ from [^ ]+\/release-pr\// ||
          subj ~ /^Merge branch '\''release-pr\// ||
          index(body, "Release-PR: true") > 0) {
        next
      }
      title = subj
      if (subj ~ /^Merge pull request #[0-9]+ from /) {
        pr = subj
        sub(/^Merge pull request #/, "", pr)
        sub(/ from .*/, "", pr)
        n = split(body, lines, "\n")
        pr_title = ""
        for (i = 1; i <= n; i++) {
          line = lines[i]
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (line != "" && line !~ /^#/ && line !~ /^(Co-authored-by|Signed-off-by|Reviewed-by):/) {
            pr_title = line
            break
          }
        }
        if (pr_title != "") {
          if (index(pr_title, "(#" pr ")") > 0) {
            title = pr_title
          } else {
            title = pr_title " (#" pr ")"
          }
        }
      }
      printf "- %s (`%s`)\n", title, sha
    }
  ')"
  if [[ -n "$COMMIT_LIST" ]]; then
    printf '%s\n\n' "$COMMIT_LIST"
  fi
  printf '[查看完整对比](%s/compare/%s...%s)\n' "$REPO_URL" "$PREVIOUS_TAG" "$TAG"
fi

DOWNLOAD_URL="${REPO_URL}/releases/download/${TAG}"
cat <<EOF

## 下载与安装

- **macOS 14.0 或更新版本**：下载 [Universal DMG](${DOWNLOAD_URL}/AI-Cleaner-${TAG}-macOS.dmg)，将 **AI Cleaner.app** 拖入「应用程序」。支持 Apple Silicon 和 Intel Mac。
- **Windows x64**：从附件下载 NSIS 安装程序（\`.exe\`）或 MSI 安装包（\`.msi\`）。
- **Linux x64**：按发行版选择 \`.deb\`、\`.rpm\` 或 \`.AppImage\`。

macOS 安装包使用 ad-hoc 签名。首次打开时，可能需要在「系统设置 → 隐私与安全性」选择「仍要打开」。Windows 安装包未使用 Authenticode，可能显示未知发布者提示，启用 Smart App Control 的设备可能拦截。应用内更新仍验证 Tauri 更新签名。

### SHA-256 校验

计算所下载文件的 SHA-256，并与 [SHA256SUMS.txt](${DOWNLOAD_URL}/SHA256SUMS.txt) 中的同名条目比较。
EOF
