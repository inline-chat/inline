import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

// Detailed / Friendly output through Hermes' public plugin hooks and send metadata. The
// gateway modules are stubbed to the surface the adapter uses; the sidecar is a recorder.
const script = String.raw`
import asyncio
import contextvars
import json
import os
import sys
import tempfile
import threading
import time
import types
from dataclasses import dataclass, field
from pathlib import Path

def module(name):
    created = types.ModuleType(name)
    sys.modules[name] = created
    return created

gateway = module("gateway")
config = module("gateway.config")
platforms = module("gateway.platforms")
base = module("gateway.platforms.base")
helpers = module("gateway.platforms.helpers")
session_context = module("gateway.session_context")
hermes_constants = module("hermes_constants")
home = Path(tempfile.mkdtemp(prefix="inline-hermes-activity-"))
hermes_constants.get_hermes_home = lambda: home
os.environ["HERMES_HOME"] = str(home)
os.environ["INLINE_SETTINGS_PATH"] = str(home / "settings.json")

class Platform(str):
    def __new__(cls, value):
        return str.__new__(cls, str(value))

@dataclass
class PlatformConfig:
    enabled: bool = True
    token: object = None
    extra: dict = field(default_factory=dict)

class BasePlatformAdapter:
    def __init__(self, config, platform):
        self.config = config
        self.platform = platform
        self.name = str(platform)
    def build_source(self, **kwargs):
        return types.SimpleNamespace(platform=self.platform, **kwargs)
    def truncate_message(self, text, max_len):
        return [text[i:i + max_len] for i in range(0, len(text), max_len)] or [""]
    def _is_sender_authorized(self, user_id, chat_type=None, chat_id=None, **kwargs):
        return True

class SendResult:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)

class MessageEvent:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)
    def is_command(self):
        return str(getattr(self, "text", "")).startswith("/")

config.Platform = Platform
config.PlatformConfig = PlatformConfig
base.BasePlatformAdapter = BasePlatformAdapter
base.MessageEvent = MessageEvent
base.MessageType = types.SimpleNamespace(TEXT="text", PHOTO="photo", VIDEO="video", VOICE="voice", DOCUMENT="document")
base.SendResult = SendResult
base.safe_url_for_log = lambda url: "[url]"
async def cache_file(url, ext=".bin", retries=2):
    return str(home / f"cached{ext}")
base.cache_image_from_url = cache_file
base.cache_audio_from_url = cache_file
helpers.strip_markdown = lambda text: text

# Hermes binds the turn's chat to context variables; hooks read them on their own threads.
session_vars = contextvars.ContextVar("session_vars", default={})
session_context.get_session_env = lambda name, default="": session_vars.get().get(name, default)
def bind(platform="inline", chat="10", thread="", user="u1"):
    session_vars.set({
        "HERMES_SESSION_PLATFORM": platform, "HERMES_SESSION_CHAT_ID": chat,
        "HERMES_SESSION_THREAD_ID": thread, "HERMES_SESSION_USER_ID": user,
    })

sys.path.insert(0, "plugin")
import inline.adapter as adapter_module
from inline.adapter import InlineAdapter, _register_activity_hooks, _INLINE_DISPLAY_DEFAULTS

assert _INLINE_DISPLAY_DEFAULTS["interim_assistant_messages"] is True
assert _INLINE_DISPLAY_DEFAULTS["tool_progress"] == "off"

class Ctx:
    def __init__(self):
        self.hooks = {}
    def register_hook(self, name, callback):
        self.hooks[name] = callback

ctx = Ctx()
_register_activity_hooks(ctx)
hooks = ctx.hooks
assert set(hooks) == {
    "pre_tool_call", "post_tool_call", "subagent_start", "subagent_stop",
    "pre_approval_request", "post_approval_response",
}

def make_adapter(mode="detailed", log=None, block=None):
    adapter = InlineAdapter(PlatformConfig(extra={"token": "fake", "allow_all": True, "context_history_limit": 0}))
    adapter._http_client = object()
    log = log if log is not None else []
    def post(path, body, timeout):
        if block is not None:
            block.wait(5)
        log.append((path, json.loads(json.dumps(body)), threading.get_ident()))
        if body.get("event", {}).get("type") == "turn.start":
            return {"ok": True, "result": {"mode": mode}}
        return {"ok": True, "result": {}}
    adapter._activity_post = post
    async def send_message(chat_id, content, reply_to=None, metadata=None, actions=None):
        log.append(("chat-send", {"chatId": chat_id, "text": content, "replyTo": reply_to, "metadata": metadata}, threading.get_ident()))
        return SendResult(success=True, message_id="m1", raw_response={})
    adapter._send_message = send_message
    return adapter, log

def processing_event(chat="10", thread=None, user="u1", text="hi", message_id="1"):
    return MessageEvent(
        text=text, message_id=message_id,
        source=types.SimpleNamespace(chat_id=chat, thread_id=thread, user_id=user, profile=None),
        raw_message={"kind": "message.new"},
    )

def events_of(log, turn_id=None):
    return [entry[1]["event"] for entry in log if entry[0] == "/activity" and (turn_id is None or entry[1]["turnId"] == turn_id)]

def wait_for(predicate, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    raise AssertionError("timed out")

async def detailed_turn():
    adapter, log = make_adapter()
    event = processing_event()
    await adapter.on_processing_start(event)
    bind()
    # Terminal: command, then its output tail, exit code and duration; the hook returns None.
    assert hooks["pre_tool_call"](tool_name="terminal", args={"command": "npm test"}, task_id="", session_id="s1", tool_call_id="c1", turn_id="") is None
    hooks["post_tool_call"](
        tool_name="terminal", args={"command": "npm test"}, result=json.dumps({"output": "1 failing\n", "exit_code": 1, "error": None}),
        task_id="", session_id="s1", tool_call_id="c1", turn_id="", duration_ms=1200, status="error", error_type="tool_error", error_message="exit 1",
    )
    # A sub-agent nests its own tools.
    hooks["pre_tool_call"](tool_name="delegate_task", args={"goal": "x"}, session_id="s1", tool_call_id="c2")
    hooks["subagent_start"](parent_session_id="s1", parent_turn_id="", parent_subagent_id=None, child_session_id="child-1", child_subagent_id="sa-1", child_role="leaf", child_goal="Investigate the flaky test\nwith details")
    hooks["pre_tool_call"](tool_name="read_file", args={"path": "/repo/src/a.ts"}, session_id="child-1", tool_call_id="k1")
    hooks["post_tool_call"](tool_name="read_file", args={"path": "/repo/src/a.ts"}, result="{}", session_id="child-1", tool_call_id="k1", duration_ms=5, status="ok")
    hooks["subagent_stop"](parent_session_id="s1", parent_turn_id="", child_session_id="child-1", child_role="leaf", child_summary="done", child_status="completed", tool_call_history=[], duration_ms=3000)
    hooks["post_tool_call"](tool_name="delegate_task", args={"goal": "x"}, result="{}", session_id="s1", tool_call_id="c2", duration_ms=3100, status="ok")
    # Approvals: a person's decision waits; a model's (smart) does not.
    hooks["pre_approval_request"](command="rm -rf build", description="", pattern_key="", pattern_keys=[], session_key="k", surface="gateway")
    hooks["post_approval_response"](command="rm -rf build", description="", pattern_key="", pattern_keys=[], session_key="k", surface="gateway", choice="once")
    hooks["pre_approval_request"](command="ls", surface="smart")
    hooks["post_approval_response"](command="ls", surface="smart", choice="smart_approve")
    # Plans, edits, web; no rows for clarify or Inline messages the agent sent itself.
    todos = [{"id": "1", "content": "Write tests", "status": "completed"}, {"id": "2", "content": "Ship", "status": "in_progress"}, {"id": "3", "content": "Old idea", "status": "cancelled"}]
    hooks["pre_tool_call"](tool_name="todo_list", args={"todos": todos}, session_id="s1", tool_call_id="c3")
    hooks["post_tool_call"](tool_name="todo_list", args={"todos": todos}, result=json.dumps({"todos": todos}), session_id="s1", tool_call_id="c3", status="ok")
    hooks["pre_tool_call"](tool_name="patch", args={"path": "src/a.ts", "old_string": "a", "new_string": "b"}, session_id="s1", tool_call_id="c4")
    hooks["post_tool_call"](tool_name="patch", args={"path": "src/a.ts"}, result=json.dumps({"success": True, "diff": "--- a\n+++ b\n-a\n+b", "files_modified": ["src/a.ts"]}), session_id="s1", tool_call_id="c4", status="ok")
    hooks["pre_tool_call"](tool_name="web_search", args={"query": "vitest flaky"}, session_id="s1", tool_call_id="c5")
    hooks["pre_tool_call"](tool_name="clarify", args={"question": "?"}, session_id="s1", tool_call_id="c6")
    hooks["pre_tool_call"](tool_name="inline", args={"action": "send_message", "text": "hey"}, session_id="s1", tool_call_id="c7")
    hooks["pre_tool_call"](tool_name="inline", args={"action": "get_history"}, session_id="s1", tool_call_id="c8")
    hooks["pre_tool_call"](tool_name="vision_analyze", args={"image_url": "secret"}, session_id="s1", tool_call_id="c9")

    # Commentary between tool calls folds into the progress message, off the chat.
    folded = await adapter.send("10", "Looking at the failing test", metadata={"_interim_send": True})
    assert folded.success is False and folded.raw_response == {"inlineActivity": "commentary"}
    assert adapter._send_retry_is_final(folded) is True
    # Hermes' own status sends and approval texts are untouched.
    await adapter.send("10", "Status", metadata={"_interim_send": True, "non_conversational": True})
    await adapter.send("10", "Approve?", metadata={"_interim_send": True, "is_approval_prompt": True})
    hooks["post_tool_call"](tool_name="web_search", args={"query": "vitest flaky"}, result="{}", session_id="s1", tool_call_id="c5", status="ok")

    # The answer: "Worked for" is flushed before the answer is sent.
    answer = await adapter.send("10", "Fixed it.")
    assert answer.success is True
    kinds = [entry[0] for entry in log]
    assert kinds[-2:] == ["/activity/flush", "chat-send"], kinds
    events = events_of(log)
    assert events[0] == {"type": "turn.start"} and log[0][1]["lazy"] is False and log[0][1]["target"] == {"chatId": "10"}
    assert events[-1] == {"type": "turn.end", "outcome": "success"}
    items = [e for e in events if e["type"] == "item"]
    by_id = {}
    for item in items:
        by_id.setdefault(item["id"], []).append(item)
    terminal_end = by_id["tool:c1"][-1]
    assert by_id["tool:c1"][0]["body"] == {"kind": "command", "command": "npm test"}
    assert terminal_end["state"] == "failed" and terminal_end["durationMs"] == 1200
    assert terminal_end["body"] == {"kind": "command", "command": "npm test", "output": "1 failing", "exitCode": 1}
    assert "tool:c2" not in by_id  # delegate_task draws through its sub-agents
    agent = by_id["agent:sa-1"]
    assert agent[0]["body"] == {"kind": "agent", "title": "Investigate the flaky test"} and "parent" not in agent[0]
    assert agent[-1]["state"] == "done" and agent[-1]["durationMs"] == 3000
    assert by_id["tool:k1"][0]["parent"] == "agent:sa-1" and by_id["tool:k1"][0]["body"] == {"kind": "read", "path": "/repo/src/a.ts"}
    waits = [e for e in events if e["type"] == "waiting"]
    assert waits == [{"type": "waiting", "waiting": True}, {"type": "waiting", "waiting": False}]
    assert "tool:c3" not in by_id and by_id["plan:s1"][-1]["state"] == "done"
    assert by_id["plan:s1"][-1]["body"] == {"kind": "plan", "steps": [
        {"text": "Write tests", "status": "completed"}, {"text": "Ship", "status": "in_progress"}, {"text": "Old idea (cancelled)", "status": "completed"}]}
    assert by_id["tool:c4"][-1]["body"] == {"kind": "edit", "files": [{"path": "src/a.ts", "change": "modified", "diff": "--- a\n+++ b\n-a\n+b"}]}
    assert by_id["tool:c5"][0]["body"] == {"kind": "web", "query": "vitest flaky"}
    assert "tool:c6" not in by_id and "tool:c7" not in by_id
    assert by_id["tool:c8"][0]["body"] == {"kind": "tool", "name": "inline", "title": "Inline: get history"}
    # Titles never come from arguments or output.
    assert by_id["tool:c9"][0]["body"] == {"kind": "tool", "name": "vision_analyze", "title": "Looked at an image"}
    commentary = [e for e in events if e["type"] == "commentary"]
    assert commentary == [{"type": "commentary", "text": "Looking at the failing test"}]
    # The commentary shows after the rows before it and before the next row.
    order = [e.get("id") or e["type"] for e in events]
    assert order.index("commentary") > order.index("tool:c9") and order.index("commentary") < len(order) - 1
    chat_sends = [entry[1]["text"] for entry in log if entry[0] == "chat-send"]
    assert chat_sends == ["Status", "Approve?", "Fixed it."], chat_sends
    # Hooks after the answer, and the processing-complete fallback, add nothing.
    before = len(log)
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "late"}, session_id="s1", tool_call_id="late")
    await adapter.on_processing_complete(event, types.SimpleNamespace(value="success"))
    await asyncio.sleep(0.05)
    assert len(log) == before
    adapter._activity_stop()

asyncio.run(detailed_turn())

async def hooks_never_do_io():
    release = threading.Event()
    adapter, log = make_adapter(block=release)
    event = processing_event()
    await adapter.on_processing_start(event)
    bind()
    audited = []
    in_hook = threading.local()
    def audit(name, args):
        if getattr(in_hook, "active", False) and (name.startswith("socket.") or name in {"open", "urllib.Request", "subprocess.Popen", "os.system"}):
            audited.append(name)
    sys.addaudithook(audit)
    caller = threading.get_ident()
    in_hook.active = True
    started = time.perf_counter()
    for index in range(50):
        result = hooks["pre_tool_call"](tool_name="terminal", args={"command": f"echo {index}"}, session_id="s1", tool_call_id=f"io{index}")
        assert result is None
    elapsed = time.perf_counter() - started
    in_hook.active = False
    # The worker is blocked on the sidecar; the hooks still returned at once, without I/O.
    assert elapsed < 0.2, elapsed
    assert audited == [], audited
    release.set()
    wait_for(lambda: len(events_of(log)) >= 51)
    assert all(entry[2] != caller for entry in log)
    adapter._activity_stop()

asyncio.run(hooks_never_do_io())

async def routing():
    log = []
    first, _ = make_adapter(log=log)
    second, _ = make_adapter(log=log)
    first_event = processing_event(chat="10", user="u1")
    second_event = processing_event(chat="10", user="u2", message_id="2")
    await first.on_processing_start(first_event)
    await second.on_processing_start(second_event)
    wait_for(lambda: len(events_of(log)) == 2)
    first_turn = first._activity_turn_for_send("10", None).turn_id
    second_turn = second._activity_turn_for_send("10", None).turn_id
    assert first_turn != second_turn
    # Another platform's session, and an Inline chat with no open turn, are ignored.
    bind(platform="telegram", chat="10", user="u1")
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "a"}, session_id="s", tool_call_id="r1")
    bind(chat="11", user="u1")
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "b"}, session_id="s", tool_call_id="r2")
    # Two open turns in one chat (per-user sessions, or two adapters) route by the session's user.
    bind(chat="10", user="u2")
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "for u2"}, session_id="s", tool_call_id="r3")
    bind(chat="10", user="u1")
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "for u1"}, session_id="s", tool_call_id="r4")
    wait_for(lambda: len(events_of(log)) == 4)
    assert [e["id"] for e in events_of(log, first_turn) if e["type"] == "item"] == ["tool:r4"]
    assert [e["id"] for e in events_of(log, second_turn) if e["type"] == "item"] == ["tool:r3"]
    # A send from another adapter never closes this adapter's turn.
    await second.send("10", "answer for u2")
    assert events_of(log, first_turn)[-1]["type"] == "item"
    assert events_of(log, second_turn)[-1] == {"type": "turn.end", "outcome": "success"}
    # The fallback close carries Hermes' outcome.
    await first.on_processing_complete(first_event, types.SimpleNamespace(value="cancelled"))
    wait_for(lambda: events_of(log, first_turn)[-1].get("type") == "turn.end")
    assert events_of(log, first_turn)[-1] == {"type": "turn.end", "outcome": "cancelled"}
    first._activity_stop()
    second._activity_stop()

asyncio.run(routing())

async def friendly_turn():
    adapter, log = make_adapter(mode="friendly")
    event = processing_event()
    await adapter.on_processing_start(event)
    bind()
    wait_for(lambda: adapter._activity_turn_for_send("10", None).mode_ready.is_set())
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "ls"}, session_id="s1", tool_call_id="f1")
    update = await adapter.send("10", "Checking the logs first.", metadata={"_interim_send": True})
    assert update.success is True
    await adapter.send("10", "All good.")
    sends = [entry[1]["text"] for entry in log if entry[0] == "chat-send"]
    assert sends == ["Checking the logs first.", "All good."]
    # Friendly keeps no progress: only the turn's start reached the sidecar.
    assert [e["type"] for e in events_of(log)] == ["turn.start"]
    adapter._activity_stop()

asyncio.run(friendly_turn())

async def commentary_that_is_the_answer():
    adapter, log = make_adapter()
    await adapter.on_processing_start(processing_event(thread="55"))
    # Hermes addresses a reply thread with thread_id metadata; progress posts in the thread.
    await adapter.send("10", "The answer is 42.", metadata={"_interim_send": True, "thread_id": "55"})
    await adapter.send("10", "The answer is 42.", metadata={"thread_id": "55", "notify": True})
    events = events_of(log)
    assert log[0][1]["target"] == {"chatId": "55"}
    # The interim text Hermes then sent as the answer is not drawn twice.
    assert [e["type"] for e in events] == ["turn.start", "turn.end"], events
    adapter._activity_stop()

asyncio.run(commentary_that_is_the_answer())

async def steer_split_and_busy_notice():
    adapter, log = make_adapter()
    handled = []
    async def chat_info(chat_id, **kwargs):
        return {"id": chat_id, "peer": {"type": {"oneofKind": "user", "user": {"userId": "u1"}}}}
    async def handle_message(event):
        handled.append(event)
    async def sidecar_call(path, body):
        return {"ok": True, "result": {}}
    adapter._get_chat_info = chat_info
    adapter.handle_message = handle_message
    adapter._sidecar_call = sidecar_call
    def dm(seq, text):
        return {"seq": seq, "chatId": "20", "sender": {"id": "u1", "firstName": "Ada"}, "message": {
            "id": f"dm-{seq}", "chatId": "20", "fromId": "u1", "message": text, "peerId": {"peer": {"oneofKind": "user"}},
        }}
    await adapter._dispatch_message(dm(1, "build it"))
    await adapter.on_processing_start(handled[-1])
    bind(chat="20")
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "make"}, session_id="s1", tool_call_id="b1")
    # A person's message mid-turn ends the progress message before Hermes sees it.
    await adapter._dispatch_message(dm(2, "also run the tests"))
    assert len(handled) == 2
    wait_for(lambda: any(e["type"] == "split" for e in events_of(log)))
    # Hermes' busy notice replies to that message: not this turn's answer.
    await adapter.send("20", "Got it, I'll fold that in.", reply_to="dm-2")
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "make test"}, session_id="s1", tool_call_id="b2")
    await adapter.send("20", "Built and tested.")
    order = [e.get("id") or e["type"] for e in events_of(log)]
    assert order == ["turn.start", "tool:b1", "split", "tool:b2", "turn.end"], order
    adapter._activity_stop()

asyncio.run(steer_split_and_busy_notice())

async def commands_and_failures():
    adapter, log = make_adapter()
    # A slash command opens its turn lazily: no "Working" unless work starts.
    await adapter.on_processing_start(processing_event(text="/help"))
    wait_for(lambda: len(log) == 1)
    assert log[0][1]["lazy"] is True
    await adapter.send("10", "Commands: ...")
    adapter._activity_stop()

    # An unreachable sidecar never blocks or breaks the turn: interim messages post as usual.
    broken = InlineAdapter(PlatformConfig(extra={"token": "fake"}))
    broken._http_client = object()
    def refuse(path, body, timeout):
        raise OSError("connection refused")
    broken._activity_post = refuse
    sent = []
    async def send_message(chat_id, content, reply_to=None, metadata=None, actions=None):
        sent.append(content)
        return SendResult(success=True, message_id="m", raw_response={})
    broken._send_message = send_message
    event = processing_event()
    await broken.on_processing_start(event)
    bind()
    hooks["pre_tool_call"](tool_name="terminal", args={"command": "ls"}, session_id="s", tool_call_id="x")
    assert (await broken.send("10", "update", metadata={"_interim_send": True})).success is True
    assert (await broken.send("10", "answer")).success is True
    assert sent == ["update", "answer"]
    broken._activity_stop()

    # Not connected (a one-shot sender): no turns at all.
    idle = InlineAdapter(PlatformConfig(extra={"token": "fake"}))
    await idle.on_processing_start(processing_event())
    assert idle._activity_pump is None

asyncio.run(commands_and_failures())

print("activity python ok")
`

describe("python adapter output modes", () => {
  it("draws Detailed progress from Hermes hooks and folds interim messages", () => {
    const result = spawnSync("python3", ["-"], {
      cwd: packageRoot,
      encoding: "utf8",
      input: script,
      env: {
        ...process.env,
        INLINE_TOKEN: "",
        INLINE_BOT_TOKEN: "",
        INLINE_EXPERIMENTAL_AGENT_ACTIVITY: "",
        INLINE_DROP_PENDING_ON_COLD_BOOT: "0",
      },
    })
    const detail = JSON.stringify({ status: result.status, stderr: result.stderr, stdout: result.stdout })
    expect(result.status, detail).toBe(0)
    expect(result.stdout).toContain("activity python ok")
  }, 60_000)
})
