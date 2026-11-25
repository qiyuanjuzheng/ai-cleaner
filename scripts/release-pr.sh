#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_PATH="${SCRIPT_DIR}/release-pr-lib.py"

usage() {
  cat <<'EOF'
用法:
  release-pr.sh detect [--repo DIR] [--head REF] [--base REF] [--release-branch NAME]
                       [--pr-json FILE] [--merged-pr-json FILE] [--github-output FILE]

  release-pr.sh plan [--repo DIR] [--head REF] [--release-branch NAME] [--release-branch-ref REF]
                     [--has-open-pr true|false] [--date YYYY-MM-DD]
                     [--output-changelog FILE] [--output-pr-body FILE]

  release-pr.sh prepare-branch [--repo DIR] [--base-ref REF] [--release-branch NAME]
                               [--remote origin] [--has-open-pr true|false] [--date YYYY-MM-DD]
                               [--output-pr-body FILE] [--output-json FILE] [--push]

  release-pr.sh create-tag --tag vX.Y.Z [--repo DIR] [--target HEAD] [--remote origin] [--push]
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "错误: 参数 $1 缺少取值。" >&2
    exit 2
  fi
}

cmd_detect() {
  local repo="$ROOT_DIR"
  local head="HEAD"
  local base=""
  local release_branch="release-pr/main"
  local pr_json=""
  local merged_pr_json=""
  local github_output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) require_value "$@"; repo="$2"; shift ;;
      --head) require_value "$@"; head="$2"; shift ;;
      --base) base="${2:-}"; shift ;;
      --release-branch) require_value "$@"; release_branch="$2"; shift ;;
      --pr-json) pr_json="${2:-}"; shift ;;
      --merged-pr-json) merged_pr_json="${2:-}"; shift ;;
      --github-output) github_output="${2:-}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "错误: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  local py_args=(
    detect
    --repo "$repo"
    --head "$head"
    --release-branch "$release_branch"
  )
  [[ -n "$base" ]] && py_args+=(--base "$base")
  [[ -n "$pr_json" ]] && py_args+=(--pr-json "$pr_json")
  [[ -n "$merged_pr_json" ]] && py_args+=(--merged-pr-json "$merged_pr_json")
  [[ -n "$github_output" ]] && py_args+=(--github-output "$github_output")

  python3 "$LIB_PATH" "${py_args[@]}"
}

cmd_plan() {
  local repo="$ROOT_DIR"
  local head="HEAD"
  local release_branch="release-pr/main"
  local release_branch_ref=""
  local has_open_pr="false"
  local date_str=""
  local output_changelog=""
  local output_pr_body=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) require_value "$@"; repo="$2"; shift ;;
      --head) require_value "$@"; head="$2"; shift ;;
      --release-branch) require_value "$@"; release_branch="$2"; shift ;;
      --release-branch-ref) release_branch_ref="${2:-}"; shift ;;
      --has-open-pr) require_value "$@"; has_open_pr="$2"; shift ;;
      --date) date_str="${2:-}"; shift ;;
      --output-changelog) output_changelog="${2:-}"; shift ;;
      --output-pr-body) output_pr_body="${2:-}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "错误: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  local py_args=(
    plan
    --repo "$repo"
    --head "$head"
    --release-branch "$release_branch"
  )
  [[ -n "$release_branch_ref" ]] && py_args+=(--release-branch-ref "$release_branch_ref")
  [[ "$has_open_pr" == "true" ]] && py_args+=(--has-open-pr)
  [[ -n "$date_str" ]] && py_args+=(--date "$date_str")
  [[ -n "$output_changelog" ]] && py_args+=(--output-changelog "$output_changelog")
  [[ -n "$output_pr_body" ]] && py_args+=(--output-pr-body "$output_pr_body")

  python3 "$LIB_PATH" "${py_args[@]}"
}

cmd_prepare_branch() {
  local repo="$ROOT_DIR"
  local base_ref="HEAD"
  local release_branch="release-pr/main"
  local remote="origin"
  local has_open_pr="false"
  local date_str=""
  local output_pr_body=""
  local output_json=""
  local should_push="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) require_value "$@"; repo="$2"; shift ;;
      --base-ref) require_value "$@"; base_ref="$2"; shift ;;
      --release-branch) require_value "$@"; release_branch="$2"; shift ;;
      --remote) require_value "$@"; remote="$2"; shift ;;
      --has-open-pr) require_value "$@"; has_open_pr="$2"; shift ;;
      --date) date_str="${2:-}"; shift ;;
      --output-pr-body) output_pr_body="${2:-}"; shift ;;
      --output-json) output_json="${2:-}"; shift ;;
      --push) should_push="true" ;;
      -h|--help) usage; exit 0 ;;
      *) echo "错误: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  local release_branch_ref=""
  if [[ "$has_open_pr" == "true" ]]; then
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/${remote}/${release_branch}"; then
      release_branch_ref="refs/remotes/${remote}/${release_branch}"
    elif git -C "$repo" show-ref --verify --quiet "refs/heads/${release_branch}"; then
      release_branch_ref="refs/heads/${release_branch}"
    fi
  fi

  CLEANUP_REPO="$repo"
  CLEANUP_TMP_DIR="$(mktemp -d)"
  CLEANUP_WORKTREE_DIR=""
  cleanup_prepare() {
    if [[ -n "${CLEANUP_WORKTREE_DIR:-}" && -d "${CLEANUP_WORKTREE_DIR}" ]]; then
      git -C "${CLEANUP_REPO}" worktree remove --force "${CLEANUP_WORKTREE_DIR}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${CLEANUP_TMP_DIR:-}" && -d "${CLEANUP_TMP_DIR}" ]]; then
      rm -rf "${CLEANUP_TMP_DIR}"
    fi
  }
  trap cleanup_prepare EXIT

  local tmp_dir="$CLEANUP_TMP_DIR"
  local changelog_tmp="${tmp_dir}/CHANGELOG.md"
  local plan_tmp="${tmp_dir}/plan.json"
  local commit_msg_tmp="${tmp_dir}/commit-msg.txt"
  local body_target="${output_pr_body:-${tmp_dir}/pr-body.md}"

  local py_args=(
    plan
    --repo "$repo"
    --head "$base_ref"
    --release-branch "$release_branch"
    --output-changelog "$changelog_tmp"
    --output-pr-body "$body_target"
  )
  [[ -n "$release_branch_ref" ]] && py_args+=(--release-branch-ref "$release_branch_ref")
  [[ "$has_open_pr" == "true" ]] && py_args+=(--has-open-pr)
  [[ -n "$date_str" ]] && py_args+=(--date "$date_str")

  python3 "$LIB_PATH" "${py_args[@]}" > "$plan_tmp"

  if [[ -n "$output_json" ]]; then
    cp "$plan_tmp" "$output_json"
  fi

  local action
  action="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["action"])' "$plan_tmp")"
  if [[ "$action" != "create_or_update" ]]; then
    cat "$plan_tmp"
    return 0
  fi

  python3 -c 'import json, sys; open(sys.argv[2], "w", encoding="utf-8").write(json.load(open(sys.argv[1], encoding="utf-8"))["commit_message"])' "$plan_tmp" "$commit_msg_tmp"

  local base_sha
  base_sha="$(git -C "$repo" rev-parse "${base_ref}^{commit}")"
  CLEANUP_WORKTREE_DIR="${tmp_dir}/worktree"
  git -C "$repo" worktree add --quiet --detach "$CLEANUP_WORKTREE_DIR" "$base_sha"
  cp "$changelog_tmp" "${CLEANUP_WORKTREE_DIR}/CHANGELOG.md"
  git -C "$CLEANUP_WORKTREE_DIR" add CHANGELOG.md
  if git -C "$CLEANUP_WORKTREE_DIR" diff --cached --quiet; then
    git -C "$repo" worktree remove --force "$CLEANUP_WORKTREE_DIR" >/dev/null 2>&1
    CLEANUP_WORKTREE_DIR=""
    python3 -c 'import json, sys
p = sys.argv[1]
data = json.load(open(p, encoding="utf-8"))
data["action"] = "keep"
data["reason"] = "changelog_identical_to_base"
json.dump(data, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
' "$plan_tmp"
    if [[ -n "$output_json" ]]; then
      cp "$plan_tmp" "$output_json"
    fi
    cat "$plan_tmp"
    return 0
  fi
  git -C "$CLEANUP_WORKTREE_DIR" commit --quiet -F "$commit_msg_tmp"

  local new_commit_sha
  new_commit_sha="$(git -C "$CLEANUP_WORKTREE_DIR" rev-parse HEAD)"
  git -C "$repo" worktree remove --force "$CLEANUP_WORKTREE_DIR" >/dev/null 2>&1
  CLEANUP_WORKTREE_DIR=""

  git -C "$repo" branch -f "$release_branch" "$new_commit_sha"

  if [[ "$should_push" == "true" ]]; then
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/${remote}/${release_branch}"; then
      local expected_oid
      expected_oid="$(git -C "$repo" rev-parse "refs/remotes/${remote}/${release_branch}")"
      git -C "$repo" push \
        --force-with-lease="refs/heads/${release_branch}:${expected_oid}" \
        "$remote" \
        "refs/heads/${release_branch}:refs/heads/${release_branch}"
    else
      git -C "$repo" push \
        "$remote" \
        "refs/heads/${release_branch}:refs/heads/${release_branch}"
    fi
  fi

  cat "$plan_tmp"
}

cmd_create_tag() {
  local repo="$ROOT_DIR"
  local tag=""
  local target="HEAD"
  local remote="origin"
  local should_push="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) require_value "$@"; repo="$2"; shift ;;
      --tag) require_value "$@"; tag="$2"; shift ;;
      --target) require_value "$@"; target="$2"; shift ;;
      --remote) require_value "$@"; remote="$2"; shift ;;
      --push) should_push="true" ;;
      -h|--help) usage; exit 0 ;;
      *) echo "错误: 未知参数 $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done

  if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误: 标签必须符合 vX.Y.Z 格式，收到: '${tag}'" >&2
    exit 2
  fi

  local target_sha
  target_sha="$(git -C "$repo" rev-parse "${target}^{commit}")"

  # 校验目标提交的 CHANGELOG.md 已包含该版本说明，避免打空标签。
  python3 "$LIB_PATH" check-changelog --repo "$repo" --tag "$tag" --ref "$target_sha"

  if [[ "$should_push" == "true" ]] && ! git -C "$repo" show-ref --verify --quiet "refs/tags/${tag}"; then
    if git -C "$repo" ls-remote --exit-code --tags "$remote" "refs/tags/${tag}" >/dev/null 2>&1; then
      git -C "$repo" fetch --quiet "$remote" "refs/tags/${tag}:refs/tags/${tag}"
    fi
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/tags/${tag}"; then
    local existing_sha
    existing_sha="$(git -C "$repo" rev-list -n 1 "refs/tags/${tag}")"
    if [[ "$existing_sha" != "$target_sha" ]]; then
      echo "错误: 标签 ${tag} 已存在且指向提交 ${existing_sha}（当前目标为 ${target_sha}），拒绝覆盖。" >&2
      exit 1
    fi
    echo "标签 ${tag} 已指向目标提交 ${target_sha}，按幂等跳过重建。"
  else
    git -C "$repo" tag -a "$tag" "$target_sha" -m "AI Cleaner ${tag}"
    echo "已创建带注释标签 ${tag} -> ${target_sha}"
  fi

  if [[ "$should_push" == "true" ]]; then
    if git -C "$repo" ls-remote --exit-code --tags "$remote" "refs/tags/${tag}" >/dev/null 2>&1; then
      echo "远端 ${remote} 已存在标签 ${tag}，无需重复推送。"
    else
      git -C "$repo" push "$remote" "refs/tags/${tag}"
      echo "已推送标签 ${tag} 至 ${remote}"
    fi
  fi
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

subcommand="$1"
shift
case "$subcommand" in
  detect) cmd_detect "$@" ;;
  plan) cmd_plan "$@" ;;
  prepare-branch) cmd_prepare_branch "$@" ;;
  create-tag) cmd_create_tag "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "错误: 未知子命令 '${subcommand}'" >&2; usage >&2; exit 2 ;;
esac
