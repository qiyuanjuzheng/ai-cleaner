#!/usr/bin/env python3
"""Build the Tauri v2 update feed from the signed, staged release assets."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote


def signed_asset(
    assets: Path, pattern: str, download_prefix: str, public_key: str | None
) -> dict[str, str]:
    matches = [path for path in assets.glob(pattern) if path.is_file()]
    if len(matches) != 1 or not matches[0].stat().st_size:
        raise ValueError(f"Expected one nonempty asset matching {pattern}")
    asset = matches[0]
    signature_path = asset.with_name(f"{asset.name}.sig")
    signature = signature_path.read_text(encoding="utf-8").strip()
    if not signature:
        raise ValueError(f"Empty signature: {signature_path.name}")
    if public_key is not None:
        verify_signature(asset, signature, public_key)
    return {"url": download_prefix + quote(asset.name, safe=""), "signature": signature}


def verify_signature(asset: Path, signature: str, public_key: str) -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        key_path = Path(temp_dir) / "updater.pub"
        signature_path = Path(temp_dir) / "updater.minisig"
        key_path.write_bytes(base64.b64decode(public_key, validate=True))
        signature_path.write_bytes(base64.b64decode(signature, validate=True))
        try:
            subprocess.run(
                ["minisign", "-V", "-q", "-p", str(key_path), "-x", str(signature_path), "-m", str(asset)],
                check=True,
            )
        except subprocess.CalledProcessError as error:
            raise ValueError(f"Updater signature verification failed: {asset.name}") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("repository")
    parser.add_argument("assets", type=Path)
    parser.add_argument("notes", type=Path)
    parser.add_argument("--verify", action="store_true", help="verify staged installers with minisign")
    args = parser.parse_args()
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", args.tag):
        parser.error("expected a release tag in vX.Y.Z format")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repository):
        parser.error("expected a GitHub repository in owner/name format")
    public_key = None
    if args.verify:
        public_key = os.environ.get("TAURI_UPDATER_PUBLIC_KEY", "").strip()
        if not public_key:
            parser.error("configure TAURI_UPDATER_PUBLIC_KEY to verify update signatures")
    prefix = f"https://github.com/{args.repository}/releases/download/{args.tag}/"
    try:
        mac = signed_asset(args.assets, "*.app.tar.gz", prefix, public_key)
        nsis = signed_asset(args.assets, "*-setup.exe", prefix, public_key)
        msi = signed_asset(args.assets, "*.msi", prefix, public_key)
        appimage = signed_asset(args.assets, "*.AppImage", prefix, public_key)
        feed = {
            "version": args.tag[1:],
            "notes": args.notes.read_text(encoding="utf-8").strip(),
            "platforms": {
                "darwin-aarch64": mac,
                "darwin-x86_64": mac,
                "windows-x86_64": nsis,
                "windows-x86_64-nsis": nsis,
                "windows-x86_64-msi": msi,
                "linux-x86_64": appimage,
            },
        }
        (args.assets / "latest.json").write_text(
            json.dumps(feed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
