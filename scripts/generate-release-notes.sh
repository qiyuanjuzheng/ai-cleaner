#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_URL="${RELEASE_REPO_URL:-https://github.com/${GITHUB_REPOSITORY:-qiyuanjuzheng/ai-cleaner}}"
CHANGES_ONLY=false
if [[ "${1:-}" == --changes-only ]]; then
  CHANGES_ONLY=true
  shift
fi

if [[ $# -ne 1 || ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "用法: $0 [--changes-only] vX.Y.Z" >&2
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

需要 macOS 14.0（Sonoma）或更新版本。Universal 通用包支持 Apple Silicon 和 Intel Mac。

1. 下载 [AI-Cleaner-${TAG}-macOS.dmg](${DOWNLOAD_URL}/AI-Cleaner-${TAG}-macOS.dmg)，打开磁盘映像，将 **AI Cleaner.app** 拖入「应用程序」。
2. 也可以下载 [AI-Cleaner-${TAG}-macOS.zip](${DOWNLOAD_URL}/AI-Cleaner-${TAG}-macOS.zip)，解压后将应用移入「应用程序」。

### 首次打开

安装包采用 ad-hoc 签名，尚未经过 Apple 公证。确认安装包来自本页并通过校验后，若 macOS 拦截首次打开，可先尝试启动应用，再前往「系统设置 → 隐私与安全性 → 仍要打开」。也可以在终端执行以下命令后重新打开应用。

\`\`\`bash
xattr -cr "/Applications/AI Cleaner.app"
\`\`\`

### SHA-256 校验

将两个安装包和 [SHA256SUMS.txt](${DOWNLOAD_URL}/SHA256SUMS.txt) 放在同一个目录，在该目录执行：

\`\`\`bash
shasum -a 256 -c SHA256SUMS.txt
\`\`\`
EOF
