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


def idle_memory(exe: Path, settle: float) -> dict:
    before = {p.pid for p in psutil.process_iter()}
    proc = subprocess.Popen([str(exe)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(settle)
    procs: dict[int, psutil.Process] = {}
    try:
        root = psutil.Process(proc.pid)
        procs[root.pid] = root
        for child in root.children(recursive=True):
            procs[child.pid] = child
    except psutil.NoSuchProcess:
        return {"error": f"app exited early with code {proc.poll()}"}
    # macOS WebKit XPC services are launchd children, not app children: pick up new ones by name.
    for p in psutil.process_iter(["name"]):
        if p.pid not in before and p.pid not in procs and any(h in (p.info["name"] or "").lower() for h in WEBVIEW_HINTS):
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
    result = {
        "settle_seconds": settle,
        "processes": sorted(rows, key=lambda r: r["name"]),
        "total_rss_mib": round(sum(r["rss_mib"] or 0 for r in rows), 2),
        "total_uss_mib": round(sum(r.get("uss_mib") or 0 for r in rows), 2) if all("uss_mib" in r for r in rows) else None,
        "sidecar_running": any("aicleaner-core" in r["name"] for r in rows),
    }
    for p in list(procs.values()):
        try:
            if p.pid != proc.pid:
                p.kill()
        except psutil.Error:
            pass
    proc.kill()
    proc.wait(timeout=10)
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
