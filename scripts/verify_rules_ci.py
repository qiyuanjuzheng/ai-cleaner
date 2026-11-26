#!/usr/bin/env python3
"""Real-OS CI rule verification harness for AICL-37 (Windows) and AICL-38 (Linux).

Runs real AI CLI clients on the current OS, captures the real generated files,
executes the real `aicleaner-core` JSON-RPC v1 sidecar (`core.handshake` ->
`scan.start` -> `scan.completed` -> `items.query` -> `core.shutdown`), and writes:
  - tree.txt          (real files created by the clients)
  - scan-report.json  (full JSON-RPC scan & query output from aicleaner-core)
  - summary.md        (Markdown verification record suitable for CI step summary)
"""

import argparse
import json
import os
import platform
from queue import Queue
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def run_cmd(cmd, env=None, timeout=60, cwd=None):
    try:
        proc = subprocess.run(
            cmd,
            env=env,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        err = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return 124, out, err + "\n[timeout]"
    except OSError as exc:
        return 127, "", str(exc)


def resolve_tool(name: str, os_name: str, npm_bin: Path | None, env: dict[str, str]):
    candidates = []
    if npm_bin is not None:
        if os_name == "windows":
            candidates.extend([npm_bin / f"{name}.cmd", npm_bin / f"{name}.exe", npm_bin / name])
        else:
            candidates.append(npm_bin / name)
    for cand in candidates:
        if cand.exists():
            return str(cand)
    return shutil.which(name, path=env.get("PATH"))


def run_client_probes(os_name: str, npm_bin: Path | None, env: dict[str, str]) -> list[dict]:
    probes = [
        ("opencode", [
            ["opencode", "--version"],
            ["opencode", "debug", "paths"],
            ["opencode", "session", "list", "--format", "json", "--pure"],
            ["opencode", "run", "--pure", "--model", "missing-provider/missing-model", "diagnostic"],
        ]),
        ("codex", [["codex", "--version"], ["codex", "--help"]]),
        ("pi", [["pi", "--version"], ["pi", "--help"]]),
        ("gemini", [["gemini", "--version"], ["gemini", "--help"]]),
        ("claude", [["claude", "--version"], ["claude", "--help"]]),
        ("copilot", [["copilot", "--version"], ["copilot", "--help"]]),
    ]
    results = []
    for label, commands in probes:
        exe = resolve_tool(label, os_name, npm_bin, env)
        record = {"client": label, "executable": exe, "commands": []}
        if not exe:
            record["status"] = "not-installed"
            results.append(record)
            continue
        record["status"] = "ran"
        for raw_cmd in commands:
            cmd = [exe] + raw_cmd[1:]
            rc, out, err = run_cmd(cmd, env=env, timeout=25)
            record["commands"].append({
                "argv": raw_cmd,
                "exitCode": rc,
                "stdout": out.strip()[:800],
                "stderr": err.strip()[:400],
            })
        results.append(record)
    return results


def snapshot_files(roots: list[Path], max_depth: int = 5) -> dict[str, int]:
    files: dict[str, int] = {}
    for root in roots:
        if not root.exists():
            continue
        root_resolved = root.resolve()
        for dirpath, dirnames, filenames in os.walk(root_resolved):
            # Skip huge unrelated caches/system trees on real Windows runner profiles.
            dirnames[:] = sorted(
                d for d in dirnames
                if d.lower() not in {
                    "node_modules", ".git", "temp", "microsoft", "packages", "programs",
                    "windows", "npm-cache", "pip", "cargo", "rustup", ".dotnet", "nuget"
                }
            )
            rel_dir = Path(dirpath).relative_to(root_resolved)
            depth = 0 if str(rel_dir) == "." else len(rel_dir.parts)
            if depth >= max_depth:
                dirnames[:] = []
                continue
            for name in sorted(filenames):
                p = Path(dirpath) / name
                try:
                    size = p.lstat().st_size
                except OSError:
                    size = -1
                rel = f"{root.name}/{p.relative_to(root_resolved).as_posix()}"
                files[rel] = size
    return files


def call_sidecar_scan(sidecar_bin: Path, env: dict[str, str]) -> dict:
    proc = subprocess.Popen(
        [str(sidecar_bin)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None

    output_queue: Queue = Queue()
    events: list[dict] = []
    next_id = 0

    def read_stdout():
        try:
            for line in proc.stdout:
                line = line.strip()
                if line:
                    output_queue.put(json.loads(line))
        except Exception as exc:
            output_queue.put(exc)
        finally:
            output_queue.put(EOFError("sidecar stdout closed"))

    reader = threading.Thread(target=read_stdout, daemon=True)
    reader.start()

    def recv(timeout=120):
        item = output_queue.get(timeout=timeout)
        if isinstance(item, Exception):
            stderr = proc.stderr.read() if proc.poll() is not None else ""
            raise RuntimeError(f"sidecar stream error: {item}; stderr={stderr}")
        return item

    def call(method: str, **params):
        nonlocal next_id
        next_id += 1
        req = {"jsonrpc": "2.0", "id": next_id, "method": method, "params": params}
        proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        while True:
            msg = recv()
            if "method" in msg:
                events.append(msg)
                continue
            if msg.get("id") != next_id:
                continue
            if "error" in msg:
                raise RuntimeError(f"RPC {method} error: {msg['error']}")
            return msg["result"]

    try:
        handshake = call("core.handshake", protocolVersion="1.0", clientVersion="rules-verify-ci", locale="zh-Hans")
        scan_started = call("scan.start")
        scan_id = scan_started["scanId"]
        while not any(e.get("method") == "scan.completed" for e in events):
            events.append(recv())
        completion = next(e["params"] for e in events if e.get("method") == "scan.completed")
        if completion.get("status") != "completed":
            raise RuntimeError(f"scan did not complete: {completion}")
        clients_list = call("clients.list", scanId=scan_id)
        items = call("items.query", scanId=scan_id, limit=200)
        call("core.shutdown")
        proc.stdin.close()
        proc.wait(timeout=20)
        return {
            "handshake": handshake,
            "scanId": scan_id,
            "completed": completion,
            "clientsList": clients_list,
            "itemsQuery": items,
        }
    finally:
        if proc.poll() is None:
            proc.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sidecar", required=True, type=Path, help="Path to built aicleaner-core binary")
    parser.add_argument("--out", required=True, type=Path, help="Output directory for tree/report/summary")
    parser.add_argument("--npm-bin", type=Path, default=None, help="Directory with pre-installed CLI binaries")
    parser.add_argument("--use-real-home", action="store_true", help="Use host real user profile (recommended on Windows CI)")
    args = parser.parse_args()

    os_name = {"Darwin": "macos", "Windows": "windows", "Linux": "linux"}.get(platform.system(), platform.system().lower())
    args.out.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    temp_ctx = None
    if args.use_real_home:
        home = Path.home()
    else:
        temp_ctx = tempfile.TemporaryDirectory(prefix="aicl-rules-verify-")
        home = Path(temp_ctx.name) / "home"
        home.mkdir(parents=True, exist_ok=True)
        env["HOME"] = str(home)
        if os_name == "linux":
            for var, rel in (
                ("XDG_CONFIG_HOME", ".config"),
                ("XDG_DATA_HOME", ".local/share"),
                ("XDG_CACHE_HOME", ".cache"),
                ("XDG_STATE_HOME", ".local/state"),
            ):
                d = home / rel
                d.mkdir(parents=True, exist_ok=True)
                env[var] = str(d)

    if args.npm_bin is not None:
        env["PATH"] = str(args.npm_bin) + os.pathsep + env.get("PATH", "")

    watch_roots = [home]
    before = snapshot_files(watch_roots)
    probed = run_client_probes(os_name, args.npm_bin, env)
    after = snapshot_files(watch_roots)
    created = sorted(f"{path} ({size} bytes)" for path, size in after.items() if path not in before or before[path] != size)

    (args.out / "tree.txt").write_text("\n".join(created) + ("\n" if created else ""), encoding="utf-8")

    rpc_result = call_sidecar_scan(args.sidecar, env)
    output_payload = {
        "os": os_name,
        "platform": platform.platform(),
        "home": str(home),
        "useRealHome": args.use_real_home,
        "clientsProbed": probed,
        "createdOrModifiedFiles": created,
        "sidecar": rpc_result,
    }
    (args.out / "scan-report.json").write_text(json.dumps(output_payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    completed = rpc_result["completed"]
    summary = completed.get("summary", {})
    clients = rpc_result.get("clientsList", {}).get("clients", [])
    items = rpc_result["itemsQuery"].get("items", [])

    md = [
        f"## Real-OS Rules Verification ({os_name} · `{platform.platform()}`)",
        "",
        f"- **Sidecar protocol**: v{rpc_result['handshake'].get('protocolVersion')} (`{rpc_result['handshake'].get('platform')}`)",
        f"- **Built-in profiles loaded**: {summary.get('totalBuiltInProfilesCount', 0)}",
        f"- **Detected built-in clients**: {summary.get('detectedBuiltInClientsCount', 0)}",
        f"- **Cleanable items**: {summary.get('totalItemCount', 0)} ({summary.get('totalSizeBytes', 0)} bytes)",
        f"- **Protected items**: {summary.get('totalProtectedItemCount', 0)} ({summary.get('protectedSizeBytes', 0)} bytes)",
        f"- **Files created/modified by CLI probes**: {len(created)}",
        "",
        "### Probed CLI Clients",
        "| Client | Status | Key Output |",
        "| --- | --- | --- |",
    ]
    for c in probed:
        sample = ""
        for cmd in c.get("commands", []):
            if cmd["stdout"]:
                sample = cmd["stdout"].splitlines()[0].replace("|", "\\|")[:90]
                break
        md.append(f"| `{c['client']}` | `{c['status']}` | `{sample}` |")

    for c in probed:
        for cmd in c.get("commands", []):
            if cmd["argv"][:3] == ["opencode", "debug", "paths"] and cmd["stdout"]:
                md.extend(["", "### `opencode debug paths` Output", "```text", cmd["stdout"], "```"])

    md.extend([
        "",
        "### `aicleaner-core` Detected Clients",
        "| Client | Items | Cleanable Bytes | Protected Bytes |",
        "| --- | ---: | ---: | ---: |",
    ])
    for cl in clients:
        md.append(
            f"| `{cl['id']}` ({cl['name']}) | {cl.get('itemCount', 0)} | {cl.get('totalSizeBytes', 0)} | {cl.get('protectedSizeBytes', 0)} |"
        )

    if items:
        md.extend([
            "",
            "### Sample Discovered Items (first 30)",
            "| Client | Rule ID | Recommendation | Size | Path |",
            "| --- | --- | --- | ---: | --- |",
        ])
        for it in items[:30]:
            md.append(
                f"| `{it['clientId']}` | `{it['ruleId']}` | `{it['recommendation']}` | {it['sizeBytes']} | `{it['path']}` |"
            )

    if created:
        md.extend(["", "### Newly Created/Modified Files Snapshot (first 60)", "```text", *created[:60], "```"])

    summary_text = "\n".join(md) + "\n"
    (args.out / "summary.md").write_text(summary_text, encoding="utf-8")
    print(summary_text)

    if temp_ctx is not None:
        temp_ctx.cleanup()
    return 0


if __name__ == "__main__":
    sys.exit(main())
