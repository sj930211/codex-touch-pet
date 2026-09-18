#!/usr/bin/env python3
"""Observe metadata-only broadcasts on the local Codex Desktop IPC router.

Frames are length-prefixed JSON. Payload content is never printed; the probe
reports only event names, IDs, revision numbers, and state field names.
"""

from __future__ import annotations

import json
import select
import socket
import struct
import time
import uuid
from collections import Counter
from pathlib import Path


SOCKET_PATH = Path.home() / ".codex/ipc/ipc.sock"


def send_frame(connection: socket.socket, payload: dict[str, object]) -> None:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    connection.sendall(struct.pack("<I", len(encoded)) + encoded)


def receive_exact(connection: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise EOFError("IPC socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def receive_frame(connection: socket.socket) -> dict[str, object]:
    length = struct.unpack("<I", receive_exact(connection, 4))[0]
    if length == 0 or length > 256 * 1024 * 1024:
        raise ValueError(f"invalid frame length: {length}")
    return json.loads(receive_exact(connection, length))


def summarize(message: dict[str, object]) -> dict[str, object]:
    summary: dict[str, object] = {
        "type": message.get("type"),
        "method": message.get("method"),
        "resultType": message.get("resultType"),
        "version": message.get("version"),
    }
    params = message.get("params")
    if isinstance(params, dict):
        for key in ("conversationId", "hostId", "status", "clientType"):
            if key in params:
                summary[key] = params[key]
        change = params.get("change")
        if isinstance(change, dict):
            summary["changeType"] = change.get("type")
            summary["revision"] = change.get("revision")
            state = change.get("conversationState")
            if isinstance(state, dict):
                summary["conversationStateFields"] = sorted(state.keys())
            patches = change.get("patches")
            if isinstance(patches, list):
                summary["patchCount"] = len(patches)
    result = message.get("result")
    if isinstance(result, dict) and "clientId" in result:
        summary["clientId"] = result["clientId"]
    return {key: value for key, value in summary.items() if value is not None}


def main() -> int:
    request_id = str(uuid.uuid4())
    counts: Counter[str] = Counter()

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(SOCKET_PATH))
        send_frame(
            connection,
            {
                "type": "request",
                "requestId": request_id,
                "sourceClientId": "initializing-client",
                "version": 0,
                "method": "initialize",
                "params": {"clientType": "codex-touchbar-feasibility-probe"},
                "timeoutMs": 5000,
            },
        )

        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            readable, _, _ = select.select([connection], [], [], 0.5)
            if not readable:
                continue
            message = receive_frame(connection)
            method = str(message.get("method") or message.get("resultType") or message.get("type"))
            counts[method] += 1
            print(json.dumps(summarize(message), ensure_ascii=False))

    print(json.dumps({"eventCounts": counts}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
