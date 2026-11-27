#!/usr/bin/env python3
"""Check JSON-RPC startup using only the runtime shipped with an installer."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sidecar", type=Path)
    args = parser.parse_args()
    sidecar = args.sidecar.resolve(strict=True)
    methods = [("core.handshake", {"protocolVersion": "1.0"}), ("core.ping", {}), ("core.shutdown", {})]
    requests = "".join(
        json.dumps({"jsonrpc": "2.0", "id": index, "method": method, "params": params}) + "\n"
        for index, (method, params) in enumerate(methods, 1)
    )
    env = os.environ.copy()
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES"):
        env.pop(key, None)
    if os.name == "nt":
        # The runner has Swift on PATH. An installed application must find its own DLLs.
        env["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")

    with tempfile.TemporaryDirectory(prefix="aicleaner-package-") as sandbox:
        env["AI_CLEANER_HOME"] = sandbox
        env.pop("AI_CLEANER_SYSTEM_TMP", None)
        result = subprocess.run(
            [str(sidecar)], input=requests, capture_output=True, encoding="utf-8",
            cwd=sandbox, timeout=30, env=env,
        )
    if result.returncode:
        raise SystemExit(f"{sidecar} exited with {result.returncode}: {result.stderr}")
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    if len(replies) != len(methods) or any(
        reply.get("id") != index or "result" not in reply
        for index, reply in enumerate(replies, 1)
    ):
        raise SystemExit(f"Unexpected JSON-RPC replies from {sidecar}: {replies}")
    if replies[0]["result"].get("protocolVersion") != "1.0":
        raise SystemExit(f"Protocol mismatch from {sidecar}: {replies[0]}")
    print(f"{sidecar}: handshake, ping and shutdown passed")


if __name__ == "__main__":
    main()
