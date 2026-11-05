"""Inline plugin through Hermes' production gateway: `python -m gateway.run`.

Unlike check-hermes-host.py, nothing replaces Hermes' message handler: the real
GatewayRunner authorizes, runs the agent turn and delivers through the adapter.
The two boundaries Hermes does not own are faked on loopback: an OpenAI-compatible
model server with a fixed answer, and the Inline sidecar HTTP contract (the
adapter's own Node sidecar is covered by the package tests). No credentials.

usage: HERMES_PYTHON PLUGIN_DIR  (run with the Hermes host's interpreter)
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPLY = "inline-gateway-e2e-reply"
INBOUND = "inline-gateway-e2e-inbound"
DEADLINE_S = float(os.environ.get("INLINE_GATEWAY_E2E_TIMEOUT", "120"))

plugin_src = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="inline-hermes-gateway-e2e-"))
home = root / "home"
hermes_home = home / ".hermes"
shutil.copytree(plugin_src, hermes_home / "plugins" / "inline")

model_calls: list[dict] = []
sidecar_calls: list[tuple[str, dict]] = []
inbound_ready = threading.Event()
inbound_lines: list[str] = []
lock = threading.Condition()


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Quiet(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def body(self) -> dict:
        size = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(size) if size else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def json(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except OSError:  # the gateway may drop a typing call it no longer awaits
            pass


class Model(Quiet):
    def do_GET(self):
        self.json({"object": "list", "data": [{"id": "e2e-model", "object": "model"}]})

    def do_POST(self):
        req = self.body()
        with lock:
            model_calls.append(req)
        created = int(time.time())
        if not req.get("stream"):
            self.json({
                "id": "e2e", "object": "chat.completion", "created": created, "model": "e2e-model",
                "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": REPLY}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()
        for delta, finish in (({"role": "assistant", "content": REPLY}, None), ({}, "stop")):
            chunk = {"id": "e2e", "object": "chat.completion.chunk", "created": created, "model": "e2e-model",
                     "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
        usage = {"id": "e2e", "object": "chat.completion.chunk", "created": created, "model": "e2e-model",
                 "choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        self.wfile.write(f"data: {json.dumps(usage)}\n\ndata: [DONE]\n\n".encode())
        self.wfile.flush()
        self.close_connection = True


class Sidecar(Quiet):
    """The sidecar's loopback HTTP contract: NDJSON /inbound plus JSON POST RPCs."""

    def do_GET(self):
        if self.path != "/inbound":
            self.json({"ok": False, "error": "not found", "errorKind": "not_found"}, 404)
            return
        self.send_response(200)
        self.send_header("content-type", "application/x-ndjson")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        inbound_ready.set()
        sent = 0
        while True:
            with lock:
                lock.wait_for(lambda: len(inbound_lines) > sent, timeout=1.0)
                pending = inbound_lines[sent:]
            for line in pending:
                data = (line + "\n").encode()
                try:
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                    self.wfile.flush()
                except OSError:
                    return
                sent += 1

    def do_POST(self):
        req = self.body()
        with lock:
            sidecar_calls.append((self.path, req))
            lock.notify_all()
        result: dict = {}
        if self.path in ("/send", "/edit"):
            result = {"messageId": str(9000 + len(sidecar_calls))}
        elif self.path == "/chat":
            result = {"chat": {"id": "101", "type": "private"}}
        elif self.path in ("/history", "/messages"):
            result = {"messages": []}
        self.json({"ok": True, "result": result})


def serve(handler) -> tuple[ThreadingHTTPServer, int]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


model_server, model_port = serve(Model)
sidecar_server, sidecar_port = serve(Sidecar)

(hermes_home / "config.yaml").write_text(
    "model:\n  provider: custom\n"
    f"  base_url: http://127.0.0.1:{model_port}/v1\n"
    "  default: e2e-model\n  context_length: 128000\n"
    "agent:\n  api_max_retries: 0\n  auto_recovery_cycles: 0\n  max_turns: 3\n"
    "compression:\n  enabled: false\n"
    "memory:\n  memory_enabled: false\n  user_profile_enabled: false\n"
    "updates:\n  check: false\n"
    "plugins:\n  enabled: [inline-platform]\n"
    "platform_toolsets:\n  inline: []\n"
    "platforms:\n  inline:\n    enabled: true\n    token: e2e-offline-token\n    extra:\n"
    f"      base_url: http://127.0.0.1:{sidecar_port}\n"
    f"      sidecar_port: {sidecar_port}\n"
    "      dm_policy: open\n      allow_all_users: true\n      context_backfill: 'off'\n"
    "      reactions: false\n      sync_commands: false\n      text_debounce_seconds: 0\n"
    "      drop_pending_on_cold_boot: false\n",
    encoding="utf-8",
)
(hermes_home / ".env").write_text("OPENAI_API_KEY=sk-e2e-offline\n", encoding="utf-8")

env = {k: v for k, v in os.environ.items() if not (
    k.endswith(("_API_KEY", "_TOKEN", "_SECRET")) or k.startswith(("HERMES_", "INLINE_", "OPENAI", "ANTHROPIC", "OPENROUTER", "NOUS_")))}
env.update({
    "HOME": str(home), "HERMES_HOME": str(hermes_home), "OPENAI_API_KEY": "sk-e2e-offline",
    "INLINE_SIDECAR_AUTOSTART": "false", "INLINE_SIDECAR_TOKEN": "e2e-sidecar-token",
    "INLINE_ALLOW_ALL_USERS": "true",
    "HERMES_GATEWAY_LOCK_DIR": str(root / "locks"), "HERMES_GATEWAY_MAX_STARTS": "0",
    "HERMES_STATE_DB_GUARD_BYPASS": "1", "PYTHONUNBUFFERED": "1", "NO_COLOR": "1", "TZ": "UTC",
})
for key in ("NOTIFY_SOCKET", "INVOCATION_ID", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
    env.pop(key, None)

log_path = root / "gateway.log"
log = open(log_path, "wb")
proc = subprocess.Popen([sys.executable, "-m", "gateway.run"], cwd=str(home), env=env,
                        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
log.close()


def tail() -> str:
    return log_path.read_text(errors="replace")[-12000:]


def fail(message: str) -> None:
    print(f"FAIL: {message}\n--- sidecar calls ---")
    for path, body in sidecar_calls:
        print(path, json.dumps(body)[:600])
    print(f"--- model calls: {len(model_calls)}\n--- gateway log (tail) ---\n{tail()}")
    sys.exit(1)


try:
    deadline = time.monotonic() + DEADLINE_S
    while not inbound_ready.wait(0.5):
        if proc.poll() is not None:
            fail(f"gateway exited during boot rc={proc.returncode}")
        if time.monotonic() > deadline:
            fail("gateway never opened the Inline inbound stream")
    now = int(time.time())
    event = {"kind": "message.new", "seq": 1, "chatId": "101", "meId": "999", "meUsername": "e2ebot",
             "_inlineDeliveryId": "d-1",
             "message": {"id": "201", "chatId": "101", "fromId": "42", "date": now, "message": INBOUND,
                         "sender": {"id": "42", "bot": False, "firstName": "E2E"},
                         "peerId": {"peer": {"oneofKind": "user", "user": {"userId": "42"}}}}}
    with lock:
        inbound_lines.append(json.dumps(event))
        lock.notify_all()

    def replied() -> bool:
        return any(p in ("/send", "/edit") and REPLY in json.dumps(b) for p, b in sidecar_calls)

    with lock:
        ok = lock.wait_for(replied, timeout=max(1.0, deadline - time.monotonic()))
    if not ok:
        fail("the agent's reply never reached Inline through the gateway")
    if not model_calls:
        fail("reply arrived without a model call; the gateway turn did not run")
    with lock:
        lock.wait_for(lambda: any(p == "/inbound/ack" for p, _ in sidecar_calls), timeout=15)
    if not any(p == "/inbound/ack" for p, _ in sidecar_calls):
        fail("inbound delivery was never acknowledged")
    errors = [line for line in tail().splitlines()
              if "Native admission refused" in line
              or "[inline]" in line and any(w in line for w in ("ERROR", "Traceback", "rejected", "failed"))]
    if errors:
        fail("adapter logged errors during the turn:\n" + "\n".join(errors[-20:]))
    print("Hermes gateway e2e passed: inbound -> GatewayRunner -> model -> Inline reply + ack")
finally:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
    model_server.shutdown()
    sidecar_server.shutdown()
