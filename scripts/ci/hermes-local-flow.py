"""Packaged, normally started Hermes against the owned local Inline server.

Only the LLM is deterministic: an HTTP provider plus a pre-provider entry hold.
Gateway construction/startup, SDK checkpoints, authorization and SQLite writes
are real. Case success follows assertions, never merely a worker's exit code.
All fresh homes are retained; HOME and production credentials are untouched.
"""
from __future__ import annotations

import asyncio
from contextlib import closing
from dataclasses import asdict
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import inspect
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse
import uuid

SCENARIOS = (
    "hermes-real-host-inbound-and-persisted-reply",
    "hermes-acknowledged-pending-process-death-recovery",
    "hermes-pending-edited-current-source",
    "hermes-pending-deleted-source-settlement",
    "hermes-pending-revoked-access-settlement",
    "hermes-receiver-profile-mismatch-refused",
    "hermes-control-command-excluded-from-replay",
    "hermes-atomic-user-row-consumption-and-no-replay",
)


def write_json(path, data):
    Path(path).write_text(json.dumps(data, sort_keys=True, indent=2) + "\n")


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def local_url(value):
    parsed = urlparse(value)
    assert parsed.hostname in {"127.0.0.1", "localhost", "::1"}, "Only the owned local server is allowed"
    assert parsed.scheme in {"http", "https"} and parsed.port
    return value


def require_tracked_clean(source):
    # No VersionInfo fallback, external diff driver or untracked-file inference.
    # Nonzero status is uncertainty, never a clean-core result.
    for stage in ((), ("--cached",)):
        result = subprocess.run(["git", "diff", *stage, "--no-ext-diff", "--no-textconv", "--name-only"],
            cwd=source, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        assert result.returncode == 0 and not result.stdout, "Loaded core tracked cleanliness could not be verified"


def host_info():
    import gateway.platforms.base as base
    import hermes_state
    from hermes_cli import version_info
    source = Path(base.__file__).resolve().parents[2]
    assert Path(hermes_state.__file__).resolve().parent == source
    assert Path(version_info.__file__).resolve().parents[1] == source
    # The filtered PM checkout must have no project environment file to load.
    assert not (source / ".env").exists(), "Qualification requires a secret-free installed core source"
    require_tracked_clean(source)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    origin = subprocess.check_output(["git", "remote", "get-url", "origin"], cwd=source, text=True).strip()
    assert origin == "https://github.com/morajabi/hermes-agent.git", "Loaded core has an unqualified origin"
    assert re.fullmatch(r"[a-f0-9]{40}", head)
    version = version_info.get_version_info()
    assert version.commit == head, "Loaded version stamp and actual core disagree"
    assert base.BasePlatformAdapter.durable_intake_version == 1
    assert callable(getattr(hermes_state.SessionDB, "adopt_gateway_intake", None))
    return {"repository": "morajabi/hermes-agent", "sha": head, "intakeVersion": 1,
            "version": asdict(version)}, source


def snapshot(home):
    """One real read transaction: no reopen substitute for the OS-death test."""
    path = Path(home) / "state.db"
    if not path.exists():
        return {"intakes": [], "users": []}
    with closing(sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        rows = [dict(row) for row in db.execute("SELECT * FROM gateway_intake ORDER BY rowid")]
        users = []
        for row in db.execute("SELECT id, session_id, display_metadata FROM messages WHERE role = 'user'"):
            metadata = json.loads(row["display_metadata"] or "{}")
            users.append({"rowId": row["id"], "sessionId": row["session_id"],
                          "receiptIds": [item["receipt_id"] for item in metadata.get("gateway_intake", [])]})
        db.rollback()
    for row in rows:
        row["snapshot"] = json.loads(row.pop("snapshot_json"))
        row["owner"] = json.loads(row.pop("owner_json"))
    return {"intakes": rows, "users": users}


def row_for(home, receipt_id):
    rows = [row for row in snapshot(home)["intakes"] if row["receipt_id"] == receipt_id]
    assert len(rows) == 1, "The exact adopted physical receipt disappeared"
    return rows[0]


def user_rows(home, receipt_id):
    return [row for row in snapshot(home)["users"] if receipt_id in row["receiptIds"]]


def assert_atomic(home):
    view = snapshot(home)
    for row in view["intakes"]:
        matching = [item for item in view["users"] if row["receipt_id"] in item["receiptIds"]]
        if row["state"] == "consumed":
            assert len(matching) == 1 and matching[0]["sessionId"] == row["consumed_session_id"]
        else:
            assert not matching, "A pending/refused receipt escaped into an ordinary user row"
    return view


def text_digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def latest_user_text(body):
    messages = body.get("messages")
    assert isinstance(messages, list), "Provider request has no message list"
    latest = next((item for item in reversed(messages) if isinstance(item, dict) and item.get("role") == "user"), None)
    assert latest is not None, "Provider request has no current user message"
    content = latest.get("content")
    if isinstance(content, str):
        return content
    assert isinstance(content, list), "Current user message has no text content"
    return "\n".join(item["text"] for item in content if isinstance(item, dict)
                     and item.get("type") in {"text", "input_text"} and isinstance(item.get("text"), str))


class DeterministicProvider:
    """Real local OpenAI HTTP, and sanitized observation of the real writer TX."""
    def __init__(self, home, job):
        self.home, self.job = Path(home), job
        self.lock = threading.RLock()
        self.entries, self.calls, self.rejections, self.atomic_transactions = [], [], [], []
        self.pending_tx = []
        self.runner = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.respond({"object": "list", "data": [{"id": "ci-hermes-local", "object": "model"}]})

            def respond(self, data, status=200):
                payload = json.dumps(data).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_POST(self):
                assert self.path.rstrip("/") == "/v1/chat/completions", "Unexpected provider endpoint"
                length = int(self.headers.get("Content-Length", "0"))
                assert 0 < length < 4_000_000
                body = json.loads(self.rfile.read(length))
                with owner.lock:
                    ids = list(owner.entries[-1]["receiptIds"]) if owner.entries else []
                    kind = "auxiliary-title" if body.get("response_format", {}).get("json_schema", {}).get("name") == "session_title" else "conversation"
                    try:
                        assert ids, "Provider ran without its real ordinary-input admission"
                        view = assert_atomic(owner.home)
                        for receipt_id in ids:
                            row = next(row for row in view["intakes"] if row["receipt_id"] == receipt_id)
                            assert row["state"] == "consumed", "Provider began before atomic consumption"
                        proof = owner.verify_current_user(body, ids, view) if kind == "conversation" else {}
                    except (AssertionError, KeyError, TypeError, StopIteration) as error:
                        owner.rejections.append({"receiptIds": ids, "kind": kind, "failureClass": type(error).__name__})
                        owner.flush()
                        self.respond({"error": {"type": "qualification_input_rejected"}}, 422)
                        return
                    owner.calls.append({"receiptIds": ids, "kind": kind, "ordinaryRowConsumedBeforeHTTP": True, **proof})
                    owner.flush()
                # The real host can also issue its normal background title request.
                # It is a provider request, not another run_conversation admission.
                reply = json.dumps({"title": "Hermes local receiving qualification"}) if kind == "auxiliary-title" else owner.job["reply"]
                completion = {"id": "ci-" + uuid.uuid4().hex, "object": "chat.completion",
                              "created": int(time.time()), "model": "ci-hermes-local"}
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    chunk = {**completion, "object": "chat.completion.chunk", "choices": [
                        {"index": 0, "delta": {"role": "assistant", "content": reply}, "finish_reason": None}]}
                    self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    final = {**completion, "object": "chat.completion.chunk", "choices": [
                        {"index": 0, "delta": {}, "finish_reason": "stop"}]}
                    self.wfile.write(("data: " + json.dumps(final) + "\n\ndata: [DONE]\n\n").encode())
                else:
                    self.respond({**completion, "choices": [{"index": 0,
                        "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}],
                        "usage": {"prompt_tokens": 20, "completion_tokens": 5, "total_tokens": 25}})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/v1"

    def flush(self):
        write_json(self.job["observations"], {"entries": self.entries, "calls": self.calls,
                   "rejections": self.rejections, "atomicTransactions": self.atomic_transactions})

    def expected_input(self, ids, view=None):
        assert len(ids) == 1, "The physical FIFO input must retain its own receipt"
        view = snapshot(self.home) if view is None else view
        row = next(row for row in view["intakes"] if row["receipt_id"] == ids[0])
        text = row["snapshot"]["event"]["raw"]["message"]["message"]
        expected = next(item for item in self.job["expectedInputs"] if item["textSha256"] == text_digest(text))
        assert text == expected["marker"] and row["snapshot"]["event"]["admitted_text"] == text
        return expected, row

    def verify_current_user(self, body, ids, view):
        expected, _row = self.expected_input(ids, view)
        current = latest_user_text(body)
        assert re.search(r"(?<![\w-])" + re.escape(expected["marker"]) + r"(?![\w-])", current), "Frozen physical input is missing from the current user request"
        return {"currentUserInputVerified": True, "physicalInputSha256": expected["textSha256"],
                "currentUserTextSha256": text_digest(current)}

    def trace(self, statement):
        # sqlite's trace callback expands values. Never store/print SQL or model
        # content: keep only transaction boundaries and the two relevant writes.
        upper = statement.lstrip().upper()
        if upper.startswith("BEGIN"):
            self.pending_tx = ["begin"]
        elif upper.startswith("ROLLBACK"):
            self.pending_tx = []
        elif upper.startswith("INSERT INTO MESSAGES") and "gateway_intake" in statement:
            self.pending_tx.append("ordinary-user-row")
        elif upper.startswith("UPDATE GATEWAY_INTAKE") and "'consumed'" in statement:
            self.pending_tx.append("intake-consumed")
        elif upper.startswith("COMMIT"):
            if "ordinary-user-row" in self.pending_tx and "intake-consumed" in self.pending_tx:
                with self.lock:
                    self.atomic_transactions.append([*self.pending_tx, "commit"])
                    self.flush()
            self.pending_tx = []

    def install_llm_seam(self):
        from run_agent import AIAgent
        original = AIAgent.run_conversation
        signature = inspect.signature(original)
        provider = self

        def run(agent, *args, **kwargs):
            bound = signature.bind_partial(agent, *args, **kwargs)
            metadata = bound.arguments.get("persist_user_display_metadata") or {}
            receipts = metadata.get("gateway_intake", [])
            ids = [item["receipt_id"] for item in receipts]
            with provider.lock:
                entry = {"receiptIds": ids, "dispatchNonce": provider.runner._intake_dispatch_owner(), "providerStarted": False}
                provider.entries.append(entry)
                provider.flush()
                # Keep refused/malformed attempts visible: the test seam must
                # not hide a replay merely by stopping it before the original.
                assert receipts, "Physical local turn reached the LLM without an intake receipt"
                assert Path(agent._session_db.db_path).resolve() == provider.home / "state.db"
                expected, _row = provider.expected_input(ids)
                entry["physicalInputSha256"] = expected["textSha256"]
                provider.flush()
            if provider.job["hold"]:
                # The original LLM method has not run, so its real _persist_turn_start
                # cannot yet create a user row. SIGKILL ends this actual parent process.
                threading.Event().wait()
                raise AssertionError("The held LLM entry unexpectedly returned")
            agent._session_db._conn.set_trace_callback(provider.trace)
            try:
                result = original(agent, *args, **kwargs)
                with provider.lock:
                    provider.entries[-1]["providerStarted"] = True
                    provider.flush()
                return result
            finally:
                agent._session_db._conn.set_trace_callback(None)

        AIAgent.run_conversation = run

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def configuration(provider_url, *, environment=None):
    env = os.environ if environment is None else environment
    human = env["INLINE_E2E_HUMAN_ID"]
    home = Path(env["HERMES_HOME"])
    bot = env["INLINE_E2E_BOT_ID"]
    return {"model": {"provider": "custom", "default": "ci-hermes-local", "base_url": provider_url,
                      "api_key": "no-key-required"},
            "agent": {"max_iterations": 2}, "memory": {"memory_enabled": False},
            "gateway": {"multiplex_profiles": False, "group_sessions_per_user": False,
                        "streaming": {"enabled": False}},
            "platforms": {"inline": {"enabled": True, "token": env["INLINE_TOKEN"],
                "typing_indicator": False, "gateway_restart_notification": False,
                "base_url": env["INLINE_BASE_URL"], "sidecar_port": 0,
                "dm_policy": "allowlist", "allow_from": human, "group_allow_from": human,
                "require_mention": False, "reply_threads": "off", "context_backfill": "off",
                "reactions": False, "sync_commands": False, "text_debounce_seconds": 0,
                "state_path": str(home / f"sdk-{bot}.json"),
                "settings_path": str(home / f"settings-{bot}.json")}}}


async def worker(job):
    home = Path(os.environ["HERMES_HOME"]).resolve()
    assert not (home / ".env").exists()
    _host, source = host_info()
    provider = DeterministicProvider(home, job)
    write_json(home / "config.yaml", configuration(provider.url))
    provider.install_llm_seam()
    from hermes_cli.plugins import get_plugin_manager
    get_plugin_manager().discover_and_load()
    from gateway.run import GatewayRunner
    import gateway.run
    assert Path(gateway.run.__file__).resolve().parent.parent == source
    runner = GatewayRunner()  # ordinary constructor, config loader, DB and lifecycle owners
    provider.runner = runner
    try:
        assert await asyncio.wait_for(runner.start(), 40), "Normal startup failed"
        assert runner._running and not runner._startup_restore_in_progress
        adapter = next(value for key, value in runner.adapters.items() if key.value == "inline")
        assert adapter._me_id == os.environ["INLINE_E2E_BOT_ID"]
        assert adapter.durable_intake is True and adapter._durable_intake_available()
        loaded = Path(inspect.getfile(type(adapter))).resolve()
        packaged = Path(os.environ["INLINE_E2E_CONSUMER"]) / "node_modules/@inline-chat/hermes-agent-adapter/plugin/inline/adapter.py"
        assert hashlib.sha256(loaded.read_bytes()).digest() == hashlib.sha256(packaged.read_bytes()).digest(), "Loaded plugin is not the packed artifact"
        assert adapter._sidecar_proc is not None and adapter._sidecar_proc.poll() is None
        write_json(job["ready"], {"pid": os.getpid(), "nodePid": adapter._sidecar_proc.pid,
            "dispatchNonce": runner._intake_dispatch_owner(), "normalConstructor": True,
            "normalStart": True, "startupRestoreCompleted": True, "statePath": str(adapter._state_path),
            "authenticatedBotId": adapter._me_id, "loadedPlugin": str(loaded)})
        while not Path(job["stop"]).exists():
            query = read_json(job["query"])
            if query:
                try:
                    response = await adapter._sidecar_call("/history", {"target": {"chatId": query["chatId"]}, "limit": 100})
                    messages = response["result"]["messages"]
                    health = await adapter._sidecar_call("/healthz", {})
                    write_json(job["history"], {"sdkSyncState": health["result"]["diagnostics"]["sync"]["state"],
                        "messages": [{"id": str(item["id"]),
                        "fromId": str(item.get("fromId", "")), "text": item.get("message", "")} for item in messages]})
                except Exception as error:
                    write_json(job["history"], {"errorClass": type(error).__name__})
            write_json(job["status"], {"activeSessions": len(adapter._active_sessions),
                "liveTasks": sum(not task.done() for task in adapter._session_tasks.values())})
            await asyncio.sleep(0.05)
    finally:
        try:
            await asyncio.wait_for(runner.stop(), 15)
        finally:
            runner.session_store.close_all_db_handles()
            provider.close()


def child_environment(home, *, other=False):
    from hermes_constants import get_default_hermes_root
    # Retain HOME verbatim; carry only the local-server credentials minted by CI.
    keep = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "TMPDIR", "LANG", "LC_ALL", "TZ") if key in os.environ}
    for key in ("INLINE_NODE_BIN", "INLINE_BASE_URL", "INLINE_E2E_BASE_URL", "INLINE_E2E_CONSUMER",
                "INLINE_E2E_HUMAN_TOKEN", "INLINE_E2E_HUMAN_ID", "INLINE_E2E_SOURCE_SHA",
                "INLINE_E2E_HERMES_ARTIFACT_SHA256", "HERMES_BIN", "HERMES_PYTHON_BIN"):
        keep[key] = os.environ[key]
    # The installer uses this alias; never let it select an ambient host.
    assert Path(keep["HERMES_BIN"]).resolve() == (Path(sys.executable).parent / "hermes").resolve(), \
        "Hermes launcher must belong to the qualified Python environment"
    keep["INLINE_HERMES_BIN"] = keep["HERMES_BIN"]
    keep.update(HERMES_HOME=str(home), HERMES_RUNTIME_DIR=str(get_default_hermes_root(home=home) / "tools"),
                INLINE_TOKEN=os.environ["INLINE_E2E_OTHER_BOT_TOKEN" if other else "INLINE_TOKEN"],
                INLINE_E2E_BOT_ID=os.environ["INLINE_E2E_OTHER_BOT_ID" if other else "INLINE_E2E_BOT_ID"])
    return keep


async def command(*args, env, stdin=None, timeout=30):
    child = await asyncio.create_subprocess_exec(*args, env=env,
        cwd=os.environ["INLINE_E2E_CONSUMER"], stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, _err = await asyncio.wait_for(child.communicate(stdin), timeout)
        assert child.returncode == 0, "Local setup/human operation failed (credential diagnostics suppressed)"
        return out.decode()
    finally:
        if child.returncode is None:
            child.kill()
            await child.wait()


async def human(operation):
    out = await command(os.environ["INLINE_NODE_BIN"], str(Path(os.environ["INLINE_E2E_CONSUMER"]) / "hermes-human.mjs"),
        env=child_environment(Path(os.environ["HERMES_HOME"])), stdin=json.dumps(operation).encode())
    lines = [line[len("HERMES_HUMAN_RESULT="):] for line in out.splitlines() if line.startswith("HERMES_HUMAN_RESULT=")]
    assert len(lines) == 1
    return json.loads(lines[0])


async def wait_for(read, label, *, child=None, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if child is not None:
            assert child.returncode is None, label + ": receiver exited before assertion"
        value = read()
        if value:
            return value
        await asyncio.sleep(0.05)
    raise AssertionError(label + " timed out")


class Receiver:
    def __init__(self, home, *, hold=False, other=False, expected_inputs=()):
        self.home, self.hold, self.other = home, hold, other
        self.identifier = uuid.uuid4().hex[:12]
        self.job = {name: str(home / f"{self.identifier}-{name}.json") for name in
                    ("ready", "observations", "query", "history", "status", "stop")}
        # The controller chooses these before startup/send; never learn an
        # expected marker from the provider's request or the admitted payload.
        self.job.update(hold=hold, reply="ci-hermes-reply-" + self.identifier,
                        expectedInputs=[{"marker": text, "textSha256": text_digest(text)} for text in expected_inputs])
        self.path = home / f"{self.identifier}-job.json"
        write_json(self.path, self.job)
        self.child = None
        self.log = None

    async def start(self):
        self.log = (self.home / f"{self.identifier}-worker.log").open("wb")
        self.child = await asyncio.create_subprocess_exec(sys.executable, str(Path(__file__).resolve()),
            "worker", str(self.path), env=child_environment(self.home, other=self.other),
            cwd=os.environ["INLINE_E2E_CONSUMER"], stdout=self.log, stderr=self.log)
        self.ready = await wait_for(lambda: read_json(self.job["ready"]), "normal runner startup", child=self.child, timeout=45)
        return self

    def observations(self):
        return read_json(self.job["observations"], {"entries": [], "calls": [], "atomicTransactions": []})

    async def kill(self):
        self.child.kill()  # actual SIGKILL of Hermes parent, not an in-process close/reopen
        assert await asyncio.wait_for(self.child.wait(), 10) == -signal.SIGKILL
        node_pid = self.ready["nodePid"]
        def exited():
            try:
                os.kill(node_pid, 0)
                return False
            except ProcessLookupError:
                return True
        await wait_for(exited, "managed sidecar exit after actual parent death", timeout=15)
        self.log.close()

    async def close(self):
        if self.child is not None and self.child.returncode is None:
            write_json(self.job["stop"], {"stop": True})
            try:
                await asyncio.wait_for(self.child.wait(), 20)
                assert self.child.returncode == 0, "Normal receiver shutdown failed"
            finally:
                if self.child.returncode is None:
                    self.child.kill()
                    await self.child.wait()
        if self.log is not None and not self.log.closed:
            self.log.close()

    async def receipt(self, physical):
        def ready():
            rows = [row for row in snapshot(self.home)["intakes"] if
                    row["snapshot"]["physical_chat_id"] == physical["chatId"] and
                    row["snapshot"]["physical_message_id"] == physical["messageId"]]
            return rows[0] if len(rows) == 1 else None
        row = await wait_for(ready, "physical durable receipt", child=self.child)
        raw_text = row["snapshot"]["event"]["raw"]["message"]["message"]
        assert physical["textSha256"] == text_digest(raw_text)
        assert any(item["textSha256"] == physical["textSha256"] for item in self.job["expectedInputs"])
        return row

    async def pending_ack(self, physical):
        row = await self.receipt(physical)
        seq = int(row["snapshot"]["event"]["raw"]["seq"])
        assert seq > 0 and seq == physical["seq"]
        def acked():
            state = read_json(self.ready["statePath"], {})
            if state:
                assert state["inlineAccount"]["botUserId"] == self.ready["authenticatedBotId"]
            return int(state.get("lastSeqByChatId", {}).get(physical["chatId"], 0)) >= seq
        await wait_for(acked, "actual durable SDK checkpoint", child=self.child)
        await wait_for(lambda: any(row["receipt_id"] in item["receiptIds"] and item.get("physicalInputSha256") == physical["textSha256"]
                                  for item in self.observations()["entries"]),
                       "held actual LLM entry", child=self.child)
        current = row_for(self.home, row["receipt_id"])
        assert current["state"] == "pending" and current["consumed_session_id"] is None
        assert not user_rows(self.home, row["receipt_id"]) and not self.observations()["calls"]
        assert current["dispatch_owner"] == self.ready["dispatchNonce"]
        return current, seq

    async def reply(self, physical, receipt_id):
        write_json(self.job["query"], {"chatId": physical["chatId"]})
        def persisted():
            messages = read_json(self.job["history"], {}).get("messages", [])
            replies = [item for item in messages if item["text"] == self.job["reply"]]
            if not replies:
                return None
            assert len(replies) == 1 and replies[0]["fromId"] == self.ready["authenticatedBotId"]
            return replies[0]
        reply = await wait_for(persisted, "one persisted public bot reply", child=self.child)
        await wait_for(lambda: read_json(self.job["status"], {}).get("liveTasks") == 0,
                       "ordinary turn lifecycle completion", child=self.child)
        row = row_for(self.home, receipt_id)
        assert row["state"] == "consumed" and row["dispatch_owner"] is None
        assert len(user_rows(self.home, receipt_id)) == 1
        observations = self.observations()
        assert sum(receipt_id in entry["receiptIds"] for entry in observations["entries"]) == 1
        assert sum(receipt_id in call["receiptIds"] and call["kind"] == "conversation"
                   for call in observations["calls"]) == 1
        call = next(call for call in observations["calls"] if receipt_id in call["receiptIds"] and call["kind"] == "conversation")
        assert call["currentUserInputVerified"] is True and call["physicalInputSha256"] == physical["textSha256"]
        public_outputs = [item for item in read_json(self.job["history"])["messages"]
                          if item["fromId"] == self.ready["authenticatedBotId"]
                          and int(item["id"]) > int(physical["messageId"])]
        assert len(public_outputs) == 1 and public_outputs[0]["id"] == reply["id"], "Duplicate/error public output followed the one physical input"
        assert observations["atomicTransactions"], "No real writer transaction contained both row and consumption"
        assert_atomic(self.home)
        return reply


async def fresh_home():
    from hermes_constants import get_default_hermes_root
    # Normal named profiles isolate journals while sharing the caller's prepared PM root.
    root = get_default_hermes_root(home=os.environ["HERMES_HOME"]).resolve()
    assert root == Path(os.environ["HERMES_HOME"]).resolve(), "The caller must supply its fresh default root"
    home = root / "profiles" / ("c" + uuid.uuid4().hex[:8])
    home.mkdir(parents=True)
    env = child_environment(home)
    write_json(home / "config.yaml", configuration("http://127.0.0.1:9/v1", environment=env))
    consumer = Path(os.environ["INLINE_E2E_CONSUMER"])
    await command(os.environ["INLINE_NODE_BIN"], str(consumer / "node_modules/.bin/inline-hermes"),
                  "install", "--hermes-home", str(home), "--json", env=env)
    await command(env["HERMES_BIN"], "plugins", "enable", "inline-platform", env=env)
    return home


async def assert_refused(receiver, old):
    receipt_id = old["receipt_id"]
    await wait_for(lambda: row_for(receiver.home, receipt_id)["state"] == "refused",
                   "exact old receipt terminal refusal", child=receiver.child)
    assert not user_rows(receiver.home, receipt_id)
    assert all(item["receiptIds"] and receipt_id not in item["receiptIds"] for item in receiver.observations()["entries"])
    assert all(receipt_id not in item["receiptIds"] for item in receiver.observations()["calls"])
    assert receiver.ready["dispatchNonce"] != old["dispatch_owner"]
    assert_atomic(receiver.home)
    return {"receiptId": receipt_id, "oldState": "refused", "oldOrdinaryRows": 0,
            "oldProviderCalls": 0, "newDispatchNonce": receiver.ready["dispatchNonce"] != old["dispatch_owner"]}


async def main():
    assert os.environ.get("INLINE_SIDECAR_TEST_MOCK") != "1"
    local_url(os.environ["INLINE_BASE_URL"])
    local_url(os.environ["INLINE_E2E_BASE_URL"])
    host, _source = host_info()
    source_sha, artifact = os.environ["INLINE_E2E_SOURCE_SHA"], os.environ["INLINE_E2E_HERMES_ARTIFACT_SHA256"]
    assert re.fullmatch(r"[a-f0-9]{40}", source_sha) and re.fullmatch(r"[a-f0-9]{64}", artifact)
    report = {"sourceSha": source_sha, "host": host,
              "adapter": {"name": "@inline-chat/hermes-agent-adapter", "sha256": artifact}, "scenarios": []}
    destination = Path(os.environ["INLINE_E2E_HERMES_REPORT"])
    active = []

    def passed(name, detail):
        assert name in SCENARIOS and not any(item["scenario"] == name for item in report["scenarios"])
        report["scenarios"].append({"scenario": name, "status": "passed", **detail})
        write_json(destination, report)

    async def start(home, **kwargs):
        receiver = Receiver(home, **kwargs)
        active.append(receiver)
        return await receiver.start()

    try:
        # Reserve time inside the caller's 240s deadline for owned-child cleanup.
        async with asyncio.timeout(210):
            home = await fresh_home()
            normal_text = "ci-hermes-normal-" + uuid.uuid4().hex
            normal = await start(home, expected_inputs=(normal_text,))
            physical = await human({"kind": "send", "text": normal_text})
            receipt = await normal.receipt(physical)
            reply = await normal.reply(physical, receipt["receipt_id"])
            await normal.close()
            passed(SCENARIOS[0], {"normalConstructor": True, "normalStart": True, "profileHome": str(home),
                "receiptId": receipt["receipt_id"], "ordinaryRows": 1, "publicReplyId": reply["id"],
                "currentUserInputVerified": True, "physicalInputSha256": physical["textSha256"]})

            home = await fresh_home()
            frozen_text = "ci-hermes-process-death-" + uuid.uuid4().hex
            held = await start(home, hold=True, expected_inputs=(frozen_text,))
            physical = await human({"kind": "send", "text": frozen_text})
            old, seq = await held.pending_ack(physical)
            await held.kill()
            assert row_for(home, old["receipt_id"])["state"] == "pending" and not user_rows(home, old["receipt_id"])
            resumed = await start(home, expected_inputs=(frozen_text,))
            assert resumed.ready["dispatchNonce"] != old["dispatch_owner"]
            reply = await resumed.reply(physical, old["receipt_id"])
            await resumed.close()
            passed(SCENARIOS[1], {"profileHome": str(home), "receiptId": old["receipt_id"],
                "sdkCheckpointSeqBeforeKill": seq, "pendingBeforeAndAfterSIGKILL": True,
                "ordinaryRowsBeforeKill": 0, "hermesExitSignal": "SIGKILL", "newDispatchNonce": True,
                "normalStartupRecovery": True, "ordinaryRowsAfterRecovery": 1, "publicReplyId": reply["id"],
                "currentUserInputVerified": True, "physicalInputSha256": physical["textSha256"]})
            again = await start(home)
            write_json(again.job["query"], {"chatId": physical["chatId"]})
            history = await wait_for(lambda: (value if (value := read_json(again.job["history"], {})).get("sdkSyncState") == "live" else None),
                                    "live SDK and persisted reply after another normal startup", child=again.child)
            assert sum(item["id"] == reply["id"] for item in history["messages"]) == 1
            await asyncio.sleep(2)
            assert not again.observations()["entries"] and not again.observations()["calls"]
            assert row_for(home, old["receipt_id"])["state"] == "consumed" and len(user_rows(home, old["receipt_id"])) == 1
            assert_atomic(home)
            await again.close()
            passed(SCENARIOS[7], {"receiptId": old["receipt_id"], "sameWriterTransaction": True,
                "ordinaryRows": 1, "providerCallsAfterConsumedStartup": 0, "publicReplyId": reply["id"],
                "sdkSyncState": "live", "noReplayObservationSeconds": 2})

            for name, change in ((SCENARIOS[2], "edit"), (SCENARIOS[3], "delete"),
                                 (SCENARIOS[4], "revoke-bot"), (SCENARIOS[5], "other-receiver")):
                home = await fresh_home()
                participants = {"kind": "create-private-chat", "botId": os.environ["INLINE_E2E_BOT_ID"]}
                if change == "other-receiver":
                    participants["otherBotId"] = os.environ["INLINE_E2E_OTHER_BOT_ID"]
                chat = await human(participants)
                frozen_text = "ci-hermes-source-" + uuid.uuid4().hex
                edited_text = "ci-hermes-authoritative-edit-" + uuid.uuid4().hex
                held = await start(home, hold=True, expected_inputs=(frozen_text,))
                physical = await human({"kind": "send", "chatId": chat["chatId"], "text": frozen_text})
                old, seq = await held.pending_ack(physical)
                await held.kill()
                if change != "other-receiver":
                    operation = {"kind": change, **physical, "botId": os.environ["INLINE_E2E_BOT_ID"]}
                    if change == "edit":
                        operation["text"] = edited_text
                    proof = await human(operation)
                    assert proof.get({"edit": "edited", "delete": "deleted", "revoke-bot": "accessRevoked"}[change]) is True
                resumed = await start(home, other=change == "other-receiver",
                                      expected_inputs=(frozen_text, edited_text) if change == "edit" else (frozen_text,))
                detail = await assert_refused(resumed, old)
                detail.update(profileHome=str(home), physicalChatId=physical["chatId"], physicalMessageId=physical["messageId"],
                    sdkCheckpointSeqBeforeKill=seq, currentSourceMutation=change, normalStartupRecovery=True)
                if change == "other-receiver":
                    assert resumed.ready["authenticatedBotId"] != os.environ["INLINE_E2E_BOT_ID"]
                    detail["differentAuthenticatedReceiver"] = True
                    write_json(resumed.job["query"], {"chatId": physical["chatId"]})
                    current = await wait_for(lambda: read_json(resumed.job["history"], {}).get("messages"),
                        "different receiver's actual public source access", child=resumed.child)
                    assert any(item["id"] == physical["messageId"] and item["fromId"] == os.environ["INLINE_E2E_HUMAN_ID"]
                               for item in current)
                    detail["currentSourceReadableByDifferentReceiver"] = True
                await resumed.close()
                passed(name, detail)

            home = await fresh_home()
            frozen_text = "ci-hermes-stop-pending-" + uuid.uuid4().hex
            allowed_text = "ci-hermes-after-stop-" + uuid.uuid4().hex
            held = await start(home, hold=True, expected_inputs=(frozen_text,))
            physical = await human({"kind": "send", "text": frozen_text})
            old, seq = await held.pending_ack(physical)
            control = await human({"kind": "send", "chatId": physical["chatId"], "text": "/stop"})
            await wait_for(lambda: row_for(home, old["receipt_id"])["state"] == "refused", "real stop refusal", child=held.child)
            assert control["seq"] > seq
            await wait_for(lambda: int(read_json(held.ready["statePath"], {}).get("lastSeqByChatId", {}).get(physical["chatId"], 0)) >= control["seq"],
                           "control SDK checkpoint", child=held.child)
            assert not any(row["snapshot"]["physical_message_id"] == control["messageId"] and
                           row["snapshot"]["physical_chat_id"] == control["chatId"] for row in snapshot(home)["intakes"])
            await held.kill()
            resumed = await start(home, expected_inputs=(frozen_text, allowed_text))
            detail = await assert_refused(resumed, old)
            assert not resumed.observations()["entries"] and not resumed.observations()["calls"]
            allowed = await human({"kind": "send", "chatId": physical["chatId"], "text": allowed_text})
            allowed_receipt = await resumed.receipt(allowed)
            allowed_reply = await resumed.reply(allowed, allowed_receipt["receipt_id"])
            assert not any((row["snapshot"]["physical_chat_id"], row["snapshot"]["physical_message_id"]) ==
                           (physical["chatId"], control["messageId"]) for row in snapshot(home)["intakes"])
            await resumed.close()
            passed(SCENARIOS[6], {**detail, "controlMessageId": control["messageId"], "controlReceiptCount": 0,
                "controlSdkCheckpointSeqBeforeKill": control["seq"], "controlReplayProviderCalls": 0,
                "positiveControlReceiptId": allowed_receipt["receipt_id"],
                "positiveControlPublicReplyId": allowed_reply["id"], "currentUserInputVerified": True,
                "physicalInputSha256": allowed["textSha256"]})
        assert {item["scenario"] for item in report["scenarios"]} == set(SCENARIOS)
    except BaseException as error:
        for name in SCENARIOS:
            if not any(item["scenario"] == name for item in report["scenarios"]):
                report["scenarios"].append({"scenario": name, "status": "failed", "failureClass": type(error).__name__,
                    "reason": "No success assertion completed; consult retained local worker evidence"})
        write_json(destination, report)
        raise
    finally:
        for receiver in reversed(active):
            await receiver.close()
    write_json(destination, report)
    print("Packaged normal Hermes startup: all eight observed local receiving cases passed (deterministic LLM only).")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "worker":
        asyncio.run(worker(read_json(sys.argv[2])))
    else:
        asyncio.run(main())
