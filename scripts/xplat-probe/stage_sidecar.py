#!/usr/bin/env python3
"""AICL-33: stage a measured sidecar into the Tauri shell probe before `tauri build`.

    python stage_sidecar.py <sidecar-binary> [--runtime-dll DLL ...]

Copies the binary to src-tauri/binaries/aicleaner-core-<rust host triple>[.exe] (Tauri externalBin
naming). On Windows, each --runtime-dll is added to bundle.resources via tauri.windows.conf.json
so the installer carries the Swift runtime next to the sidecar, as a real release would.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent / "tauri-shell" / "src-tauri"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--runtime-dll", action="append", default=[], help="DLL to ship next to the sidecar")
    args = ap.parse_args()
    host = next(
        line.split(":", 1)[1].strip()
        for line in subprocess.run(["rustc", "-vV"], capture_output=True, text=True, check=True).stdout.splitlines()
        if line.startswith("host:")
    )
    src = Path(args.binary)
    suffix = ".exe" if src.suffix.lower() == ".exe" else ""
    dest = HERE / "binaries" / f"aicleaner-core-{host}{suffix}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    dest.chmod(0o755)
    print(f"sidecar -> {dest} ({dest.stat().st_size} bytes)")

    if args.runtime_dll:
        runtime = HERE / "swift-runtime"
        runtime.mkdir(exist_ok=True)
        resources: dict[str, str] = {}
        for dll in args.runtime_dll:
            p = Path(dll)
            shutil.copy2(p, runtime / p.name)
            resources[f"swift-runtime/{p.name}"] = p.name
        overlay = {"bundle": {"resources": resources}}
        (HERE / "tauri.windows.conf.json").write_text(json.dumps(overlay, indent=2), encoding="utf-8")
        print(f"bundled {len(resources)} runtime DLLs")


if __name__ == "__main__":
    main()
