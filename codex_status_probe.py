#!/usr/bin/env python3
"""Read Codex thread metadata from a short-lived local app-server.

The probe deliberately prints only thread identifiers, runtime status, cwd,
timestamps, and source. It does not print prompts, assistant messages, or turn
contents.
"""

from __future__ import annotations

import json
import os
import selectors
import subprocess
import sys
import time
from pathlib import Path


CODEX = Path.home() / ".npm-global/bin/codex"


def send(process: subprocess.Popen[str], payload: dict[str, object]) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    process.stdin.flush()


def main() -> int:
    process = subprocess.Popen(
        [str(CODEX), "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=os.environ.copy(),
    )
    assert process.stdout is not None
    assert process.stderr is not None

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")

    send(
        process,
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codex-touchbar-feasibility-probe",
                    "title": "Codex Touch Bar Feasibility Probe",
                    "version": "0.1.0",
                },
                "capabilities": {"experimentalApi": True},
            },
        },
    )

    initialized = False
    requested_threads = False
    deadline = time.monotonic() + 12.0

    try:
        while time.monotonic() < deadline:
            events = selector.select(timeout=0.5)
            if not events and process.poll() is not None:
                break

            for key, _ in events:
                line = key.fileobj.readline()
                if not line:
                    continue
                if key.data == "stderr":
                    if "ERROR" in line or "WARN" in line:
                        print(f"app-server: {line.strip()}", file=sys.stderr)
                    continue

                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if message.get("id") == 1:
                    if "error" in message:
                        print(json.dumps(message["error"], ensure_ascii=False), file=sys.stderr)
                        return 2
                    initialized = True
                    if not requested_threads:
                        requested_threads = True
                        send(
                            process,
                            {
                                "id": 2,
                                "method": "thread/list",
                                "params": {
                                    "limit": 20,
                                    "sortKey": "recency_at",
                                    "sortDirection": "desc",
                                    "useStateDbOnly": True,
                                },
                            },
                        )
                    continue

                if message.get("id") == 2:
                    if "error" in message:
                        print(json.dumps(message["error"], ensure_ascii=False), file=sys.stderr)
                        return 3
                    result = message.get("result", {})
                    threads = result.get("data", [])
                    sanitized = [
                        {
                            "id": thread.get("id"),
                            "status": thread.get("status"),
                            "cwd": thread.get("cwd"),
                            "source": thread.get("source"),
                            "updatedAt": thread.get("updatedAt"),
                        }
                        for thread in threads
                    ]
                    print(
                        json.dumps(
                            {
                                "initialized": initialized,
                                "threadCount": len(sanitized),
                                "threads": sanitized,
                            },
                            ensure_ascii=False,
                            indent=2,
                        )
                    )
                    return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

    print("Timed out before thread/list returned", file=sys.stderr)
    return 4


if __name__ == "__main__":
    raise SystemExit(main())
