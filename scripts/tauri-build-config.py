#!/usr/bin/env python3
"""Write the version and optional updater settings for a Tauri bundle build."""

import argparse
import json
import os
from pathlib import Path
import re


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("repository")
    parser.add_argument("output", type=Path)
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", args.tag):
        parser.error("expected a release tag in vX.Y.Z format")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repository):
        parser.error("expected a GitHub repository in owner/name format")
    version = args.tag[1:]
    config = {"version": version, "bundle": {"macOS": {"bundleVersion": version}}}
    pubkey = os.environ.get("TAURI_UPDATER_PUBLIC_KEY", "").strip()
    if args.release and not pubkey:
        parser.error("configure TAURI_UPDATER_PUBLIC_KEY in repository variables")
    if pubkey:
        config["bundle"]["createUpdaterArtifacts"] = True
        updater = {"pubkey": pubkey, "requireSignedVersion": True}
        if args.release:
            updater["endpoints"] = [f"https://github.com/{args.repository}/releases/latest/download/latest.json"]
        config["plugins"] = {"updater": updater}
    thumbprint = os.environ.get("AI_CLEANER_WINDOWS_SIGNING_THUMBPRINT", "").strip()
    if thumbprint:
        if not re.fullmatch(r"[0-9A-Fa-f]{40}", thumbprint):
            parser.error("invalid Windows code-signing certificate thumbprint")
        config["bundle"]["windows"] = {
            "certificateThumbprint": thumbprint,
            "digestAlgorithm": "sha256",
            "timestampUrl": "http://timestamp.digicert.com",
            "tsp": True,
        }
    args.output.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
