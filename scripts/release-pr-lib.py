#!/usr/bin/env python3
"""Release PR planning, CHANGELOG generation, and merge detection for AI Cleaner.

Uses Python 3 standard library only so it behaves identically on macOS and Linux.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
CHANGELOG_HEADING_RE = re.compile(
    r"^##\s+\[(v?\d+\.\d+\.\d+)\](?:\s*-\s*([^\s].*?))?\s*$"
)
UNRELEASED_HEADING_RE = re.compile(r"^##\s+\[Unreleased\]\s*$", re.IGNORECASE)
PR_MERGE_SUBJECT_RE = re.compile(r"^Merge pull request #(\d+) from ([^\s]+)")
BRANCH_MERGE_SUBJECT_RE = re.compile(
    r"^Merge (?:remote-tracking )?branch '([^']+)'"
)
TRAILING_PR_RE = re.compile(r"\(#(\d+)\)\s*$")
TASK_PREFIX_RE = re.compile(r"^(?:\[?[A-Z]{2,10}-\d+\]?\s*[:：\-]?\s*)+")
CONV_HEADER_RE = re.compile(
    r"^(?P<type>[a-zA-Z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?:\s*(?P<desc>.+)$"
)
SKIP_RELEASE_RE = re.compile(r"\[(?:skip release|release skip)\]", re.IGNORECASE)
OVERRIDE_BUMP_RE = re.compile(
    r"\[(?:release|bump):(major|minor|patch)\]", re.IGNORECASE
)
RELEASE_TITLE_RE = re.compile(r"^chore\(release\):", re.IGNORECASE)
TRAILER_LINE_RE = re.compile(r"^([A-Za-z][A-Za-z0-9-]*):\s*(.+?)\s*$")

IGNORED_DIR_PREFIXES = (
    "site/",
    "docs/",
    ".github/",
)
IGNORED_EXACT_PATHS = {
    ".gitignore",
    ".gitattributes",
    ".editorconfig",
    "scripts/release-pr.sh",
    "scripts/release-pr-lib.py",
    "scripts/test-release-pr.sh",
}

BUMP_ORDER = {"none": 0, "patch": 1, "minor": 2, "major": 3}

SECTION_KEYS = ("breaking", "added", "fixed", "changed")
SECTION_TITLES = {
    "breaking": "破坏性变更",
    "added": "新增",
    "fixed": "修复",
    "changed": "优化与变更",
}
TITLE_TO_SECTION_KEY = {v: k for k, v in SECTION_TITLES.items()}

CHINESE_BREAKING_RE = re.compile(r"^(?:破坏性变更|不兼容变更|重大变更)")
CHINESE_FEAT_RE = re.compile(r"^(?:新增|支持|添加|增加|引入|接入|实现|提供|上线)")
ENGLISH_FEAT_RE = re.compile(
    r"^(?:add|added|support|supports|introduce|introduces|implement|implements|enable|enables)\b",
    re.IGNORECASE,
)
CHINESE_FIX_RE = re.compile(r"^(?:修复|修正|解决|恢复|回退|防止|避免)")
ENGLISH_FIX_RE = re.compile(
    r"^(?:fix|fixes|fixed|bugfix|hotfix|resolve|resolves|restore|restores|revert|reverts|prevent|prevents)\b",
    re.IGNORECASE,
)


@dataclass
class ChangeEntry:
    sha: str
    title: str
    bullet: str
    bump: str
    section: str
    pr_number: str | None = None


@dataclass
class ReleaseBranchState:
    exists: bool = False
    base_tag: str | None = None
    head_sha: str | None = None
    auto_version: str | None = None
    pinned_version: str | None = None
    human_edited: bool = False
    changelog_text: str | None = None
    current_version: str | None = None


def run_git(repo: Path, args: list[str], check: bool = True) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=str(repo),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()}"
        )
    return proc.stdout


def git_ref_exists(repo: Path, ref: str) -> bool:
    if not ref or re.fullmatch(r"0+", ref):
        return False
    proc = subprocess.run(
        ["git", "cat-file", "-e", f"{ref}^{{commit}}"],
        cwd=str(repo),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def parse_semver(tag: str) -> tuple[int, int, int]:
    m = SEMVER_RE.match(tag.strip())
    if not m:
        raise ValueError(f"Invalid semantic version: {tag!r}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def normalize_tag(tag: str) -> str:
    major, minor, patch = parse_semver(tag)
    return f"v{major}.{minor}.{patch}"


def bump_semver(tag: str | None, bump: str) -> str:
    if not tag:
        return "v0.1.0"
    major, minor, patch = parse_semver(tag)
    if bump == "major":
        return f"v{major + 1}.0.0"
    if bump == "minor":
        return f"v{major}.{minor + 1}.0"
    if bump == "patch":
        return f"v{major}.{minor}.{patch + 1}"
    return f"v{major}.{minor}.{patch}"


def max_bump(a: str, b: str) -> str:
    return a if BUMP_ORDER[a] >= BUMP_ORDER[b] else b


def is_ignored_path(path: str) -> bool:
    normalized = path.strip().lstrip("./")
    if not normalized:
        return True
    if normalized.startswith(IGNORED_DIR_PREFIXES):
        return True
    if normalized in IGNORED_EXACT_PATHS:
        return True
    if "/" not in normalized:
        lower = normalized.lower()
        if lower.endswith(".md"):
            return True
        if lower == "license" or lower.startswith("license."):
            return True
    return False


def get_commit_parents(repo: Path, sha: str) -> list[str]:
    out = run_git(repo, ["rev-list", "--parents", "-n", "1", sha]).strip()
    parts = out.split()
    return parts[1:] if len(parts) > 1 else []


def get_commit_subject_and_body(repo: Path, sha: str) -> tuple[str, str]:
    raw = run_git(repo, ["show", "-s", "--format=%s%x1f%b", sha])
    if "\x1f" in raw:
        subject, body = raw.split("\x1f", 1)
    else:
        subject, body = raw, ""
    return subject.strip(), body.strip()


def get_commit_changed_files(repo: Path, sha: str, parents: list[str]) -> list[str]:
    if parents:
        out = run_git(repo, ["diff", "--name-only", parents[0], sha])
    else:
        out = run_git(
            repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", "--root", sha]
        )
    return [line.strip() for line in out.splitlines() if line.strip()]


def get_file_at_ref(repo: Path, ref: str, path: str) -> str | None:
    proc = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        cwd=str(repo),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def extract_trailers(body: str) -> dict[str, str]:
    trailers: dict[str, str] = {}
    for line in body.splitlines():
        m = TRAILER_LINE_RE.match(line.strip())
        if m:
            trailers[m.group(1)] = m.group(2).strip()
    return trailers


def is_release_pr_commit(subject: str, body: str, release_branch: str) -> bool:
    if RELEASE_TITLE_RE.match(subject.strip()):
        return True
    m_pr = PR_MERGE_SUBJECT_RE.match(subject.strip())
    if m_pr:
        branch_part = m_pr.group(2)
        if branch_part.endswith(f"/{release_branch}") or branch_part == release_branch:
            return True
    m_br = BRANCH_MERGE_SUBJECT_RE.match(subject.strip())
    if m_br:
        br = m_br.group(1)
        if br == release_branch or br.endswith(f"/{release_branch}"):
            return True
    trailers = extract_trailers(body)
    if trailers.get("Release-PR", "").lower() == "true":
        return True
    return False


def first_meaningful_body_line(body: str) -> str | None:
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#") or line.startswith("Conflicts:"):
            continue
        if re.match(
            r"^(?:Co-authored-by|Signed-off-by|Reviewed-by|Release-[A-Za-z-]+):",
            line,
            re.IGNORECASE,
        ):
            continue
        return line
    return None


def clean_bullet_text(title: str, pr_number: str | None) -> str:
    text = OVERRIDE_BUMP_RE.sub("", title).strip()
    text = SKIP_RELEASE_RE.sub("", text).strip()
    text = re.sub(r"\s{2,}", " ", text)

    # Strip redundant Conventional Commit prefix while keeping scope when present.
    m_conv = CONV_HEADER_RE.match(text)
    if m_conv:
        scope = m_conv.group("scope")
        desc = m_conv.group("desc").strip()
        if scope:
            text = f"**{scope}**：{desc}"
        else:
            text = desc

    if pr_number and not re.search(rf"\(#{re.escape(pr_number)}\)", text):
        text = f"{text} (#{pr_number})"
    return text


def classify_change(
    title: str, full_text: str, inner_subjects: list[str], inner_texts: list[str]
) -> tuple[str, str]:
    combined_texts = [title, full_text, *inner_texts]
    combined_all = "\n".join(t for t in combined_texts if t)

    # 1. Explicit bump override tag ([release:major|minor|patch] or [bump:...])
    explicit_bumps = [
        m.group(1).lower() for m in OVERRIDE_BUMP_RE.finditer(combined_all)
    ]
    explicit_bump: str | None = None
    for b in explicit_bumps:
        explicit_bump = b if explicit_bump is None else max_bump(explicit_bump, b)

    stripped_title = OVERRIDE_BUMP_RE.sub("", title).strip()
    norm_title = TASK_PREFIX_RE.sub("", stripped_title).strip()

    # Check breaking markers
    is_breaking = False
    if re.search(r"(?:^|\n)BREAKING[ -]CHANGE:", combined_all):
        is_breaking = True
    m_conv = CONV_HEADER_RE.match(norm_title)
    if m_conv and m_conv.group("bang"):
        is_breaking = True
    if CHINESE_BREAKING_RE.match(norm_title):
        is_breaking = True
    for sub in inner_subjects:
        m_inner = CONV_HEADER_RE.match(TASK_PREFIX_RE.sub("", sub.strip()).strip())
        if m_inner and m_inner.group("bang"):
            is_breaking = True

    if explicit_bump == "major" or (explicit_bump is None and is_breaking):
        return "major", "breaking"

    # Determine semantic category from title and inner commits
    is_feat = False
    is_fix = False
    if m_conv:
        ctype = m_conv.group("type").lower()
        if ctype == "feat":
            is_feat = True
        elif ctype in ("fix", "bugfix", "hotfix"):
            is_fix = True
    else:
        if CHINESE_FEAT_RE.match(norm_title) or ENGLISH_FEAT_RE.match(norm_title):
            is_feat = True
        elif CHINESE_FIX_RE.match(norm_title) or ENGLISH_FIX_RE.match(norm_title):
            is_fix = True

    if not is_feat and not is_fix:
        for sub in inner_subjects:
            m_inner = CONV_HEADER_RE.match(TASK_PREFIX_RE.sub("", sub.strip()).strip())
            if m_inner:
                ctype = m_inner.group("type").lower()
                if ctype == "feat":
                    is_feat = True
                elif ctype in ("fix", "bugfix", "hotfix"):
                    is_fix = True

    if explicit_bump == "minor":
        return "minor", "added"
    if explicit_bump == "patch":
        return "patch", ("fixed" if is_fix else "changed")

    if is_feat:
        return "minor", "added"
    if is_fix:
        return "patch", "fixed"
    return "patch", "changed"


def get_latest_semver_tag(repo: Path, ref: str) -> str | None:
    out = run_git(repo, ["tag", "--merged", ref, "--sort=-version:refname"])
    for line in out.splitlines():
        tag = line.strip()
        if re.fullmatch(r"v\d+\.\d+\.\d+", tag):
            return tag
    return None


def collect_releasable_entries(
    repo: Path, base_ref: str | None, head_ref: str, release_branch: str
) -> list[ChangeEntry]:
    rev_range = f"{base_ref}..{head_ref}" if base_ref else head_ref
    out = run_git(repo, ["rev-list", "--first-parent", "--reverse", rev_range])
    shas = [line.strip() for line in out.splitlines() if line.strip()]

    entries: list[ChangeEntry] = []
    for sha in shas:
        parents = get_commit_parents(repo, sha)
        changed_files = get_commit_changed_files(repo, sha, parents)
        if not changed_files:
            continue

        subject, body = get_commit_subject_and_body(repo, sha)
        if is_release_pr_commit(subject, body, release_branch):
            continue

        if all(is_ignored_path(path) for path in changed_files):
            continue

        full_text = f"{subject}\n{body}".strip()
        if SKIP_RELEASE_RE.search(full_text):
            continue

        m_pr = PR_MERGE_SUBJECT_RE.match(subject)
        m_br = BRANCH_MERGE_SUBJECT_RE.match(subject)

        if len(parents) >= 2 and m_pr:
            pr_num = m_pr.group(1)
            inner_shas = [
                s.strip()
                for s in run_git(
                    repo, ["rev-list", "--no-merges", "--reverse", f"{parents[0]}..{parents[1]}"]
                ).splitlines()
                if s.strip()
            ]
            inner_subjects: list[str] = []
            inner_texts: list[str] = []
            for isha in inner_shas:
                isub, ibody = get_commit_subject_and_body(repo, isha)
                inner_subjects.append(isub)
                inner_texts.append(f"{isub}\n{ibody}".strip())

            if inner_texts and all(SKIP_RELEASE_RE.search(t) for t in inner_texts):
                continue

            title = first_meaningful_body_line(body)
            if not title:
                p2_sub, _ = get_commit_subject_and_body(repo, parents[1])
                title = p2_sub or subject

            bump, section = classify_change(title, full_text, inner_subjects, inner_texts)
            bullet = clean_bullet_text(title, pr_num)
            entries.append(
                ChangeEntry(
                    sha=sha,
                    title=title,
                    bullet=bullet,
                    bump=bump,
                    section=section,
                    pr_number=pr_num,
                )
            )
            continue

        if len(parents) >= 2 and m_br:
            body_title = first_meaningful_body_line(body)
            inner_shas = [
                s.strip()
                for s in run_git(
                    repo, ["rev-list", "--no-merges", "--reverse", f"{parents[0]}..{parents[1]}"]
                ).splitlines()
                if s.strip()
            ]
            if body_title:
                inner_subjects = []
                inner_texts = []
                for isha in inner_shas:
                    isub, ibody = get_commit_subject_and_body(repo, isha)
                    inner_subjects.append(isub)
                    inner_texts.append(f"{isub}\n{ibody}".strip())
                if inner_texts and all(SKIP_RELEASE_RE.search(t) for t in inner_texts):
                    continue
                m_trailing = TRAILING_PR_RE.search(body_title)
                pr_num = m_trailing.group(1) if m_trailing else None
                bump, section = classify_change(
                    body_title, full_text, inner_subjects, inner_texts
                )
                bullet = clean_bullet_text(body_title, pr_num)
                entries.append(
                    ChangeEntry(
                        sha=sha,
                        title=body_title,
                        bullet=bullet,
                        bump=bump,
                        section=section,
                        pr_number=pr_num,
                    )
                )
            else:
                for isha in inner_shas:
                    iparents = get_commit_parents(repo, isha)
                    ifiles = get_commit_changed_files(repo, isha, iparents)
                    if not ifiles or all(is_ignored_path(p) for p in ifiles):
                        continue
                    isub, ibody = get_commit_subject_and_body(repo, isha)
                    if is_release_pr_commit(isub, ibody, release_branch):
                        continue
                    ifull = f"{isub}\n{ibody}".strip()
                    if SKIP_RELEASE_RE.search(ifull):
                        continue
                    m_trailing = TRAILING_PR_RE.search(isub)
                    pr_num = m_trailing.group(1) if m_trailing else None
                    bump, section = classify_change(isub, ifull, [], [])
                    bullet = clean_bullet_text(isub, pr_num)
                    entries.append(
                        ChangeEntry(
                            sha=isha,
                            title=isub,
                            bullet=bullet,
                            bump=bump,
                            section=section,
                            pr_number=pr_num,
                        )
                    )
            continue

        # Single-parent commit (direct commit, squash merge, or rebase merge)
        m_trailing = TRAILING_PR_RE.search(subject)
        pr_num = m_trailing.group(1) if m_trailing else None
        bump, section = classify_change(subject, full_text, [], [])
        bullet = clean_bullet_text(subject, pr_num)
        entries.append(
            ChangeEntry(
                sha=sha,
                title=subject,
                bullet=bullet,
                bump=bump,
                section=section,
                pr_number=pr_num,
            )
        )

    return entries


def extract_changelog_versions(changelog_text: str) -> list[str]:
    versions: list[str] = []
    for line in changelog_text.splitlines():
        m = CHANGELOG_HEADING_RE.match(line.strip())
        if m:
            versions.append(normalize_tag(m.group(1)))
    return versions


def extract_changelog_section(changelog_text: str, tag: str) -> str | None:
    target = normalize_tag(tag)
    lines = changelog_text.splitlines()
    collecting = False
    collected: list[str] = []
    for line in lines:
        if line.startswith("## "):
            if collecting:
                break
            m = CHANGELOG_HEADING_RE.match(line.strip())
            if m and normalize_tag(m.group(1)) == target:
                collecting = True
            continue
        if collecting:
            collected.append(line)
    if not collecting:
        return None
    text = "\n".join(collected).strip()
    return text if text else None


def split_changelog_parts(changelog_text: str) -> tuple[str, str, str]:
    """Split CHANGELOG.md into (prefix_with_unreleased, unreleased_body, first_release_onwards)."""
    lines = changelog_text.splitlines()
    unreleased_idx = None
    first_release_idx = None
    for idx, line in enumerate(lines):
        if unreleased_idx is None and UNRELEASED_HEADING_RE.match(line.strip()):
            unreleased_idx = idx
            continue
        if first_release_idx is None and CHANGELOG_HEADING_RE.match(line.strip()):
            first_release_idx = idx
            break

    if unreleased_idx is not None:
        prefix = "\n".join(lines[: unreleased_idx + 1]).rstrip()
        body_end = first_release_idx if first_release_idx is not None else len(lines)
        unreleased_body = "\n".join(lines[unreleased_idx + 1 : body_end]).strip()
        tail = (
            "\n".join(lines[first_release_idx:]).strip()
            if first_release_idx is not None
            else ""
        )
        return prefix, unreleased_body, tail

    if first_release_idx is not None:
        before = "\n".join(lines[:first_release_idx]).strip()
        prefix = f"{before}\n\n## [Unreleased]" if before else "## [Unreleased]"
        tail = "\n".join(lines[first_release_idx:]).strip()
        return prefix, "", tail

    existing = changelog_text.strip()
    return "## [Unreleased]", existing, ""


def extract_top_release_section(changelog_text: str) -> tuple[str | None, str | None, str]:
    """Return (top_tag, top_date, section_body) for the first ## [vX.Y.Z] section."""
    lines = changelog_text.splitlines()
    start_idx = None
    end_idx = len(lines)
    top_tag = None
    top_date = None
    for idx, line in enumerate(lines):
        if line.startswith("## "):
            if start_idx is not None:
                end_idx = idx
                break
            m = CHANGELOG_HEADING_RE.match(line.strip())
            if m:
                start_idx = idx
                top_tag = normalize_tag(m.group(1))
                top_date = m.group(2).strip() if m.group(2) else None
    if start_idx is None:
        return None, None, ""
    body = "\n".join(lines[start_idx + 1 : end_idx]).strip()
    return top_tag, top_date, body


def render_entries_markdown(
    entries: list[ChangeEntry], extra_unreleased_body: str = ""
) -> str:
    grouped: dict[str, list[str]] = {key: [] for key in SECTION_KEYS}
    seen_bullets: set[str] = set()
    # Display newest first within each category.
    for entry in reversed(entries):
        if entry.bullet in seen_bullets:
            continue
        seen_bullets.add(entry.bullet)
        grouped[entry.section].append(entry.bullet)

    blocks: list[str] = []
    if extra_unreleased_body.strip():
        blocks.append(extra_unreleased_body.strip())

    for key in SECTION_KEYS:
        bullets = grouped[key]
        if not bullets:
            continue
        lines = [f"### {SECTION_TITLES[key]}", ""]
        lines.extend(f"- {item}" for item in bullets)
        blocks.append("\n".join(lines))

    return "\n\n".join(blocks).strip()


def merge_new_entries_into_human_section(
    existing_body: str, new_entries: list[ChangeEntry]
) -> str:
    """Append newly merged entries into a human-edited section without touching existing prose."""
    if not new_entries:
        return existing_body.strip()

    # Deduplicate against existing PR numbers or exact bullet lines.
    existing_pr_nums = set(re.findall(r"\(#(\d+)\)", existing_body))
    existing_lines = {line.strip() for line in existing_body.splitlines()}

    grouped: dict[str, list[str]] = {key: [] for key in SECTION_KEYS}
    for entry in reversed(new_entries):
        if entry.pr_number and entry.pr_number in existing_pr_nums:
            continue
        bullet_line = f"- {entry.bullet}"
        if bullet_line in existing_lines:
            continue
        if entry.bullet in grouped[entry.section]:
            continue
        grouped[entry.section].append(entry.bullet)

    lines = existing_body.strip().splitlines() if existing_body.strip() else []

    # First insert into subsections that already exist.
    remaining: dict[str, list[str]] = {}
    for key in SECTION_KEYS:
        bullets = grouped[key]
        if not bullets:
            continue
        heading = f"### {SECTION_TITLES[key]}"
        heading_idx = None
        for idx, line in enumerate(lines):
            if line.strip() == heading:
                heading_idx = idx
                break
        if heading_idx is None:
            remaining[key] = bullets
            continue

        insert_pos = heading_idx + 1
        while insert_pos < len(lines) and lines[insert_pos].strip() == "":
            insert_pos += 1
        to_insert = [f"- {item}" for item in bullets]
        if insert_pos == heading_idx + 1:
            to_insert = [""] + to_insert
        lines[insert_pos:insert_pos] = to_insert

    # Append missing subsections at the end in canonical order.
    result = "\n".join(lines).rstrip()
    extra_blocks: list[str] = []
    for key in SECTION_KEYS:
        bullets = remaining.get(key)
        if not bullets:
            continue
        block_lines = [f"### {SECTION_TITLES[key]}", ""]
        block_lines.extend(f"- {item}" for item in bullets)
        extra_blocks.append("\n".join(block_lines))

    if extra_blocks:
        if result:
            result = f"{result}\n\n" + "\n\n".join(extra_blocks)
        else:
            result = "\n\n".join(extra_blocks)
    return result.strip()


def compose_changelog(
    base_changelog: str, version_tag: str, release_date: str, section_body: str
) -> str:
    prefix, _, tail = split_changelog_parts(base_changelog)
    parts = [prefix, f"## [{version_tag}] - {release_date}", section_body.strip()]
    if tail:
        parts.append(tail)
    return "\n\n".join(part for part in parts if part).rstrip() + "\n"


def inspect_release_branch(
    repo: Path, release_branch_ref: str, current_last_tag: str | None
) -> ReleaseBranchState:
    state = ReleaseBranchState()
    if not git_ref_exists(repo, release_branch_ref):
        return state

    state.exists = True
    tip_subject, tip_body = get_commit_subject_and_body(repo, release_branch_ref)
    tip_trailers = extract_trailers(tip_body)

    # Walk first-parent history of release branch (bounded) to locate last automated commit.
    log_out = run_git(repo, ["rev-list", "--first-parent", "-n", "30", release_branch_ref])
    shas = [s.strip() for s in log_out.splitlines() if s.strip()]

    bot_trailers: dict[str, str] | None = None
    bot_is_tip = False
    for idx, sha in enumerate(shas):
        _, body = get_commit_subject_and_body(repo, sha)
        trailers = extract_trailers(body)
        if trailers.get("Release-PR", "").lower() == "true" and trailers.get(
            "Release-Head-SHA"
        ):
            bot_trailers = trailers
            bot_is_tip = idx == 0
            break

    if not bot_trailers:
        return ReleaseBranchState(exists=False)

    branch_base_tag = bot_trailers.get("Release-Base-Tag")
    if branch_base_tag == "none":
        branch_base_tag = None

    if branch_base_tag != current_last_tag:
        # Stale branch from a previous release cycle.
        return ReleaseBranchState(exists=False)

    state.base_tag = branch_base_tag
    state.head_sha = bot_trailers.get("Release-Head-SHA")
    state.auto_version = bot_trailers.get("Release-Auto-Version")
    state.pinned_version = bot_trailers.get("Release-Pinned-Version")
    state.changelog_text = get_file_at_ref(repo, release_branch_ref, "CHANGELOG.md")

    if state.changelog_text:
        top_tag, _, _ = extract_top_release_section(state.changelog_text)
        state.current_version = top_tag

    was_human_edited = bot_trailers.get("Release-Human-Edited", "").lower() == "true"
    state.human_edited = (not bot_is_tip) or was_human_edited

    # If a human pushed a commit on top of the bot commit, treat the tip CHANGELOG heading
    # as authoritative for whether the version is pinned or back on auto-version.
    if not bot_is_tip and state.current_version:
        if state.auto_version and state.current_version != state.auto_version:
            state.pinned_version = state.current_version
        else:
            state.pinned_version = None

    return state


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    if not git_ref_exists(repo, ancestor) or not git_ref_exists(repo, descendant):
        return False
    proc = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=str(repo),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def range_touches_file(repo: Path, base_ref: str, head_ref: str, filepath: str) -> bool:
    out = run_git(repo, ["diff", "--name-only", base_ref, head_ref])
    return any(line.strip() == filepath for line in out.splitlines())


def build_pr_body(
    next_tag: str,
    last_tag: str | None,
    auto_tag: str,
    bump: str,
    section_body: str,
    commit_count: int,
    human_edited: bool,
    pinned_version: str | None,
) -> str:
    bump_label = {
        "major": "主版本升级（Major）",
        "minor": "次版本升级（Minor，含新增功能）",
        "patch": "修订版本升级（Patch，修复与优化）",
    }.get(bump, bump)

    lines = [
        f"本 PR 由 Release PR 自动化工作流维护，用于累计自 `{last_tag or '初始提交'}` 以来的客户端与应用变更。",
        "",
        f"- **目标版本**：`{next_tag}`",
        f"- **基准标签**：`{last_tag or '无（首个版本）'}`",
        f"- **版本推算**：{bump_label}（自动推算 `{auto_tag}`）",
        f"- **累计纳入提交**：{commit_count} 条",
    ]
    if pinned_version:
        lines.append(f"- **人工指定版本**：已保留你在 `CHANGELOG.md` 中修改的版本号 `{pinned_version}`")
    elif human_edited:
        lines.append("- **人工润色保护**：已保留你此前在 `CHANGELOG.md` 中的手动编辑，仅追加新增提交")

    lines.extend(
        [
            "",
            "## 本次发布说明预览（来自 `CHANGELOG.md`）",
            "",
            section_body.strip(),
            "",
            "## 发版前审阅与操作说明",
            "",
            "1. **润色更新日志**：可直接在本 PR 中编辑 `CHANGELOG.md` 调整中文措辞；后续若 `main` 再合入新 PR，工作流会保留你的手动修改并仅追加新变更。",
            f"2. **手动调整版本号**：如需修改发布版本（例如将 `{next_tag}` 改为其他语义化版本号），直接修改本 PR 中 `CHANGELOG.md` 顶部的 `## [{next_tag}] - YYYY-MM-DD` 标题即可，合并后将严格以该版本号为准。",
            "3. **合并即自动发版**：本 PR 创建与更新期间**不会**运行耗时的 macOS Universal 编译打包；点击合并后，流水线会在当前 `main` 提交自动创建带注释标签、编译 Universal `.dmg` / `.zip` 与 `SHA256SUMS.txt` 并发布 GitHub Release。",
        ]
    )
    return "\n".join(lines) + "\n"


def cmd_plan(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    head_sha = run_git(repo, ["rev-parse", args.head]).strip()
    release_date = args.date or dt.date.today().isoformat()
    release_branch = args.release_branch
    release_branch_ref = args.release_branch_ref

    last_tag = get_latest_semver_tag(repo, head_sha)
    all_entries = collect_releasable_entries(repo, last_tag, head_sha, release_branch)

    if not all_entries:
        result = {
            "action": "skip",
            "reason": "no_releasable_changes",
            "last_tag": last_tag or "",
            "next_tag": "",
            "auto_tag": "",
            "bump": "none",
            "commit_count": 0,
            "human_edited": False,
            "pinned_version": "",
            "pr_title": "",
            "commit_message": "",
            "head_sha": head_sha,
        }
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    overall_bump = "none"
    for entry in all_entries:
        overall_bump = max_bump(overall_bump, entry.bump)
    auto_tag = bump_semver(last_tag, overall_bump)

    base_changelog = get_file_at_ref(repo, head_sha, "CHANGELOG.md") or "## [Unreleased]\n"
    _, unreleased_body, _ = split_changelog_parts(base_changelog)

    branch_state = (
        inspect_release_branch(repo, release_branch_ref, last_tag)
        if args.has_open_pr and release_branch_ref
        else ReleaseBranchState(exists=False)
    )

    human_edited = False
    pinned_version: str | None = None
    next_tag = auto_tag
    section_body = ""
    reason = "updated_from_main"

    if branch_state.exists and branch_state.head_sha:
        if branch_state.head_sha == head_sha:
            # Exact same main SHA already reflected on the open Release PR.
            result = {
                "action": "keep",
                "reason": "already_up_to_date",
                "last_tag": last_tag or "",
                "next_tag": branch_state.current_version or auto_tag,
                "auto_tag": auto_tag,
                "bump": overall_bump,
                "commit_count": len(all_entries),
                "human_edited": branch_state.human_edited,
                "pinned_version": branch_state.pinned_version or "",
                "pr_title": f"chore(release): 发布 {branch_state.current_version or auto_tag}",
                "commit_message": "",
                "head_sha": head_sha,
            }
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0

        if is_ancestor(repo, branch_state.head_sha, head_sha):
            delta_entries = collect_releasable_entries(
                repo, branch_state.head_sha, head_sha, release_branch
            )
            changelog_touched_on_main = range_touches_file(
                repo, branch_state.head_sha, head_sha, "CHANGELOG.md"
            )
            if not delta_entries and not changelog_touched_on_main:
                result = {
                    "action": "keep",
                    "reason": "only_non_release_changes_since_last_sync",
                    "last_tag": last_tag or "",
                    "next_tag": branch_state.current_version or auto_tag,
                    "auto_tag": auto_tag,
                    "bump": overall_bump,
                    "commit_count": len(all_entries),
                    "human_edited": branch_state.human_edited,
                    "pinned_version": branch_state.pinned_version or "",
                    "pr_title": f"chore(release): 发布 {branch_state.current_version or auto_tag}",
                    "commit_message": "",
                    "head_sha": head_sha,
                }
                print(json.dumps(result, ensure_ascii=False, indent=2))
                return 0

            if branch_state.human_edited and branch_state.changelog_text:
                human_edited = True
                pinned_version = branch_state.pinned_version
                if pinned_version:
                    next_tag = pinned_version
                elif branch_state.current_version and parse_semver(
                    branch_state.current_version
                ) >= parse_semver(auto_tag):
                    next_tag = branch_state.current_version
                else:
                    next_tag = auto_tag
                _, _, existing_body = extract_top_release_section(
                    branch_state.changelog_text
                )
                section_body = merge_new_entries_into_human_section(
                    existing_body, delta_entries
                )
                reason = "appended_preserving_human_edits"

    if not section_body:
        section_body = render_entries_markdown(all_entries, unreleased_body)

    new_changelog = compose_changelog(
        base_changelog, next_tag, release_date, section_body
    )
    pr_title = f"chore(release): 发布 {next_tag}"
    pr_body = build_pr_body(
        next_tag=next_tag,
        last_tag=last_tag,
        auto_tag=auto_tag,
        bump=overall_bump,
        section_body=section_body,
        commit_count=len(all_entries),
        human_edited=human_edited,
        pinned_version=pinned_version,
    )

    commit_lines = [
        f"chore(release): 准备发布 {next_tag}",
        "",
        "Release-PR: true",
        f"Release-Base-Tag: {last_tag or 'none'}",
        f"Release-Head-SHA: {head_sha}",
        f"Release-Auto-Version: {auto_tag}",
    ]
    if human_edited:
        commit_lines.append("Release-Human-Edited: true")
    if pinned_version:
        commit_lines.append(f"Release-Pinned-Version: {pinned_version}")
    commit_message = "\n".join(commit_lines) + "\n"

    if args.output_changelog:
        Path(args.output_changelog).write_text(new_changelog, encoding="utf-8")
    if args.output_pr_body:
        Path(args.output_pr_body).write_text(pr_body, encoding="utf-8")

    result = {
        "action": "create_or_update",
        "reason": reason,
        "last_tag": last_tag or "",
        "next_tag": next_tag,
        "auto_tag": auto_tag,
        "bump": overall_bump,
        "commit_count": len(all_entries),
        "human_edited": human_edited,
        "pinned_version": pinned_version or "",
        "pr_title": pr_title,
        "commit_message": commit_message,
        "head_sha": head_sha,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def parse_pr_json(path: str | None) -> list[dict]:
    if not path:
        return []
    p = Path(path)
    if not p.exists():
        return []
    raw = p.read_text(encoding="utf-8").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    return data if isinstance(data, list) else []


def detect_pr_from_api(
    pr_items: list[dict], head_sha: str, release_branch: str
) -> tuple[bool, str | None, str]:
    """Check GitHub API PR objects for a merged Release PR matching head_sha."""
    for pr in pr_items:
        if not isinstance(pr, dict):
            continue
        # Support both REST /commits/{sha}/pulls and gh pr list --json shapes.
        merged = bool(pr.get("merged_at") or pr.get("mergedAt") or pr.get("state") == "MERGED")
        if not merged:
            continue

        head_ref = ""
        if isinstance(pr.get("head"), dict):
            head_ref = str(pr["head"].get("ref") or "")
        elif pr.get("headRefName"):
            head_ref = str(pr["headRefName"])

        merge_oid = ""
        if isinstance(pr.get("mergeCommit"), dict):
            merge_oid = str(pr["mergeCommit"].get("oid") or "")
        elif pr.get("merge_commit_sha"):
            merge_oid = str(pr["merge_commit_sha"])

        # If mergeCommit is provided (from gh pr list), ensure it strictly matches head_sha.
        if "mergeCommit" in pr and merge_oid != head_sha:
            continue

        labels = set()
        for lbl in pr.get("labels") or []:
            if isinstance(lbl, dict) and lbl.get("name"):
                labels.add(str(lbl["name"]))
            elif isinstance(lbl, str):
                labels.add(lbl)

        if head_ref == release_branch or "release-pr" in labels:
            pr_num = pr.get("number")
            return True, (str(pr_num) if pr_num is not None else None), "github_api"
    return False, None, ""


def extract_released_tag_from_changelog_diff(
    repo: Path, base_ref: str | None, head_sha: str
) -> str | None:
    head_changelog = get_file_at_ref(repo, head_sha, "CHANGELOG.md")
    if not head_changelog:
        return None
    head_versions = extract_changelog_versions(head_changelog)
    if not head_versions:
        return None

    if base_ref and git_ref_exists(repo, base_ref):
        base_changelog = get_file_at_ref(repo, base_ref, "CHANGELOG.md") or ""
        base_versions = set(extract_changelog_versions(base_changelog))
        added = [v for v in head_versions if v not in base_versions]
        if added:
            return added[0]

    # Fallback (e.g., multi-commit rebase where last commit edited prose only):
    # use the top version in CHANGELOG.md if it doesn't already tag an older commit.
    top_version = head_versions[0]
    proc = subprocess.run(
        ["git", "rev-list", "-n", "1", f"refs/tags/{top_version}"],
        cwd=str(repo),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if proc.returncode != 0 or proc.stdout.strip() == head_sha:
        return top_version
    return None


def cmd_detect(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    head_sha = run_git(repo, ["rev-parse", args.head]).strip()
    release_branch = args.release_branch

    base_ref = args.base
    if not base_ref or not git_ref_exists(repo, base_ref):
        parents = get_commit_parents(repo, head_sha)
        base_ref = parents[0] if parents else None

    is_merge = False
    pr_number: str | None = None
    reason = "not_a_release_pr_merge"

    # 1. Primary signal: GitHub API PR metadata when provided
    api_prs = parse_pr_json(args.pr_json) + parse_pr_json(args.merged_pr_json)
    if api_prs:
        matched, num, api_reason = detect_pr_from_api(
            api_prs, head_sha, release_branch
        )
        if matched:
            is_merge = True
            pr_number = num
            reason = api_reason

    # 2. Pure-Git signal (offline tests + fallback when GitHub API lags)
    if not is_merge:
        subject, body = get_commit_subject_and_body(repo, head_sha)
        changed_files = (
            [
                line.strip()
                for line in run_git(
                    repo, ["diff", "--name-only", base_ref, head_sha]
                ).splitlines()
                if line.strip()
            ]
            if base_ref
            else get_commit_changed_files(repo, head_sha, [])
        )
        only_changelog = bool(changed_files) and all(
            f == "CHANGELOG.md" for f in changed_files
        )

        # Inspect commits introduced in base_ref..head_sha for Release PR markers
        rev_range = f"{base_ref}..{head_sha}" if base_ref else head_sha
        commit_shas = [
            s.strip()
            for s in run_git(repo, ["rev-list", "-n", "20", rev_range]).splitlines()
            if s.strip()
        ]
        git_marker_found = False
        for csha in commit_shas:
            csub, cbody = get_commit_subject_and_body(repo, csha)
            if is_release_pr_commit(csub, cbody, release_branch):
                git_marker_found = True
                m_pr = PR_MERGE_SUBJECT_RE.match(csub)
                if m_pr and not pr_number:
                    pr_number = m_pr.group(1)
                else:
                    m_tr = TRAILING_PR_RE.search(csub)
                    if m_tr and not pr_number:
                        pr_number = m_tr.group(1)
                break

        if git_marker_found and only_changelog:
            is_merge = True
            reason = "git_commit_marker"

    release_tag = ""
    if is_merge:
        extracted = extract_released_tag_from_changelog_diff(repo, base_ref, head_sha)
        if not extracted:
            print(
                "错误: 检测到 Release PR 合并，但无法从 CHANGELOG.md 提取有效的未发布版本号（## [vX.Y.Z]）。",
                file=sys.stderr,
            )
            return 1
        head_changelog = get_file_at_ref(repo, head_sha, "CHANGELOG.md") or ""
        if not extract_changelog_section(head_changelog, extracted):
            print(
                f"错误: CHANGELOG.md 中 {extracted} 章节内容为空，无法继续发版。",
                file=sys.stderr,
            )
            return 1
        release_tag = extracted

    result = {
        "is_release_merge": is_merge,
        "release_tag": release_tag,
        "pr_number": pr_number or "",
        "reason": reason,
        "head_sha": head_sha,
    }

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            fh.write(f"is_release_merge={'true' if is_merge else 'false'}\n")
            fh.write(f"release_tag={release_tag}\n")
            fh.write(f"pr_number={pr_number or ''}\n")
            fh.write(f"reason={reason}\n")

    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def cmd_check_changelog(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    tag = normalize_tag(args.tag)
    changelog = get_file_at_ref(repo, args.ref, "CHANGELOG.md")
    if not changelog:
        print(f"错误: 在 {args.ref} 未找到 CHANGELOG.md。", file=sys.stderr)
        return 1
    section = extract_changelog_section(changelog, tag)
    if not section:
        print(
            f"错误: {args.ref} 的 CHANGELOG.md 中缺少 {tag} 的非空版本说明。",
            file=sys.stderr,
        )
        return 1
    print(f"CHANGELOG.md 校验通过: {tag}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AI Cleaner Release PR helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan", help="Plan Release PR version and CHANGELOG update")
    p_plan.add_argument("--repo", default=".", help="Git repository root")
    p_plan.add_argument("--head", default="HEAD", help="Target branch head ref")
    p_plan.add_argument(
        "--release-branch", default="release-pr/main", help="Release PR branch name"
    )
    p_plan.add_argument(
        "--release-branch-ref",
        default="",
        help="Git ref of existing open Release PR branch (e.g. origin/release-pr/main)",
    )
    p_plan.add_argument(
        "--has-open-pr",
        action="store_true",
        help="Whether an open Release PR currently exists",
    )
    p_plan.add_argument("--date", default="", help="Override release date YYYY-MM-DD")
    p_plan.add_argument("--output-changelog", default="", help="Write updated CHANGELOG.md")
    p_plan.add_argument("--output-pr-body", default="", help="Write PR body markdown")
    p_plan.set_defaults(func=cmd_plan)

    p_detect = sub.add_parser("detect", help="Detect whether HEAD is a Release PR merge")
    p_detect.add_argument("--repo", default=".", help="Git repository root")
    p_detect.add_argument("--head", default="HEAD", help="Commit SHA/ref to inspect")
    p_detect.add_argument("--base", default="", help="Previous base SHA before push")
    p_detect.add_argument(
        "--release-branch", default="release-pr/main", help="Release PR branch name"
    )
    p_detect.add_argument(
        "--pr-json", default="", help="JSON file from GitHub commits/{sha}/pulls API"
    )
    p_detect.add_argument(
        "--merged-pr-json",
        default="",
        help="JSON file from gh pr list --state merged --head release-pr/main",
    )
    p_detect.add_argument(
        "--github-output", default="", help="Append outputs to GITHUB_OUTPUT file"
    )
    p_detect.set_defaults(func=cmd_detect)

    p_check = sub.add_parser(
        "check-changelog", help="Validate CHANGELOG.md contains a tag section"
    )
    p_check.add_argument("--repo", default=".", help="Git repository root")
    p_check.add_argument("--tag", required=True, help="Release tag vX.Y.Z")
    p_check.add_argument("--ref", default="HEAD", help="Git ref to inspect")
    p_check.set_defaults(func=cmd_check_changelog)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
