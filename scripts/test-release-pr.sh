#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: ${msg}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if ! grep -Fq -- "$needle" <<< "$haystack"; then
    echo "FAIL: ${msg}" >&2
    echo "  missing substring: ${needle}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if grep -Fq -- "$needle" <<< "$haystack"; then
    echo "FAIL: ${msg}" >&2
    echo "  unexpected substring: ${needle}" >&2
    exit 1
  fi
}

assert_count() {
  local haystack="$1"
  local needle="$2"
  local expected="$3"
  local msg="$4"
  local count
  count="$(grep -Fc -- "$needle" <<< "$haystack" || true)"
  assert_eq "$expected" "$count" "$msg"
}

json_field() {
  python3 -c 'import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
val = data[sys.argv[2]]
if isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
' "$1" "$2"
}

BARE_REPO="${TMP_BASE}/origin.git"
WORK_REPO="${TMP_BASE}/repo"
HUMAN_CLONE="${TMP_BASE}/human-clone"

git init --bare --quiet -b main "$BARE_REPO"
git init --quiet -b main "$WORK_REPO"
git -C "$WORK_REPO" config user.name "Test Bot"
git -C "$WORK_REPO" config user.email "bot@example.com"
git -C "$WORK_REPO" remote add origin "$BARE_REPO"

# Copy release scripts into isolated repo
mkdir -p "${WORK_REPO}/scripts" "${WORK_REPO}/Sources" "${WORK_REPO}/site" "${WORK_REPO}/docs"
cp "${ROOT_DIR}/scripts/release-pr.sh" "${WORK_REPO}/scripts/"
cp "${ROOT_DIR}/scripts/release-pr-lib.py" "${WORK_REPO}/scripts/"
cp "${ROOT_DIR}/scripts/generate-release-notes.sh" "${WORK_REPO}/scripts/"
chmod +x "${WORK_REPO}/scripts/release-pr.sh" "${WORK_REPO}/scripts/generate-release-notes.sh"

cat > "${WORK_REPO}/CHANGELOG.md" <<'EOF'
## [Unreleased]

## [v0.1.0] - 2026-11-25

### 新增

- **多客户端可视化扫描**。首版核心功能。
EOF
printf 'hello\n' > "${WORK_REPO}/Sources/App.swift"
printf '<h1>Site</h1>\n' > "${WORK_REPO}/site/index.html"
printf '# AI Cleaner\n' > "${WORK_REPO}/README.md"

git -C "$WORK_REPO" add .
git -C "$WORK_REPO" commit --quiet -m "AICL-7: Initial v0.1.0 baseline"
git -C "$WORK_REPO" tag -a v0.1.0 -m "AI Cleaner v0.1.0"
git -C "$WORK_REPO" push --quiet -u origin main --tags

echo "==> [1/6] 验证纯文档/官网与 [skip release] 改动被正确过滤"
git -C "$WORK_REPO" checkout --quiet -b feat/docs-only
printf '<h1>Updated Site</h1>\n' > "${WORK_REPO}/site/index.html"
printf 'docs update\n' > "${WORK_REPO}/README.md"
printf 'note\n' > "${WORK_REPO}/docs/note.md"
git -C "$WORK_REPO" add site/index.html README.md docs/note.md
git -C "$WORK_REPO" commit --quiet -m "AICL-9: 重设计官网并更新说明"
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --no-ff feat/docs-only -m "Merge pull request #8 from qiyuanjuzheng/feat/docs-only

AICL-9 重设计 AI Cleaner 官网并接入 macOS 下载"

PLAN_OUT="${TMP_BASE}/plan1.json"
"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --date 2026-11-26 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "skip" "$(json_field "$PLAN_OUT" action)" "docs-only PR should skip Release PR"

DETECT_OUT="${TMP_BASE}/detect1.json"
"${WORK_REPO}/scripts/release-pr.sh" detect --repo "$WORK_REPO" --head HEAD > "$DETECT_OUT"
assert_eq "false" "$(json_field "$DETECT_OUT" is_release_merge)" "docs-only merge must not trigger release"

# Commit with [skip release]
printf '// internal comment\n' >> "${WORK_REPO}/Sources/App.swift"
git -C "$WORK_REPO" add Sources/App.swift
git -C "$WORK_REPO" commit --quiet -m "chore: 内部调试注释 [skip release]"
"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --date 2026-11-26 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "skip" "$(json_field "$PLAN_OUT" action)" "[skip release] commit should skip Release PR"

echo "==> [2/6] 验证中文修复提交触发 Patch Release PR (v0.1.1)"
git -C "$WORK_REPO" checkout --quiet -b feat/aicl-10
printf 'struct Motion {}\n' > "${WORK_REPO}/Sources/Motion.swift"
git -C "$WORK_REPO" add Sources/Motion.swift
git -C "$WORK_REPO" commit --quiet -m "AICL-10 恢复环中心数字滚动"
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --no-ff feat/aicl-10 -m "Merge pull request #9 from qiyuanjuzheng/feat/aicl-10

AICL-10 恢复环中心数字滚动"

"${WORK_REPO}/scripts/release-pr.sh" detect --repo "$WORK_REPO" --head HEAD > "$DETECT_OUT"
assert_eq "false" "$(json_field "$DETECT_OUT" is_release_merge)" "feature PR merge must not trigger publish"

BODY_OUT="${TMP_BASE}/pr-body.md"
"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --date 2026-11-26 \
  --output-pr-body "$BODY_OUT" \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "create_or_update" "$(json_field "$PLAN_OUT" action)" "fix PR should create Release PR"
assert_eq "v0.1.1" "$(json_field "$PLAN_OUT" next_tag)" "fix PR should bump to v0.1.1"
assert_eq "patch" "$(json_field "$PLAN_OUT" bump)" "fix PR bump should be patch"

CL1="$(git -C "$WORK_REPO" show release-pr/main:CHANGELOG.md)"
assert_contains "$CL1" "## [v0.1.1] - 2026-11-26" "CHANGELOG should have v0.1.1 heading"
assert_contains "$CL1" "### 修复" "CHANGELOG should categorize fix under 修复"
assert_contains "$CL1" "AICL-10 恢复环中心数字滚动 (#9)" "CHANGELOG should include AICL-10"
assert_not_contains "$CL1" "AICL-9" "docs-only AICL-9 must stay excluded"
assert_not_contains "$CL1" "内部调试注释" "[skip release] commit must stay excluded"

echo "==> [3/6] 验证后续合并原地累加升级至 v0.2.0、噪音不搅动且不重复"
git -C "$WORK_REPO" fetch --quiet origin +refs/heads/release-pr/main:refs/remotes/origin/release-pr/main

# Docs-only PR while Release PR is open -> keep without churn
printf 'more docs\n' >> "${WORK_REPO}/README.md"
git -C "$WORK_REPO" add README.md
git -C "$WORK_REPO" commit --quiet -m "docs: 补充说明"
"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --has-open-pr true \
  --date 2026-11-26 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "keep" "$(json_field "$PLAN_OUT" action)" "docs-only commit while PR open should keep without churn"

# Merge Chinese feature PR (#12) + Conventional Commit feat & chore
git -C "$WORK_REPO" checkout --quiet -b feat/aicl-13
printf 'struct Excluded {}\n' > "${WORK_REPO}/Sources/Excluded.swift"
git -C "$WORK_REPO" add Sources/Excluded.swift
git -C "$WORK_REPO" commit --quiet -m "AICL-13: Support excluding items"
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --no-ff feat/aicl-13 -m "Merge pull request #12 from qiyuanjuzheng/feat/aicl-13

AICL-13: 支持清理条目右键排除、查看已排除列表及恢复"

printf 'struct Scanner {}\n' > "${WORK_REPO}/Sources/Scanner.swift"
git -C "$WORK_REPO" add Sources/Scanner.swift
git -C "$WORK_REPO" commit --quiet -m "feat(scanner): 添加扫描结果导出按钮 (#14)"

printf '// tweak\n' >> "${WORK_REPO}/Sources/Scanner.swift"
git -C "$WORK_REPO" add Sources/Scanner.swift
git -C "$WORK_REPO" commit --quiet -m "AICL-11 在待清理会话列表中显示会话标题"

"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --has-open-pr true \
  --date 2026-11-26 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "create_or_update" "$(json_field "$PLAN_OUT" action)" "feature PRs should update Release PR"
assert_eq "v0.2.0" "$(json_field "$PLAN_OUT" next_tag)" "feature PRs should bump to v0.2.0"
assert_eq "minor" "$(json_field "$PLAN_OUT" bump)" "feature PRs bump should be minor"

CL2="$(git -C "$WORK_REPO" show release-pr/main:CHANGELOG.md)"
assert_contains "$CL2" "## [v0.2.0] - 2026-11-26" "CHANGELOG should upgrade to v0.2.0 in place"
assert_not_contains "$CL2" "## [v0.1.1]" "stale v0.1.1 heading must be replaced"
assert_contains "$CL2" "### 新增" "CHANGELOG should have 新增"
assert_contains "$CL2" "### 修复" "CHANGELOG should have 修复"
assert_contains "$CL2" "### 优化与变更" "CHANGELOG should have 优化与变更"
assert_count "$CL2" "AICL-10 恢复环中心数字滚动 (#9)" 1 "AICL-10 must appear exactly once"
assert_count "$CL2" "AICL-13: 支持清理条目右键排除、查看已排除列表及恢复 (#12)" 1 "AICL-13 must appear exactly once"
assert_count "$CL2" "**scanner**：添加扫描结果导出按钮 (#14)" 1 "Conventional Commit feat(scanner) must be formatted once"
assert_count "$CL2" "AICL-11 在待清理会话列表中显示会话标题" 1 "Non-conventional Chinese commit must be included once"

# Re-running on same HEAD must be idempotent keep
git -C "$WORK_REPO" fetch --quiet origin +refs/heads/release-pr/main:refs/remotes/origin/release-pr/main
"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --has-open-pr true \
  --date 2026-11-26 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "keep" "$(json_field "$PLAN_OUT" action)" "repeat run on same HEAD must keep"

echo "==> [4/6] 验证人工编辑 Release PR 版本号与日志后追加提交、合并、打标与发布说明生成"
git clone --quiet --branch release-pr/main "$BARE_REPO" "$HUMAN_CLONE"
git -C "$HUMAN_CLONE" config user.name "Human Reviewer"
git -C "$HUMAN_CLONE" config user.email "human@example.com"
cat > "${HUMAN_CLONE}/CHANGELOG.md" <<'EOF'
## [Unreleased]

## [v0.3.0] - 2026-11-26

### 新增

- 支持右键快速排除无需清理的条目，并可随时查看与恢复（人工润色）。
- **scanner**：添加扫描结果导出按钮 (#14)

### 修复

- 恢复扫描环中心数字滚动动画。

### 优化与变更

- 在待清理会话列表中优先显示客户端保存的会话标题。

## [v0.1.0] - 2026-11-25

### 新增

- **多客户端可视化扫描**。首版核心功能。
EOF
git -C "$HUMAN_CLONE" add CHANGELOG.md
git -C "$HUMAN_CLONE" commit --quiet -m "docs: 润色中文更新日志并将目标版本调整为 v0.3.0"
git -C "$HUMAN_CLONE" push --quiet origin release-pr/main

# Now another feature PR merges into main before the human merges the Release PR
git -C "$WORK_REPO" fetch --quiet origin +refs/heads/release-pr/main:refs/remotes/origin/release-pr/main
git -C "$WORK_REPO" checkout --quiet -b feat/aicl-14
printf 'struct TmpScanner {}\n' > "${WORK_REPO}/Sources/TmpScanner.swift"
git -C "$WORK_REPO" add Sources/TmpScanner.swift
git -C "$WORK_REPO" commit --quiet -m "AICL-14: Support layered /tmp scanning"
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --no-ff feat/aicl-14 -m "Merge pull request #13 from qiyuanjuzheng/feat/aicl-14

AICL-14: 支持 /tmp 分层扫描与清理（AI 特征精准归类 + 未归属项仅手选）"

"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --has-open-pr true \
  --date 2026-11-26 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "create_or_update" "$(json_field "$PLAN_OUT" action)" "new PR after human edit should append"
assert_eq "true" "$(json_field "$PLAN_OUT" human_edited)" "human_edited flag must be true"
assert_eq "v0.3.0" "$(json_field "$PLAN_OUT" pinned_version)" "human version override v0.3.0 must be preserved"
assert_eq "v0.3.0" "$(json_field "$PLAN_OUT" next_tag)" "next_tag must stay v0.3.0"

CL3="$(git -C "$WORK_REPO" show release-pr/main:CHANGELOG.md)"
assert_contains "$CL3" "## [v0.3.0] - 2026-11-26" "human overridden v0.3.0 heading must remain"
assert_contains "$CL3" "支持右键快速排除无需清理的条目，并可随时查看与恢复（人工润色）。" "human prose must remain intact"
assert_contains "$CL3" "AICL-14: 支持 /tmp 分层扫描与清理（AI 特征精准归类 + 未归属项仅手选） (#13)" "new PR #13 must be appended"
assert_not_contains "$CL3" "AICL-13:" "already-rewritten AICL-13 must not be duplicated back"

# Merge Release PR into main (merge commit style)
BEFORE_RELEASE_MERGE="$(git -C "$WORK_REPO" rev-parse HEAD)"
git -C "$WORK_REPO" merge --quiet --no-ff release-pr/main -m "Merge pull request #99 from qiyuanjuzheng/release-pr/main

chore(release): 发布 v0.3.0"
git -C "$WORK_REPO" push --quiet origin main

GH_OUT="${TMP_BASE}/github-output.txt"
: > "$GH_OUT"
"${WORK_REPO}/scripts/release-pr.sh" detect \
  --repo "$WORK_REPO" \
  --head HEAD \
  --base "$BEFORE_RELEASE_MERGE" \
  --github-output "$GH_OUT" > "$DETECT_OUT"
assert_eq "true" "$(json_field "$DETECT_OUT" is_release_merge)" "Release PR merge commit must be detected"
assert_eq "v0.3.0" "$(json_field "$DETECT_OUT" release_tag)" "Final overridden version v0.3.0 must be extracted"
assert_eq "99" "$(json_field "$DETECT_OUT" pr_number)" "Merged PR number must be extracted"
assert_contains "$(cat "$GH_OUT")" "release_tag=v0.3.0" "GITHUB_OUTPUT should contain release_tag=v0.3.0"

# Create annotated tag idempotently and verify conflict protection
"${WORK_REPO}/scripts/release-pr.sh" create-tag --repo "$WORK_REPO" --tag v0.3.0 --target HEAD --remote origin --push >/dev/null
"${WORK_REPO}/scripts/release-pr.sh" create-tag --repo "$WORK_REPO" --tag v0.3.0 --target HEAD --remote origin --push >/dev/null
if "${WORK_REPO}/scripts/release-pr.sh" create-tag --repo "$WORK_REPO" --tag v0.1.0 --target HEAD >/dev/null 2>&1; then
  echo "FAIL: create-tag must refuse to overwrite existing tag pointing to older commit" >&2
  exit 1
fi

# Verify generate-release-notes.sh on v0.3.0
NOTES_V030="$("${WORK_REPO}/scripts/generate-release-notes.sh" v0.3.0)"
assert_contains "$NOTES_V030" "## 版本变化" "release notes must contain 版本变化"
assert_contains "$NOTES_V030" "支持右键快速排除无需清理的条目，并可随时查看与恢复（人工润色）。" "release notes must contain confirmed human CHANGELOG text"
assert_contains "$NOTES_V030" "## 与上一版本（\`v0.1.0\`）的区别" "release notes must compare against v0.1.0"
assert_contains "$NOTES_V030" "[查看完整对比](https://github.com/qiyuanjuzheng/ai-cleaner/compare/v0.1.0...v0.3.0)" "release notes must contain compare link"
assert_contains "$NOTES_V030" "AI-Cleaner-v0.3.0-macOS.dmg" "release notes must include DMG link"
assert_not_contains "$NOTES_V030" "macOS.zip" "release notes must only refer to Tauri release assets"
assert_contains "$NOTES_V030" "NSIS" "release notes must describe Windows installers"
assert_contains "$NOTES_V030" "AppImage" "release notes must describe Linux packages"
assert_contains "$NOTES_V030" "SHA256SUMS.txt" "release notes must include checksums link"
assert_not_contains "$NOTES_V030" "Merge pull request #99" "release notes commit list must exclude Release PR merge commit"
assert_not_contains "$NOTES_V030" "Merge pull request #13 from" "PR merges should display readable PR title instead of raw branch name"
assert_contains "$NOTES_V030" "AICL-14: 支持 /tmp 分层扫描与清理（AI 特征精准归类 + 未归属项仅手选） (#13)" "PR #13 readable title should appear in diff"

TAURI_NOTES_V030="$("${WORK_REPO}/scripts/generate-release-notes.sh" --tauri v0.3.0)"
assert_eq "$NOTES_V030" "$TAURI_NOTES_V030" "the --tauri option must produce the same notes as the default"
assert_contains "$NOTES_V030" "ad-hoc" "release notes must describe the macOS signature"
assert_contains "$NOTES_V030" "Authenticode" "release notes must describe Windows signing status"
assert_contains "$NOTES_V030" "Tauri 更新签名" "release notes must explain update verification"

echo "==> [5/6] 验证新一轮周期（Major 破坏性变更 -> v1.0.0）、Squash 合并与 GitHub API 识别及防误触发"
git -C "$WORK_REPO" push --quiet origin --delete release-pr/main
printf 'struct V1Rule {}\n' > "${WORK_REPO}/Sources/V1Rule.swift"
git -C "$WORK_REPO" add Sources/V1Rule.swift
git -C "$WORK_REPO" commit --quiet -m "feat!: 升级内置规则格式至 v2"

"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --has-open-pr false \
  --date 2026-11-27 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "create_or_update" "$(json_field "$PLAN_OUT" action)" "new cycle after v0.3.0 should open fresh Release PR"
assert_eq "v0.3.0" "$(json_field "$PLAN_OUT" last_tag)" "last_tag should advance to v0.3.0"
assert_eq "v1.0.0" "$(json_field "$PLAN_OUT" next_tag)" "breaking change should bump to v1.0.0"
assert_eq "major" "$(json_field "$PLAN_OUT" bump)" "breaking change bump should be major"

# Squash merge Release PR
BEFORE_SQUASH="$(git -C "$WORK_REPO" rev-parse HEAD)"
git -C "$WORK_REPO" merge --quiet --squash release-pr/main
git -C "$WORK_REPO" commit --quiet -m "chore(release): 发布 v1.0.0 (#100)"
SQUASH_SHA="$(git -C "$WORK_REPO" rev-parse HEAD)"

"${WORK_REPO}/scripts/release-pr.sh" detect \
  --repo "$WORK_REPO" \
  --head HEAD \
  --base "$BEFORE_SQUASH" > "$DETECT_OUT"
assert_eq "true" "$(json_field "$DETECT_OUT" is_release_merge)" "squash-merged Release PR must be detected"
assert_eq "v1.0.0" "$(json_field "$DETECT_OUT" release_tag)" "squash-merged version v1.0.0 must be extracted"
assert_eq "100" "$(json_field "$DETECT_OUT" pr_number)" "squash-merged PR number must be extracted"

# Verify GitHub API merged-pr-json matching
MOCK_MERGED_JSON="${TMP_BASE}/merged-prs.json"
cat > "$MOCK_MERGED_JSON" <<EOF
[
  {
    "number": 100,
    "title": "chore(release): 发布 v1.0.0",
    "state": "MERGED",
    "mergedAt": "2026-11-27T01:00:00Z",
    "mergeCommit": { "oid": "${SQUASH_SHA}" },
    "headRefName": "release-pr/main",
    "labels": [{"name": "release-pr"}]
  }
]
EOF
"${WORK_REPO}/scripts/release-pr.sh" detect \
  --repo "$WORK_REPO" \
  --head HEAD \
  --base "$BEFORE_SQUASH" \
  --merged-pr-json "$MOCK_MERGED_JSON" > "$DETECT_OUT"
assert_eq "true" "$(json_field "$DETECT_OUT" is_release_merge)" "GitHub API merged PR must be detected"
assert_eq "github_api" "$(json_field "$DETECT_OUT" reason)" "GitHub API should be primary detection reason"

# Verify a non-Release PR that edits CHANGELOG.md does NOT falsely trigger release
BEFORE_TYPO="$(git -C "$WORK_REPO" rev-parse HEAD)"
sed -i.bak 's/首版核心功能。/首版核心功能说明。/' "${WORK_REPO}/CHANGELOG.md"
rm -f "${WORK_REPO}/CHANGELOG.md.bak"
git -C "$WORK_REPO" add CHANGELOG.md
git -C "$WORK_REPO" commit --quiet -m "docs: 修正 CHANGELOG 错别字 (#101)"
TYPO_SHA="$(git -C "$WORK_REPO" rev-parse HEAD)"
MOCK_NORMAL_PR="${TMP_BASE}/normal-pr.json"
cat > "$MOCK_NORMAL_PR" <<EOF
[
  {
    "number": 101,
    "state": "closed",
    "merged_at": "2026-11-27T02:00:00Z",
    "merge_commit_sha": "${TYPO_SHA}",
    "head": { "ref": "docs/fix-changelog-typo" },
    "labels": []
  }
]
EOF
"${WORK_REPO}/scripts/release-pr.sh" detect \
  --repo "$WORK_REPO" \
  --head HEAD \
  --base "$BEFORE_TYPO" \
  --pr-json "$MOCK_NORMAL_PR" > "$DETECT_OUT"
assert_eq "false" "$(json_field "$DETECT_OUT" is_release_merge)" "normal PR editing CHANGELOG must NOT trigger release"

echo "==> [6/6] 验证 Rebase-and-Merge（含人工二次编辑版本号）及本地多提交分支合并"
"${WORK_REPO}/scripts/release-pr.sh" create-tag --repo "$WORK_REPO" --tag v1.0.0 --target "$SQUASH_SHA" --remote origin --push >/dev/null
git -C "$WORK_REPO" push --quiet origin --delete release-pr/main

# Local multi-commit branch merged with plain `git merge --no-ff` (no GitHub PR body)
git -C "$WORK_REPO" checkout --quiet -b feat/local-multi
printf 'struct A {}\n' > "${WORK_REPO}/Sources/A.swift"
git -C "$WORK_REPO" add Sources/A.swift
git -C "$WORK_REPO" commit --quiet -m "fix: 修正本地合并场景识别"
printf 'struct B {}\n' > "${WORK_REPO}/Sources/B.swift"
git -C "$WORK_REPO" add Sources/B.swift
git -C "$WORK_REPO" commit --quiet -m "feat: 支持增量日志追加"
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --no-ff feat/local-multi -m "Merge branch 'feat/local-multi'"

"${WORK_REPO}/scripts/release-pr.sh" prepare-branch \
  --repo "$WORK_REPO" \
  --base-ref HEAD \
  --has-open-pr false \
  --date 2026-11-28 \
  --output-json "$PLAN_OUT" \
  --push >/dev/null
assert_eq "v1.1.0" "$(json_field "$PLAN_OUT" next_tag)" "local multi-commit merge with feat+fix should bump v1.0.0 -> v1.1.0"

# Simulate human adding a second commit on release-pr/main changing v1.1.0 -> v1.2.0, then rebase-merging both commits
BEFORE_REBASE="$(git -C "$WORK_REPO" rev-parse HEAD)"
git -C "$WORK_REPO" checkout --quiet release-pr/main
sed -i.bak 's/## \[v1.1.0\]/## [v1.2.0]/' "${WORK_REPO}/CHANGELOG.md"
rm -f "${WORK_REPO}/CHANGELOG.md.bak"
git -C "$WORK_REPO" add CHANGELOG.md
git -C "$WORK_REPO" commit --quiet -m "docs: 手动将目标版本调整为 v1.2.0"
REBASE_TIP="$(git -C "$WORK_REPO" rev-parse HEAD)"
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --ff-only "$REBASE_TIP"

"${WORK_REPO}/scripts/release-pr.sh" detect \
  --repo "$WORK_REPO" \
  --head HEAD \
  --base "$BEFORE_REBASE" > "$DETECT_OUT"
assert_eq "true" "$(json_field "$DETECT_OUT" is_release_merge)" "rebase-merged multi-commit Release PR must be detected"
assert_eq "v1.2.0" "$(json_field "$DETECT_OUT" release_tag)" "rebase-merged human-overridden version v1.2.0 must be extracted"

"${WORK_REPO}/scripts/release-pr.sh" create-tag --repo "$WORK_REPO" --tag v1.2.0 --target HEAD --remote origin --push >/dev/null
NOTES_V120="$("${WORK_REPO}/scripts/generate-release-notes.sh" v1.2.0)"
assert_contains "$NOTES_V120" "[查看完整对比](https://github.com/qiyuanjuzheng/ai-cleaner/compare/v1.0.0...v1.2.0)" "v1.2.0 notes should compare against v1.0.0"

echo "PASS: 全部 6 组隔离端到端验证通过。"
