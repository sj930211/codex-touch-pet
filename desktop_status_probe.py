#!/usr/bin/env python3
"""Subscribe to one Codex Desktop thread and print status-only metadata.

This uses Codex Desktop's local, private IPC coordination protocol. It is a
feasibility probe, not a stable integration contract. Conversation text and
tool payloads are intentionally ignored.
"""

from __future__ import annotations

import json
import os
import select
import socket
import struct
import sys
import time
import uuid
from pathlib import Path
from typing import Any


SOCKET_PATH = Path.home() / ".codex/ipc/ipc.sock"
THREAD_ID = os.environ.get("CODEX_THREAD_ID")


def send_frame(connection: socket.socket, payload: dict[str, Any]) -> None:
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


def receive_frame(connection: socket.socket) -> dict[str, Any]:
    length = struct.unpack("<I", receive_exact(connection, 4))[0]
    if length == 0 or length > 256 * 1024 * 1024:
        raise ValueError(f"invalid frame length: {length}")
    return json.loads(receive_exact(connection, length))


def request(
    connection: socket.socket,
    client_id: str,
    method: str,
    params: dict[str, Any],
    version: int,
) -> str:
    request_id = str(uuid.uuid4())
    send_frame(
        connection,
        {
            "type": "request",
            "requestId": request_id,
            "sourceClientId": client_id,
            "version": version,
            "method": method,
            "params": params,
            "timeoutMs": 5000,
        },
    )
    return request_id


def following(
    connection: socket.socket,
    client_id: str,
    owner_client_id: str,
    enabled: bool,
) -> None:
    send_frame(
        connection,
        {
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": client_id,
            "targetClientIds": [owner_client_id],
            "params": {
                "conversationId": THREAD_ID,
                "hostId": "local",
                "following": enabled,
            },
            "version": 1,
        },
    )


def reject_discovery(connection: socket.socket, message: dict[str, Any]) -> None:
    send_frame(
        connection,
        {
            "type": "client-discovery-response",
            "requestId": message["requestId"],
            "response": {"canHandle": False},
        },
    )


def safe_snapshot(state: dict[str, Any], revision: Any) -> dict[str, Any]:
    turns = state.get("turns")
    last_turn = turns[-1] if isinstance(turns, list) and turns else None
    requests = state.get("requests")
    return {
        "event": "snapshot",
        "threadId": state.get("id") or THREAD_ID,
        "revision": revision,
        "threadRuntimeStatus": state.get("threadRuntimeStatus"),
        "resumeState": state.get("resumeState"),
        "lastTurnStatus": last_turn.get("status") if isinstance(last_turn, dict) else None,
        "pendingRequestCount": len(requests) if isinstance(requests, list) else None,
        "hasUnreadTurn": state.get("hasUnreadTurn"),
    }


def safe_patches(patches: list[Any], revision: Any) -> dict[str, Any] | None:
    allowed_markers = ("threadRuntimeStatus", "status", "requests", "hasUnreadTurn")
    selected: list[dict[str, Any]] = []
    for patch in patches:
        if not isinstance(patch, dict):
            continue
        path = patch.get("path")
        path_text = json.dumps(path, separators=(",", ":"))
        if not any(marker in path_text for marker in allowed_markers):
            continue
        selected.append(
            {
                "op": patch.get("op"),
                "path": path,
                "value": patch.get("value"),
            }
        )
    if not selected:
        return None
    return {"event": "status-patches", "revision": revision, "patches": selected}


def main() -> int:
    if not THREAD_ID:
        raise SystemExit("CODEX_THREAD_ID is not available")
    duration = 10.0
    if len(sys.argv) > 1:
        duration = max(2.0, min(300.0, float(sys.argv[1])))

    client_id = "initializing-client"
    owner_client_id: str | None = None
    discovery_request_id: str | None = None
    subscribed = False

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(SOCKET_PATH))
        initialize_request_id = request(
            connection,
            client_id,
            "initialize",
            {"clientType": "codex-touchbar-status-probe"},
            0,
        )

        deadline = time.monotonic() + duration
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([connection], [], [], 0.5)
                if not readable:
                    continue
                message = receive_frame(connection)

                if message.get("type") == "client-discovery-request":
                    reject_discovery(connection, message)
                    continue

                if message.get("requestId") == initialize_request_id:
                    if message.get("resultType") != "success":
                        print(json.dumps({"event": "initialize-failed"}))
                        return 2
                    client_id = message["result"]["clientId"]
                    discovery_request_id = request(
                        connection,
                        client_id,
                        "thread-owner-discovery",
                        {"hostId": "local", "conversationId": THREAD_ID},
                        1,
                    )
                    continue

                if discovery_request_id and message.get("requestId") == discovery_request_id:
                    if message.get("resultType") != "success":
                        print(
                            json.dumps(
                                {
                                    "event": "owner-not-found",
                                    "threadId": THREAD_ID,
                                    "error": message.get("error"),
                                }
                            )
                        )
                        return 3
                    owner_client_id = message.get("handledByClientId")
                    print(
                        json.dumps(
                            {
                                "event": "owner-found",
                                "threadId": THREAD_ID,
                                "ownerClientId": owner_client_id,
                            }
                        )
                    )
                    following(connection, client_id, owner_client_id, True)
                    subscribed = True
                    continue

                if (
                    message.get("type") == "broadcast"
                    and message.get("method") == "thread-stream-state-changed"
                ):
                    params = message.get("params", {})
                    if params.get("conversationId") != THREAD_ID:
                        continue
                    change = params.get("change", {})
                    if change.get("type") == "snapshot":
                        state = change.get("conversationState")
                        if isinstance(state, dict):
                            print(
                                json.dumps(
                                    safe_snapshot(state, change.get("revision")),
                                    ensure_ascii=False,
                                )
                            )
                    elif change.get("type") == "patches":
                        patches = change.get("patches")
                        if isinstance(patches, list):
                            safe = safe_patches(patches, change.get("revision"))
                            if safe:
                                print(json.dumps(safe, ensure_ascii=False))
        finally:
            if subscribed and owner_client_id:
                following(connection, client_id, owner_client_id, False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
