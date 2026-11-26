#!/usr/bin/env python3
"""AICL-33: measure the Tauri shell probe on the current platform.

Records installer sizes, installed size and idle memory (app + WebView processes + sidecar).

    python measure_shell.py --bundle-dir src-tauri/target/release/bundle --out shell.json

Linux needs a display (run under `xvfb-run -a`). Requires `psutil`.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import psutil

WEBVIEW_HINTS = ("webkit", "webview", "msedgewebview2")


def mib(n: int | None) -> float | None:
    return None if n is None else round(n / 1024 / 1024, 2)


def dir_size(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            p = Path(root) / name
            if not p.is_symlink():
                total += p.stat().st_size
    return total


def sample_memory(root: psutil.Process, before: set[int]) -> list[dict]:
    procs: dict[int, psutil.Process] = {}
    procs[root.pid] = root
    for child in root.children(recursive=True):
        procs[child.pid] = child
    # macOS WebKit XPC services are launchd children, not app children: pick up new ones by name.
    if sys.platform == "darwin":
        for p in psutil.process_iter(["name"]):
            if p.pid not in before and (p.info["name"] or "").startswith("com.apple.WebKit."):
                procs[p.pid] = p
    rows = []
    for p in procs.values():
        try:
            info = p.memory_info()
            row = {"pid": p.pid, "name": p.name(), "rss_mib": mib(info.rss)}
            try:
                row["uss_mib"] = mib(p.memory_full_info().uss)
            except (psutil.AccessDenied, AttributeError, psutil.ZombieProcess):
                pass
            rows.append(row)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return sorted(rows, key=lambda row: row["name"])


def idle_memory(exe: Path, settle: float) -> dict:
    before = {p.pid for p in psutil.process_iter()} if sys.platform == "darwin" else set()
    with tempfile.TemporaryDirectory(prefix="aicl33-hello-") as scratch, tempfile.TemporaryFile() as log:
        hello_file = Path(scratch) / "hello.json"
        env = dict(os.environ, AICL33_HELLO_FILE=str(hello_file))
        proc = subprocess.Popen([str(exe)], env=env, stdout=log, stderr=log)
        started = time.monotonic()
        rows = []
        result: dict = {"settle_seconds": settle}
        try:
            while proc.poll() is None and time.monotonic() - started < 60:
                if hello_file.is_file():
                    try:
                        hello = json.loads(hello_file.read_text(encoding="utf-8"))
                    except json.JSONDecodeError:
                        pass
                    else:
                        result["hello"] = hello
                        result["startup_seconds"] = round(time.monotonic() - started, 2)
                        break
                time.sleep(0.1)
            hello = result.get("hello", {})
            if hello.get("jsonrpc") == "2.0" and hello.get("id") == 1 and hello.get("result", {}).get("protocol") == 1:
                time.sleep(settle)
            else:
                result["error"] = f"sidecar hello did not complete (app exit: {proc.poll()})"
            if proc.poll() is None:
                rows = sample_memory(psutil.Process(proc.pid), before)
            else:
                result.setdefault("error", f"app exited with code {proc.returncode}")
        finally:
            if proc.poll() is None:
                try:
                    for child in psutil.Process(proc.pid).children(recursive=True):
                        try:
                            child.kill()
                        except psutil.NoSuchProcess:
                            pass
                except psutil.NoSuchProcess:
                    pass
                proc.kill()
            proc.wait(timeout=10)
        result["processes"] = rows
        result["sidecar_running"] = any("aicleaner-core" in row["name"] for row in rows)
        result["webview_running"] = any(any(hint in row["name"].lower() for hint in WEBVIEW_HINTS) for row in rows)
        if result["sidecar_running"] and result["webview_running"] and "error" not in result:
            result["total_rss_mib"] = round(sum(row["rss_mib"] for row in rows), 2)
            result["total_uss_mib"] = round(sum(row["uss_mib"] for row in rows), 2) if all("uss_mib" in row for row in rows) else None
        else:
            result.setdefault("error", "sidecar or WebView processes missing at the idle sample")
            log.seek(0, os.SEEK_END)
            log.seek(max(0, log.tell() - 8192))
            result["app_log"] = log.read().decode(errors="replace")
        return result


def files_matching(bundle: Path, pattern: str) -> dict:
    return {Path(f).name: mib(Path(f).stat().st_size) for f in sorted(glob.glob(str(bundle / pattern)))}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--settle", type=float, default=10.0)
    args = ap.parse_args()
    bundle = Path(args.bundle_dir).resolve()
    out: dict = {"platform": sys.platform, "installers": {}}
    exe: Path | None = None

    if sys.platform == "darwin":
        out["installers"] = files_matching(bundle, "dmg/*.dmg")
        app = next(iter(sorted(bundle.glob("macos/*.app"))), None)
        if app:
            out["installed_mib"] = mib(dir_size(app))
            exe = next(iter(sorted((app / "Contents/MacOS").glob("aicleaner-tauri-shell"))), None)
    elif sys.platform.startswith("linux"):
        for pattern in ("deb/*.deb", "rpm/*.rpm", "appimage/*.AppImage"):
            out["installers"].update(files_matching(bundle, pattern))
        deb = next(iter(sorted(bundle.glob("deb/*.deb"))), None)
        if deb:
            root = Path(tempfile.mkdtemp(prefix="aicl33-deb-"))
            subprocess.run(["dpkg-deb", "-x", str(deb), str(root)], check=True)
            out["installed_mib"] = mib(dir_size(root))
            exe = root / "usr/bin/aicleaner-tauri-shell"
    elif os.name == "nt":
        for pattern in ("nsis/*.exe", "msi/*.msi"):
            out["installers"].update(files_matching(bundle, pattern))
        setup = next(iter(sorted(bundle.glob("nsis/*-setup.exe"))), None)
        if setup:
            target = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / "aicl33-install"
            shutil.rmtree(target, ignore_errors=True)
            # NSIS: /S silent, /D must be the last argument and unquoted.
            subprocess.run(f'"{setup}" /S /D={target}', shell=True, check=False)
            for _ in range(60):
                if (target / "aicleaner-tauri-shell.exe").exists():
                    break
                time.sleep(1)
            time.sleep(3)
            if target.exists():
                out["installed_mib"] = mib(dir_size(target))
                out["installed_files"] = {
                    p.name: mib(p.stat().st_size) for p in sorted(target.iterdir()) if p.is_file()
                }
                exe = target / "aicleaner-tauri-shell.exe"
    if exe and exe.exists():
        out["idle"] = idle_memory(exe, args.settle)
    else:
        out["idle"] = {"error": f"app executable not found ({exe})"}
    Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as fh:
            fh.write(f"## Tauri shell probe — {sys.platform}\n\n```json\n{json.dumps(out, ensure_ascii=False, indent=2)}\n```\n")


if __name__ == "__main__":
    main()
