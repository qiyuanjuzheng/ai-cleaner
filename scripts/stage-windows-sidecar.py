#!/usr/bin/env python3
"""Stage the Windows release sidecar and its Swift DLLs for the Tauri bundler."""

import argparse
import json
from pathlib import Path
import shutil

from xplat_probe import windows_runtime_closure


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sidecar", type=Path)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    sidecar = args.sidecar.resolve(strict=True)
    runtime = windows_runtime_closure(sidecar)["paths"]
    if "swiftcore.dll" not in runtime:
        raise SystemExit("SwiftCore.dll is missing from the sidecar dependency closure. Check the Swift toolchain PATH.")

    tauri = Path(__file__).resolve().parents[1] / "apps" / "desktop" / "src-tauri"
    binaries = tauri / "binaries"
    dll_directory = binaries / "swift-runtime"
    dll_directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sidecar, binaries / "aicleaner-core-x86_64-pc-windows-msvc.exe")
    resources = {}
    for source in runtime.values():
        dll = Path(source)
        shutil.copy2(dll, dll_directory / dll.name)
        resources[f"binaries/swift-runtime/{dll.name}"] = dll.name
    args.config.write_text(json.dumps({"bundle": {"resources": resources}}, indent=2), encoding="utf-8")
    print(f"Staged the Windows sidecar and {len(resources)} Swift runtime DLLs.")


if __name__ == "__main__":
    main()
