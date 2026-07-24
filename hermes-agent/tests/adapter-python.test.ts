import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const nodeBin = spawnSync("which", ["node"], { encoding: "utf8" }).stdout.trim() || "node"

const script = String.raw`
import sys
import types
import asyncio
import contextlib
import io
import os
import inspect
import argparse
import json
import socket
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

gateway = types.ModuleType("gateway")
config = types.ModuleType("gateway.config")
display_config = types.ModuleType("gateway.display_config")
platforms = types.ModuleType("gateway.platforms")
base = types.ModuleType("gateway.platforms.base")
helpers = types.ModuleType("gateway.platforms.helpers")
httpx = types.ModuleType("httpx")
tools = types.ModuleType("tools")
approval = types.ModuleType("tools.approval")
slash_confirm = types.ModuleType("tools.slash_confirm")
clarify_gateway = types.ModuleType("tools.clarify_gateway")
hermes_cli = types.ModuleType("hermes_cli")
commands = types.ModuleType("hermes_cli.commands")
model_cost_guard = types.ModuleType("hermes_cli.model_cost_guard")
gateway_cli = types.ModuleType("hermes_cli.gateway")
setup_cli = types.ModuleType("hermes_cli.setup")
hermes_constants = types.ModuleType("hermes_constants")

setup_saved_env = {}
setup_config_writes = []
setup_platform_enabled = {"inline": False}
setup_prompt_values = []
setup_yes_no_values = []

gateway_cli.get_env_value = lambda key: setup_saved_env.get(key, "")
gateway_cli.save_env_value = lambda key, value: setup_saved_env.__setitem__(key, value)
def write_platform_config_field(platform, field, value, raw=False):
    setup_config_writes.append((platform, field, value, raw))
    if field == "enabled":
        setup_platform_enabled[platform] = value
gateway_cli.write_platform_config_field = write_platform_config_field
setup_cli.print_header = lambda value: print(value)
setup_cli.print_info = lambda value: print(value)
setup_cli.print_success = lambda value: print(value)
setup_cli.print_warning = lambda value: print(value)
setup_cli.prompt = lambda message, default="", password=False: (
    setup_prompt_values.pop(0) if setup_prompt_values else default
)
setup_cli.prompt_yes_no = lambda message, default=False: (
    setup_yes_no_values.pop(0) if setup_yes_no_values else default
)

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
        self.connected = False

    def truncate_message(self, text, max_len):
        return [text[i:i + max_len] for i in range(0, len(text), max_len)] or [""]

    def validate_media_delivery_path(self, path):
        return str(path) if str(path).strip() else None

    def build_source(self, **kwargs):
        return types.SimpleNamespace(platform=self.platform, **kwargs)

    def _mark_connected(self):
        self.connected = True

    def _mark_disconnected(self):
        self.connected = False

    def _set_fatal_error(self, code, message, retryable):
        self.fatal_error = (code, message, retryable)

class MessageEvent:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)

class MessageType:
    TEXT = "text"
    PHOTO = "photo"
    VIDEO = "video"
    VOICE = "voice"
    DOCUMENT = "document"

class SendResult:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)

config.Platform = Platform
config.PlatformConfig = PlatformConfig
display_config._PLATFORM_DEFAULTS = {}
base.BasePlatformAdapter = BasePlatformAdapter
base.MessageEvent = MessageEvent
base.MessageType = MessageType
base.SendResult = SendResult
helpers.strip_markdown = lambda text: text

def _cached_file(name, ext):
    path = Path(tempfile.gettempdir()) / f"inline-hermes-{name}{ext}"
    path.write_bytes(b"cached")
    return str(path)

async def cache_image_from_url(url, ext=".jpg", retries=2):
    return _cached_file("image", ext)

async def cache_audio_from_url(url, ext=".ogg", retries=2):
    return _cached_file("audio", ext)

base.cache_image_from_url = cache_image_from_url
base.cache_audio_from_url = cache_audio_from_url
base.resolve_channel_prompt = lambda extra, channel_id, parent_id=None: (
    ((extra or {}).get("channel_prompts") or {}).get(channel_id)
    or ((extra or {}).get("channel_prompts") or {}).get(parent_id)
)

def resolve_channel_skills(extra, channel_id, parent_id=None):
    ids = {str(channel_id)}
    if parent_id:
        ids.add(str(parent_id))
    for entry in ((extra or {}).get("channel_skill_bindings") or []):
        if str(entry.get("id") or "") not in ids:
            continue
        skills = entry.get("skills") or entry.get("skill")
        if isinstance(skills, str):
            return [skills] if skills.strip() else None
        if isinstance(skills, list):
            return [skill for skill in skills if isinstance(skill, str) and skill.strip()] or None
    return None

base.resolve_channel_skills = resolve_channel_skills
hermes_constants.find_node_executable = lambda command: f"/hermes/{command}"
hermes_constants.with_hermes_node_path = lambda env=None: {**(env or {}), "PATH": "/hermes/bin"}
commands.telegram_menu_commands = lambda max_commands=100: ([
    ("help", "Show help"),
    ("threads", "Duplicate Inline command"),
    ("model", "Switch model"),
    ("update", "Update Hermes"),
    ("bad-name", "Hyphenated command"),
][:max_commands], max(0, 5 - max_commands))

class HttpxResponse:
    def __init__(self, status_code, text):
        self.status_code = status_code
        self.text = text

    def json(self):
        return json.loads(self.text or "{}")

def _http_post(url, body, headers):
    data = None if body is None else json.dumps(body).encode("utf8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "content-type": "application/json; charset=utf-8",
            **(headers or {}),
        },
        method="POST",
    )
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=3) as response:
            return HttpxResponse(response.status, response.read().decode("utf8"))
    except urllib.error.HTTPError as exc:
        return HttpxResponse(exc.code, exc.read().decode("utf8"))

class HttpxStreamResponse:
    status_code = 200

    async def aiter_lines(self):
        while True:
            await asyncio.sleep(3600)
            if False:
                yield ""

class HttpxStreamContext:
    async def __aenter__(self):
        return HttpxStreamResponse()

    async def __aexit__(self, exc_type, exc, tb):
        return False

class AsyncClient:
    def __init__(self, *args, **kwargs):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        await self.aclose()
        return False

    async def post(self, url, json=None, headers=None, timeout=None):
        return await asyncio.to_thread(_http_post, url, json, headers)

    def stream(self, method, url, headers=None, timeout=None):
        return HttpxStreamContext()

    async def aclose(self):
        pass

httpx.AsyncClient = AsyncClient

sys.modules["gateway"] = gateway
sys.modules["gateway.config"] = config
sys.modules["gateway.display_config"] = display_config
sys.modules["gateway.platforms"] = platforms
sys.modules["gateway.platforms.base"] = base
sys.modules["gateway.platforms.helpers"] = helpers
sys.modules["httpx"] = httpx
sys.modules["tools"] = tools
sys.modules["tools.approval"] = approval
sys.modules["tools.slash_confirm"] = slash_confirm
sys.modules["tools.clarify_gateway"] = clarify_gateway
sys.modules["hermes_cli"] = hermes_cli
sys.modules["hermes_cli.commands"] = commands
sys.modules["hermes_cli.model_cost_guard"] = model_cost_guard
sys.modules["hermes_cli.gateway"] = gateway_cli
sys.modules["hermes_cli.setup"] = setup_cli
sys.modules["hermes_constants"] = hermes_constants
gateway.display_config = display_config
tools.approval = approval
tools.slash_confirm = slash_confirm
tools.clarify_gateway = clarify_gateway
hermes_cli.commands = commands
hermes_cli.model_cost_guard = model_cost_guard
hermes_cli.gateway = gateway_cli
hermes_cli.setup = setup_cli
test_settings_dir = Path(tempfile.mkdtemp(prefix="inline-hermes-settings-"))
os.environ["INLINE_SETTINGS_PATH"] = str(test_settings_dir / "adapter-settings.json")
sys.path.insert(0, "plugin")

from inline.adapter import InlineAdapter, _apply_yaml_config, _env_enablement, _inline_menu_commands, _install_inline_display_defaults, _standalone_send, _target_from_chat_id
from inline.adapter import register, validate_config
from inline import cli as inline_cli
from inline import tools as inline_tools

base_extra = {"token": "fake", "context_history_limit": 0}
assert validate_config(PlatformConfig(token="top-level-token"))
token_only = InlineAdapter(PlatformConfig(token="top-level-token"))
assert token_only._token == "top-level-token"

menu_commands, hidden_commands = _inline_menu_commands(100)
assert hidden_commands == 0
menu_names = [entry["command"] for entry in menu_commands]
assert menu_names == ["threads", "help", "model", "update", "bad_name"]
assert menu_commands[0]["description"] == "Configure Inline reply-thread routing"
assert menu_commands[3]["description"] == "Update Hermes"
assert all("/" not in name and "-" not in name for name in menu_names)

os.environ["INLINE_CUSTOM_TOKEN"] = "custom-token"
env_ref_token = "$" + "{INLINE_CUSTOM_TOKEN}"
assert validate_config(PlatformConfig(token=env_ref_token))
env_ref = InlineAdapter(PlatformConfig(token=env_ref_token))
assert env_ref._token == "custom-token"
os.environ.pop("INLINE_CUSTOM_TOKEN", None)
assert not validate_config(PlatformConfig(token=env_ref_token))

saved_inline_token = os.environ.pop("INLINE_TOKEN", None)
saved_inline_bot_token = os.environ.pop("INLINE_BOT_TOKEN", None)
saved_inline_base_url = os.environ.pop("INLINE_BASE_URL", None)
try:
    assert _env_enablement() is None
    os.environ["INLINE_BOT_TOKEN"] = "bot-token"
    os.environ["INLINE_BASE_URL"] = "https://inline.example"
    seeded_env = _env_enablement()
    assert seeded_env["token"] == "bot-token"
    assert seeded_env["base_url"] == "https://inline.example"
finally:
    if saved_inline_token is None:
        os.environ.pop("INLINE_TOKEN", None)
    else:
        os.environ["INLINE_TOKEN"] = saved_inline_token
    if saved_inline_bot_token is None:
        os.environ.pop("INLINE_BOT_TOKEN", None)
    else:
        os.environ["INLINE_BOT_TOKEN"] = saved_inline_bot_token
    if saved_inline_base_url is None:
        os.environ.pop("INLINE_BASE_URL", None)
    else:
        os.environ["INLINE_BASE_URL"] = saved_inline_base_url

class RegistryContext:
    def __init__(self):
        self.platform = None
        self.cli = None
        self.tool = None
        self.commands = []

    def register_platform(self, **kwargs):
        self.platform = kwargs

    def register_command(self, name, handler, description="", args_hint=""):
        self.commands.append({
            "name": name,
            "handler": handler,
            "description": description,
            "args_hint": args_hint,
        })

    def register_cli_command(self, **kwargs):
        self.cli = kwargs

    def register_tool(self, **kwargs):
        self.tool = kwargs

ctx = RegistryContext()
register(ctx)
inline_display = display_config._PLATFORM_DEFAULTS["inline"]
assert inline_display["tool_progress"] == "off"
assert inline_display["cleanup_progress"] is True
assert inline_display["streaming"] is False
assert inline_display["interim_assistant_messages"] is False
assert ctx.platform["name"] == "inline"
assert ctx.platform["emoji"] == "💬"
assert ctx.platform["label"] == "Inline"
assert ctx.platform["required_env"] == ["INLINE_TOKEN"]
assert ctx.platform["cron_deliver_env_var"] == "INLINE_HOME_CHANNEL"
assert ctx.platform["standalone_sender_fn"] is _standalone_send
assert "inline-hermes install" in ctx.platform["install_hint"]
assert "INLINE_TOKEN/INLINE_BOT_TOKEN" in ctx.platform["install_hint"]
assert "platforms.inline.token" in ctx.platform["install_hint"]
assert "inline.token" in ctx.platform["install_hint"]
assert len(ctx.commands) == 1
assert ctx.commands[0]["name"] == "threads"
assert ctx.commands[0]["description"] == "Configure Inline reply-thread routing"
assert ctx.commands[0]["args_hint"] == "[status|on|off|auto|reset]"
thread_fallback = ctx.commands[0]["handler"]("off")
assert "/threads off" in thread_fallback
assert "inside the target Inline DM or group chat" in thread_fallback
assert "restart the Hermes gateway" in thread_fallback
assert ctx.cli["name"] == "inline"
assert ctx.tool["name"] == "inline"
assert ctx.tool["toolset"] == "inline"
assert ctx.tool["emoji"] == "💬"
assert "participate" not in ctx.tool["description"]
assert ctx.tool["schema"]["name"] == "inline"
assert "send_message" not in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "send_message" not in ctx.tool["schema"]["description"]
assert "set_typing" not in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "set_presence" in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "reply_to_msg_id" not in ctx.tool["schema"]["parameters"]["properties"]
assert "send_mode" not in ctx.tool["schema"]["parameters"]["properties"]
assert "state" not in ctx.tool["schema"]["parameters"]["properties"]
assert ctx.tool["schema"]["parameters"]["properties"]["kind"]["description"] == "Bot avatar presence/status kind."
assert ctx.tool["schema"]["parameters"]["properties"]["comment"]["description"] == "Optional bot avatar presence/status message."
assert "get_history" in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "create_thread" in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "search_messages" in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "add_reaction" in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert "pin_message" in ctx.tool["schema"]["parameters"]["properties"]["action"]["enum"]
assert ctx.tool["check_fn"]()

tool_calls = []

def fake_inline_sidecar(path, body):
    tool_calls.append((path, body))
    if path == "/history":
        return {"ok": True, "result": {"messages": [{
            "id": "8801",
            "chatId": body["target"]["chatId"],
            "fromId": "u1",
            "message": "See Alice thread " + ("x" * 2000),
            "entities": {"entities": [
                {
                    "type": 1,
                    "offset": 4,
                    "length": 5,
                    "entity": {"oneofKind": "mention", "mention": {"userId": "99"}},
                },
                {
                    "type": 11,
                    "offset": 10,
                    "length": 6,
                    "entity": {"oneofKind": "thread", "thread": {"chatId": "77"}},
                },
            ]},
            "raw": {"ignored": True},
        }]}}
    if path == "/send":
        return {"ok": True, "result": {"messageId": "9001"}}
    if path == "/search":
        return {"ok": True, "result": {"messages": [{
            "id": "8802",
            "chatId": body["target"]["chatId"],
            "fromId": "u2",
            "message": f"found {body['query']}",
        }]}}
    if path == "/reaction":
        return {"ok": True, "result": {
            "messageId": body["messageId"],
            "emoji": body["emoji"],
            "removed": bool(body.get("remove")),
        }}
    if path == "/reactions":
        return {"ok": True, "result": {
            "message": {
                "id": body["messageId"],
                "chatId": body["target"]["chatId"],
                "fromId": "u1",
                "message": "reacted message",
            },
            "reactions": {"reactions": [{"emoji": "ok", "userId": "u2"}]},
        }}
    if path == "/pin":
        return {"ok": True, "result": {
            "messageId": body["messageId"],
            "unpinned": bool(body.get("unpin")),
        }}
    if path == "/pins":
        return {"ok": True, "result": {
            "chatId": body["target"]["chatId"],
            "pinnedMessageIds": ["8801"],
            "anchorMessage": {"id": "8801", "chatId": body["target"]["chatId"], "message": "pinned"},
        }}
    if path == "/create-subthread":
        return {"ok": True, "result": {"chatId": "321", "chat": {"id": "321", "title": "Spec"}}}
    return {"ok": True, "result": {}}

real_inline_sidecar = inline_tools._sidecar_call
saved_session_env = {key: os.environ.get(key) for key in [
    "HERMES_SESSION_PLATFORM",
    "HERMES_SESSION_CHAT_ID",
    "HERMES_SESSION_THREAD_ID",
    "HERMES_SESSION_MESSAGE_ID",
]}
try:
    inline_tools._sidecar_call = fake_inline_sidecar
    history_result = json.loads(ctx.tool["handler"]({
        "action": "get_history",
        "chat_id": "thread:99",
        "limit": 500,
    }))
    assert tool_calls[-1] == ("/history", {"target": {"chatId": "99"}, "limit": 100})
    assert history_result["success"] is True
    assert history_result["result"]["messages"][0]["text"].endswith("...")
    assert history_result["result"]["messages"][0]["entitySummary"] == 'mention "Alice" -> user:99 | thread link "thread" -> thread:77'
    assert history_result["result"]["messages"][0]["entityCount"] == 2
    assert "raw" not in json.dumps(history_result)

    send_result = json.loads(ctx.tool["handler"]({
        "action": "send_message",
        "user_id": "user:42",
        "text": "hello",
        "reply_to_msg_id": "msg:7",
        "parse_markdown": False,
        "send_mode": "silent",
    }))
    assert send_result["error"].startswith("inline: unknown action send_message")
    assert "send_message" not in send_result["allowed_actions"]
    assert "opt_in_env" not in send_result
    assert tool_calls[-1][0] == "/history"

    typing_result = json.loads(ctx.tool["handler"]({
        "action": "set_typing",
        "chat_id": "chat:10",
        "state": "start",
    }))
    assert typing_result["error"].startswith("inline: unknown action set_typing")
    assert "set_typing" not in typing_result["allowed_actions"]
    assert tool_calls[-1][0] == "/history"

    presence_result = json.loads(ctx.tool["handler"]({
        "action": "set_presence",
        "chat_id": "chat:10",
        "kind": "running",
        "comment": "reading",
    }))
    assert presence_result["success"] is True
    assert tool_calls[-1] == ("/presence", {
        "target": {"chatId": "10"},
        "kind": "running",
        "comment": "reading",
    })

    search_result = json.loads(ctx.tool["handler"]({
        "action": "search_messages",
        "chat_id": "chat:10",
        "query": "deploy blockers",
        "limit": 2,
        "offset_id": "msg:6",
    }))
    assert search_result["result"]["count"] == 1
    assert search_result["result"]["messages"][0]["text"] == "found deploy blockers"
    assert tool_calls[-1] == ("/search", {
        "target": {"chatId": "10"},
        "query": "deploy blockers",
        "limit": 2,
        "offsetId": "6",
    })

    reaction_result = json.loads(ctx.tool["handler"]({
        "action": "add_reaction",
        "chat_id": "chat:10",
        "message_id": "msg:5",
        "emoji": "ok",
    }))
    assert reaction_result["result"] == {"messageId": "5", "emoji": "ok", "removed": False}
    assert tool_calls[-1] == ("/reaction", {
        "target": {"chatId": "10"},
        "messageId": "5",
        "emoji": "ok",
    })

    remove_reaction_result = json.loads(ctx.tool["handler"]({
        "action": "remove_reaction",
        "chat_id": "chat:10",
        "message_id": "msg:5",
        "emoji": "ok",
    }))
    assert remove_reaction_result["result"] == {"messageId": "5", "emoji": "ok", "removed": True}
    assert tool_calls[-1] == ("/reaction", {
        "target": {"chatId": "10"},
        "messageId": "5",
        "emoji": "ok",
        "remove": True,
    })

    reactions_result = json.loads(ctx.tool["handler"]({
        "action": "get_reactions",
        "chat_id": "chat:10",
        "message_id": "msg:5",
    }))
    assert reactions_result["result"]["message"]["text"] == "reacted message"
    assert reactions_result["result"]["reactions"]["reactions"][0]["emoji"] == "ok"

    pin_result = json.loads(ctx.tool["handler"]({
        "action": "pin_message",
        "chat_id": "chat:10",
        "message_id": "msg:5",
    }))
    assert pin_result["result"] == {"messageId": "5", "unpinned": False}
    assert tool_calls[-1] == ("/pin", {
        "target": {"chatId": "10"},
        "messageId": "5",
    })

    unpin_result = json.loads(ctx.tool["handler"]({
        "action": "unpin_message",
        "chat_id": "chat:10",
        "message_id": "msg:5",
    }))
    assert unpin_result["result"] == {"messageId": "5", "unpinned": True}
    assert tool_calls[-1] == ("/pin", {
        "target": {"chatId": "10"},
        "messageId": "5",
        "unpin": True,
    })

    pins_result = json.loads(ctx.tool["handler"]({
        "action": "list_pins",
        "chat_id": "thread:10",
    }))
    assert pins_result["result"]["pinnedMessageIds"] == ["8801"]
    assert pins_result["result"]["anchorMessage"]["text"] == "pinned"

    thread_result = json.loads(ctx.tool["handler"]({
        "action": "create_thread",
        "parent_chat_id": "chat:10",
        "parent_message_id": "msg:5",
        "title": "Spec",
    }))
    assert thread_result["result"]["chatId"] == "321"
    assert tool_calls[-1] == ("/create-subthread", {
        "parentChatId": "10",
        "parentMessageId": "5",
        "title": "Spec",
    })

    os.environ["HERMES_SESSION_PLATFORM"] = "inline"
    os.environ["HERMES_SESSION_CHAT_ID"] = "10"
    os.environ["HERMES_SESSION_THREAD_ID"] = "99"
    os.environ["HERMES_SESSION_MESSAGE_ID"] = "5"
    context_result = json.loads(ctx.tool["handler"]({"action": "get_history"}))
    assert context_result["success"] is True
    assert tool_calls[-1] == ("/history", {"target": {"chatId": "99"}, "limit": 20})

    error_result = json.loads(ctx.tool["handler"]({"action": "missing"}))
    assert "unknown action" in error_result["error"]
finally:
    inline_tools._sidecar_call = real_inline_sidecar
    for key, value in saved_session_env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

parser = argparse.ArgumentParser()
inline_cli.register_cli(parser)
default_args = parser.parse_args([])
assert inline_cli.dispatch(default_args) == 0
status_args = parser.parse_args(["status"])
assert status_args.inline_command == "status"
status_output = io.StringIO()
with contextlib.redirect_stdout(status_output):
    assert inline_cli.dispatch(status_args) == 0
status_text = status_output.getvalue()
assert "Inline configured:" in status_text
assert "Node available: yes (" in status_text
assert "hermes inline setup" in status_text
assert "Advanced diagnostics: inline-hermes doctor --json" in status_text
setup_args = parser.parse_args(["setup"])
assert setup_args.inline_command == "setup"
setup_prompt_values.extend(["1", "existing-bot-token", "101, 202"])
real_which = inline_cli.shutil.which
inline_cli.shutil.which = lambda command: None
setup_output = io.StringIO()
try:
    with contextlib.redirect_stdout(setup_output):
        assert inline_cli.dispatch(setup_args) == 0
finally:
    inline_cli.shutil.which = real_which
setup_text = setup_output.getvalue()
assert "Create a bot in Inline and paste its token" in setup_text
assert "Settings → Bots → Create a new bot" in setup_text
assert "https://inline.chat/docs/creating-a-bot" in setup_text
assert "Inline bot token saved securely" in setup_text
assert "Inline is configured" in setup_text
assert "inline-hermes doctor" not in setup_text
assert setup_saved_env["INLINE_TOKEN"] == "existing-bot-token"
assert setup_saved_env["INLINE_ALLOWED_USERS"] == "101,202"
assert setup_saved_env["INLINE_GROUP_ALLOW_FROM"] == "101,202"
assert setup_saved_env["INLINE_DM_POLICY"] == "allowlist"
assert setup_saved_env["INLINE_GROUP_POLICY"] == "allowlist"
assert setup_config_writes == [("inline", "enabled", True, True)]
assert setup_platform_enabled["inline"] is True

setup_saved_env.clear()
setup_config_writes.clear()
setup_platform_enabled["inline"] = False
setup_prompt_values.extend(["2", "Hermes", "myhermesbot", ""])
setup_yes_no_values.extend([True])
real_run_inline_json = inline_cli._run_inline_json
inline_cli.shutil.which = lambda command: "/usr/local/bin/inline"
inline_cli._run_inline_json = lambda executable, args: (
    ({"id": "77"}, None)
    if args == ["auth", "me"]
    else ({"token": "created-bot-token", "bot": {"name": "Hermes"}}, None)
)
automatic_output = io.StringIO()
try:
    with contextlib.redirect_stdout(automatic_output):
        assert inline_cli.dispatch(setup_args) == 0
finally:
    inline_cli.shutil.which = real_which
    inline_cli._run_inline_json = real_run_inline_json
assert "Created Hermes in Inline" in automatic_output.getvalue()
assert setup_saved_env["INLINE_TOKEN"] == "created-bot-token"
assert setup_saved_env["INLINE_ALLOWED_USERS"] == "77"
assert setup_saved_env["INLINE_GROUP_ALLOW_FROM"] == "77"
assert setup_config_writes == [("inline", "enabled", True, True)]
assert setup_platform_enabled["inline"] is True

setup_saved_env.clear()
setup_config_writes.clear()
setup_platform_enabled["inline"] = False
setup_prompt_values.extend(["1", ""])
cancelled_setup_output = io.StringIO()
with contextlib.redirect_stdout(cancelled_setup_output):
    assert inline_cli.dispatch(setup_args) == 0
assert "setup was cancelled" in cancelled_setup_output.getvalue()
assert setup_config_writes == []
assert setup_platform_enabled["inline"] is False

real_find_inline_cli = inline_cli._find_inline_cli
real_subprocess_run = inline_cli.subprocess.run
real_platform = inline_cli.sys.platform

setup_yes_no_values.extend([False])
inline_cli._find_inline_cli = lambda: None
skipped_install_output = io.StringIO()
with contextlib.redirect_stdout(skipped_install_output):
    assert inline_cli._install_inline_cli(setup_cli) is None
assert "installation skipped" in skipped_install_output.getvalue()

setup_yes_no_values.extend([True])
inline_cli.sys.platform = "linux"
inline_cli.shutil.which = lambda command: None
failed_install_output = io.StringIO()
with contextlib.redirect_stdout(failed_install_output):
    assert inline_cli._install_inline_cli(setup_cli) is None
assert "requires curl" in failed_install_output.getvalue()

setup_yes_no_values.extend([True])
install_commands = []
inline_cli.sys.platform = "darwin"
inline_cli.shutil.which = lambda command: "/opt/homebrew/bin/brew" if command == "brew" else None
inline_cli._find_inline_cli = lambda: "/usr/local/bin/inline"
inline_cli.subprocess.run = lambda command, **kwargs: (
    install_commands.append(command) or types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
)
successful_install_output = io.StringIO()
try:
    with contextlib.redirect_stdout(successful_install_output):
        assert inline_cli._install_inline_cli(setup_cli) == "/usr/local/bin/inline"
finally:
    inline_cli._find_inline_cli = real_find_inline_cli
    inline_cli.subprocess.run = real_subprocess_run
    inline_cli.sys.platform = real_platform
    inline_cli.shutil.which = real_which
assert install_commands == [
    ["/opt/homebrew/bin/brew", "install", "--cask", "inline"],
    ["/usr/local/bin/inline", "--version"],
]
assert "installed successfully" in successful_install_output.getvalue()

seeded = _apply_yaml_config(
    {"token": "wrong-global", "home_channel": {"chat_id": "global"}},
    {
        "token": "yaml-token",
        "base_url": "https://inline.example",
        "sidecar_port": 9123,
        "sidecar_bind": "localhost",
        "connect_timeout_ms": 45000,
        "parse_markdown": False,
        "settings_path": "/tmp/inline-settings.json",
        "upload_max_mb": 12,
        "require_mention": False,
        "strict_mention": True,
        "allowed_chats": ["10", "thread:99"],
        "free_response_chats": "99",
        "reply_threads": False,
        "context_backfill": "selective",
        "thread_context_limit": 30,
        "reply_context_limit": 10,
        "observed_context_limit": 20,
        "observe_unmentioned_messages": True,
        "typing_indicator": False,
        "gateway_restart_notification": False,
        "sync_commands": False,
        "command_limit": 42,
        "home_channel": {"chat_id": "chat:123", "name": "Hermes"},
        "extra": {"state_path": "/tmp/inline-state.json"},
    },
)
assert seeded["token"] == "yaml-token"
assert seeded["base_url"] == "https://inline.example"
assert seeded["sidecar_port"] == 9123
assert seeded["sidecar_bind"] == "localhost"
assert seeded["connect_timeout_ms"] == 45000
assert seeded["parse_markdown"] is False
assert seeded["settings_path"] == "/tmp/inline-settings.json"
assert seeded["upload_max_mb"] == 12
assert seeded["require_mention"] is False
assert seeded["strict_mention"] is True
assert seeded["allowed_chats"] == ["10", "thread:99"]
assert seeded["free_response_chats"] == "99"
assert seeded["reply_threads"] is False
assert seeded["context_backfill"] == "selective"
assert seeded["thread_context_limit"] == 30
assert seeded["reply_context_limit"] == 10
assert seeded["observed_context_limit"] == 20
assert seeded["observe_unmentioned_messages"] is True
assert seeded["typing_indicator"] is False
assert seeded["gateway_restart_notification"] is False
assert seeded["sync_commands"] is False
assert seeded["command_limit"] == 42
assert seeded["home_channel"]["chat_id"] == "chat:123"
assert seeded["state_path"] == "/tmp/inline-state.json"

approval_state = {"fail": False, "count": 1, "calls": []}

def resolve_gateway_approval(session_key, choice):
    approval_state["calls"].append((session_key, choice))
    if approval_state["fail"]:
        raise RuntimeError("approval resolver failed")
    return approval_state["count"]

approval.resolve_gateway_approval = resolve_gateway_approval

slash_state = {"fail": False, "result": "slash result", "calls": []}

async def resolve_slash(session_key, confirm_id, choice):
    slash_state["calls"].append((session_key, confirm_id, choice))
    if slash_state["fail"]:
        raise RuntimeError("slash resolver failed")
    return slash_state["result"]

slash_confirm.resolve = resolve_slash

clarify_state = {"mark": True, "resolve": True, "calls": []}

def mark_awaiting_text(clarify_id):
    clarify_state["calls"].append(("mark", clarify_id))
    return clarify_state["mark"]

def resolve_gateway_clarify(clarify_id, response):
    clarify_state["calls"].append(("resolve", clarify_id, response))
    return clarify_state["resolve"]

clarify_gateway.mark_awaiting_text = mark_awaiting_text
clarify_gateway.resolve_gateway_clarify = resolve_gateway_clarify

warning_state = {"warning": None}
model_cost_guard.expensive_model_warning = lambda *args, **kwargs: warning_state["warning"]

real_node_bin = os.environ.pop("INLINE_NODE_BIN", None)
dm = InlineAdapter(PlatformConfig(extra={**base_extra, "allow_from": ["inline:u1", "USER:u2"]}))
assert InlineAdapter.splits_long_messages is True
assert dm._node_bin == "/hermes/node"
if real_node_bin:
    os.environ["INLINE_NODE_BIN"] = real_node_bin
loopback_bind = InlineAdapter(PlatformConfig(extra={**base_extra, "sidecar_bind": "[::1]"}))
assert loopback_bind._sidecar_bind == "::1"
assert loopback_bind._sidecar_base_url() == "http://[::1]:8794"
custom_port = InlineAdapter(PlatformConfig(extra={**base_extra, "sidecar_port": "6543"}))
assert custom_port._sidecar_port == 6543
for bad_port in ["0", "-1", "70000", "abc"]:
    try:
        InlineAdapter(PlatformConfig(extra={**base_extra, "sidecar_port": bad_port}))
        raise AssertionError("expected invalid sidecar port to fail")
    except ValueError as exc:
        assert "INLINE_SIDECAR_PORT must be an integer from 1 to 65535" in str(exc)
custom_command_limit = InlineAdapter(PlatformConfig(extra={**base_extra, "command_limit": "42"}))
assert custom_command_limit._command_limit == 42
custom_context_limit = InlineAdapter(PlatformConfig(extra={**base_extra, "context_history_limit": "3"}))
assert custom_context_limit._context_backfill == "always"
assert custom_context_limit._thread_context_limit == 3
default_context = InlineAdapter(PlatformConfig(extra={"token": "fake"}))
assert default_context._context_backfill == "selective"
assert default_context._thread_context_limit == 30
assert default_context._reply_context_limit == 10
assert default_context._observed_context_limit == 20
assert default_context._observe_unmentioned_messages is True
selective_context = InlineAdapter(PlatformConfig(extra={
    **base_extra,
    "context_backfill": "selective",
    "thread_context_limit": "40",
    "reply_context_limit": "12",
    "observed_context_limit": "25",
    "observe_unmentioned_messages": True,
}))
assert selective_context._context_backfill == "selective"
assert selective_context._thread_context_limit == 40
assert selective_context._reply_context_limit == 12
assert selective_context._observed_context_limit == 25
assert selective_context._observe_unmentioned_messages is True
disabled_observed_context = InlineAdapter(PlatformConfig(extra={**base_extra, "observe_unmentioned_messages": False}))
assert disabled_observed_context._observe_unmentioned_messages is False
off_context = InlineAdapter(PlatformConfig(extra={**base_extra, "context_backfill": "off"}))
assert off_context._context_backfill == "off"
default_reply_threads = InlineAdapter(PlatformConfig(extra=base_extra))
assert default_reply_threads._reply_thread_mode == "auto"
disabled_reply_threads = InlineAdapter(PlatformConfig(extra={**base_extra, "reply_threads": "off"}))
assert disabled_reply_threads._reply_thread_mode == "off"
enabled_reply_threads = InlineAdapter(PlatformConfig(extra={**base_extra, "reply_threads": "auto"}))
assert enabled_reply_threads._reply_thread_mode == "auto"
forced_reply_threads = InlineAdapter(PlatformConfig(extra={**base_extra, "reply_threads": "on"}))
assert forced_reply_threads._reply_thread_mode == "on"
for bad_limit in ["0", "-1", "101", "abc"]:
    try:
        InlineAdapter(PlatformConfig(extra={**base_extra, "command_limit": bad_limit}))
        raise AssertionError("expected invalid command limit to fail")
    except ValueError as exc:
        assert "INLINE_COMMAND_LIMIT must be an integer from 1 to 100" in str(exc)
for bad_limit in ["-1", "21", "abc"]:
    try:
        InlineAdapter(PlatformConfig(extra={**base_extra, "context_history_limit": bad_limit}))
        raise AssertionError("expected invalid context history limit to fail")
    except ValueError as exc:
        assert "INLINE_CONTEXT_HISTORY_LIMIT must be an integer from 0 to 20" in str(exc)
for bad_mode in ["wide-open", "sometimes"]:
    try:
        InlineAdapter(PlatformConfig(extra={**base_extra, "context_backfill": bad_mode}))
        raise AssertionError("expected invalid context backfill mode to fail")
    except ValueError as exc:
        assert "INLINE_CONTEXT_BACKFILL must be one of off, selective, or always" in str(exc)
for key, label, too_high in [
    ("thread_context_limit", "INLINE_THREAD_CONTEXT_LIMIT", "101"),
    ("reply_context_limit", "INLINE_REPLY_CONTEXT_LIMIT", "51"),
    ("observed_context_limit", "INLINE_OBSERVED_CONTEXT_LIMIT", "101"),
]:
    for bad_limit in ["-1", too_high, "abc"]:
        try:
            InlineAdapter(PlatformConfig(extra={**base_extra, key: bad_limit}))
            raise AssertionError(f"expected invalid {key} to fail")
        except ValueError as exc:
            assert f"{label} must be an integer" in str(exc)
timeout_adapter = InlineAdapter(PlatformConfig(extra={**base_extra, "connect_timeout_ms": 1234}))
assert timeout_adapter._connect_timeout_ms == 1234
for key, label in [
    ("connect_timeout_ms", "INLINE_CONNECT_TIMEOUT_MS"),
    ("media_max_mb", "INLINE_MEDIA_MAX_MB"),
    ("upload_max_mb", "INLINE_UPLOAD_MAX_MB"),
]:
    for bad_number in ["0", "-1", "abc", "nan", "inf"]:
        try:
            InlineAdapter(PlatformConfig(extra={**base_extra, key: bad_number}))
            raise AssertionError(f"expected invalid {key} to fail")
        except ValueError as exc:
            assert f"{label} must be a positive number" in str(exc)
try:
    InlineAdapter(PlatformConfig(extra={**base_extra, "sidecar_bind": "0.0.0.0"}))
    raise AssertionError("expected non-loopback sidecar bind to fail")
except ValueError as exc:
    assert "INLINE_SIDECAR_BIND must be loopback" in str(exc)
with tempfile.TemporaryDirectory() as old_node_dir:
    fake_node = Path(old_node_dir) / "node18"
    fake_node.write_text("#!/bin/sh\necho v18.19.0\n")
    fake_node.chmod(0o755)
    saved_node_bin = os.environ.get("INLINE_NODE_BIN")
    os.environ["INLINE_NODE_BIN"] = str(fake_node)
    try:
        old_node_adapter = InlineAdapter(PlatformConfig(extra=base_extra))
        assert asyncio.run(old_node_adapter.connect()) is False
        assert old_node_adapter.fatal_error[0] == "NODE_UNSUPPORTED"
        assert "Node.js >=20" in old_node_adapter.fatal_error[1]
        assert old_node_adapter._sidecar_proc is None
    finally:
        if saved_node_bin is None:
            os.environ.pop("INLINE_NODE_BIN", None)
        else:
            os.environ["INLINE_NODE_BIN"] = saved_node_bin
assert "is_reconnect" in inspect.signature(InlineAdapter.connect).parameters
assert dm._dm_policy == "allowlist"
assert dm._allowed("dm", "u1")
assert dm._allowed("dm", "user:u2")

async def assert_bot_command_sync():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    calls = []

    class FakeBotResponse:
        def __init__(self, status_code, payload):
            self.status_code = status_code
            self._payload = payload
            self.text = json.dumps(payload)

        def json(self):
            return self._payload

    class FakeBotClient:
        async def post(self, url, json=None, headers=None, timeout=None):
            calls.append((url, json, headers, timeout))
            return FakeBotResponse(200, {"ok": True, "result": {}})

    adapter._http_client = FakeBotClient()
    await adapter._sync_bot_commands()
    assert calls[0][0] == "https://api.inline.chat/bot/setMyCommands"
    assert calls[0][2]["Authorization"] == "Bearer fake"
    assert calls[0][2]["Content-Type"] == "application/json"
    assert calls[0][3] == 10.0
    names = [entry["command"] for entry in calls[0][1]["commands"]]
    assert names == ["threads", "help", "model", "update", "bad_name"]
    assert calls[0][1]["commands"][0]["description"] == "Configure Inline reply-thread routing"
    assert calls[0][1]["commands"][3]["description"] == "Update Hermes"

    fallback = InlineAdapter(PlatformConfig(extra={**base_extra, "token": "path token"}))
    fallback_calls = []

    class FallbackClient:
        async def post(self, url, json=None, headers=None, timeout=None):
            fallback_calls.append((url, headers))
            if len(fallback_calls) == 1:
                return FakeBotResponse(401, {"ok": False, "error_code": 401, "description": "unauthorized"})
            return FakeBotResponse(200, {"ok": True, "result": {}})

    fallback._http_client = FallbackClient()
    await fallback._call_bot_api("setMyCommands", {"commands": []})
    assert fallback_calls[0][0] == "https://api.inline.chat/bot/setMyCommands"
    assert fallback_calls[1][0] == "https://api.inline.chat/botpath%20token/setMyCommands"
    assert "Authorization" not in fallback_calls[1][1]

asyncio.run(assert_bot_command_sync())
assert not dm._allowed("dm", "u3")

group = InlineAdapter(PlatformConfig(extra={**base_extra, "group_allow_from": "u3"}))
assert group._group_policy == "allowlist"
assert group._allowed("group", "u3")
assert not group._allowed("group", "u4")

disabled = InlineAdapter(PlatformConfig(extra={**base_extra, "dm_policy": "disabled", "allow_all": True}))
assert not disabled._allowed("dm", "u1")

wildcard = InlineAdapter(PlatformConfig(extra={**base_extra, "dm_policy": "allowlist", "allow_from": "*"}))
assert wildcard._allowed("dm", "anyone")

patterns = InlineAdapter._compile_mention_patterns("hermes, inline\nagent")
assert [pattern.pattern for pattern in patterns] == ["hermes", "inline", "agent"]

wake = InlineAdapter(PlatformConfig(extra={**base_extra, "mention_patterns": r'["hermes\\b[:,]?"]'}))
assert wake._matches_mention("Hermes: status")
assert wake._clean_mention("Hermes: status") == "status"

merged = _apply_yaml_config({"allowed_users": ["wrong-global"]}, {"allowed_users": ["u5"], "dm_policy": "allowlist", "extra": {"token": "fake"}})
assert merged["allowed_users"] == ["u5"]
assert merged["dm_policy"] == "allowlist"
assert merged["token"] == "fake"

bound = _apply_yaml_config({}, {
    "channel_prompts": {"thread:99": "Thread prompt", "chat:10": "Parent prompt"},
    "channel_skill_bindings": [{"id": "thread:99", "skills": ["triage", "bugs"]}],
})
assert bound["channel_prompts"]["thread:99"] == "Thread prompt"
assert bound["channel_skill_bindings"][0]["skills"] == ["triage", "bugs"]

assert _target_from_chat_id("inline:user:44") == {"userId": "44"}
assert _target_from_chat_id("chat:55") == {"chatId": "55"}

async def assert_thread_bindings():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
        "channel_prompts": {"thread:99": "Thread prompt", "10": "Parent prompt"},
        "channel_skill_bindings": [
            {"id": "thread:99", "skills": ["triage", "bugs"]},
            {"id": "10", "skill": "parent"},
        ],
    }))
    events = []

    async def fake_handle_message(event):
        events.append(event)

    adapter.handle_message = fake_handle_message
    await adapter._dispatch_message({
        "seq": 7,
        "chatId": "10",
        "message": {
            "id": "5",
            "chatId": "10",
            "fromId": "u1",
            "message": "thread update",
            "peerId": {"peer": {"oneofKind": "chat"}},
            "replies": {"chatId": "thread:99"},
        },
    })

    assert len(events) == 1
    assert events[0].source.thread_id == "thread:99"
    assert events[0].channel_prompt.startswith("Thread prompt\n\nYou are handling an Inline message.")
    assert "This turn is already scoped to an Inline reply thread." in events[0].channel_prompt
    assert "Current Inline sender is" in events[0].channel_prompt
    assert "user:u1" in events[0].channel_prompt
    assert '[@user:u1](inline://user?id=u1)' in events[0].channel_prompt
    assert '[this thread](inline://thread?id=99)' in events[0].channel_prompt
    assert events[0].metadata["inline"]["sender_user_id"] == "u1"
    assert events[0].metadata["inline"]["thread_id"] == "99"
    assert events[0].metadata["inline"]["parent_chat_id"] == "10"
    assert events[0].metadata["inline"]["parent_message_id"] == "5"
    assert events[0].auto_skill == ["triage", "bugs"]

asyncio.run(assert_thread_bindings())

async def assert_reply_thread_chat_metadata():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
        "channel_prompts": {"123": "Parent prompt"},
        "channel_skill_bindings": [{"id": "123", "skill": "parent-skill"}],
    }))
    events = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_get_chat_info(chat_id):
        if chat_id == "456":
            return {
                "chatId": "456",
                "title": "Incident reply thread",
                "parentChatId": "123",
                "parentMessageId": "9001",
            }
        if chat_id == "123":
            return {"chatId": "123", "title": "Parent room"}
        raise AssertionError(f"unexpected chat info {chat_id}")

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    await adapter._dispatch_message({
        "seq": 8,
        "chatId": "456",
        "message": {
            "id": "6",
            "chatId": "456",
            "fromId": "u1",
            "message": "thread update",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert len(events) == 1
    assert events[0].source.chat_id == "456"
    assert events[0].source.chat_name == "Incident reply thread"
    assert events[0].source.thread_id == "456"
    assert events[0].source.parent_chat_id == "123"
    assert events[0].channel_prompt.startswith("Parent prompt\n\nYou are handling an Inline message.")
    assert "This turn is already scoped to an Inline reply thread." in events[0].channel_prompt
    assert events[0].metadata["inline"]["thread_id"] == "456"
    assert events[0].metadata["inline"]["parent_chat_id"] == "123"
    assert events[0].metadata["inline"]["parent_message_id"] == "9001"
    assert events[0].auto_skill == ["parent-skill"]

asyncio.run(assert_reply_thread_chat_metadata())

async def assert_default_auto_reply_threads_keep_fresh_parent_messages_flat():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
    }))
    events = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_get_chat_info(chat_id):
        assert chat_id == "10"
        return {"chatId": "10", "title": "New thread", "lastMsgId": "9001"}

    async def fake_sidecar_call(path, body):
        raise AssertionError(f"default auto mode should not create a reply thread for fresh message: {path} {body}")

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    adapter._sidecar_call = fake_sidecar_call
    await adapter._dispatch_message({
        "seq": 9,
        "chatId": "10",
        "message": {
            "id": "9001",
            "chatId": "10",
            "fromId": "u1",
            "message": "hey bro",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert len(events) == 1
    assert events[0].source.chat_id == "10"
    assert events[0].source.thread_id is None
    assert "thread_id" not in events[0].metadata["inline"]

asyncio.run(assert_default_auto_reply_threads_keep_fresh_parent_messages_flat())

async def assert_forced_reply_thread_creation():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "reply_threads": "on",
        "require_mention": False,
        "channel_prompts": {"99": "Thread prompt", "10": "Parent prompt"},
        "channel_skill_bindings": [{"id": "99", "skill": "thread-skill"}],
    }))
    events = []
    calls = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_get_chat_info(chat_id):
        assert chat_id == "10"
        return {"chatId": "10", "title": "Parent room"}

    async def fake_sidecar_call(path, body):
        calls.append((path, body))
        if path == "/create-subthread":
            return {"ok": True, "result": {"chatId": "99"}}
        if path == "/send":
            return {"ok": True, "result": {"messageId": f"sent-{len(calls)}"}}
        if path == "/typing":
            return {"ok": True, "result": {}}
        raise AssertionError(f"unexpected sidecar path {path}")

    async def fake_fetch_message(chat_id, msg_id):
        assert chat_id == "10"
        assert msg_id == "6"
        return {"id": "6", "chatId": "10", "fromId": "u2", "message": "parent quote"}

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    adapter._sidecar_call = fake_sidecar_call
    adapter._fetch_message = fake_fetch_message
    await adapter._dispatch_message({
        "seq": 9,
        "chatId": "10",
        "message": {
            "id": "7",
            "chatId": "10",
            "fromId": "u1",
            "message": "please investigate the incident",
            "replyToMsgId": "6",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert calls == [("/create-subthread", {
        "parentChatId": "10",
        "parentMessageId": "7",
        "title": "please investigate the incident",
    })]
    assert len(events) == 1
    assert events[0].source.chat_id == "10"
    assert events[0].source.thread_id == "99"
    assert events[0].source.parent_chat_id == "10"
    assert events[0].channel_prompt.startswith("Thread prompt\n\nYou are handling an Inline message.")
    assert "This turn is already scoped to an Inline reply thread." in events[0].channel_prompt
    assert events[0].metadata["inline"]["thread_id"] == "99"
    assert events[0].metadata["inline"]["parent_chat_id"] == "10"
    assert events[0].metadata["inline"]["parent_message_id"] == "7"
    assert events[0].metadata["inline"]["sender_user_id"] == "u1"
    assert events[0].reply_to_message_id == "6"
    assert events[0].reply_to_text == "parent quote"
    assert events[0].auto_skill == ["thread-skill"]

    await adapter.send_typing("10", metadata={"thread_id": "99"})
    assert calls[-1] == ("/typing", {"target": {"chatId": "10"}, "state": "start"})

    trigger_reply = await adapter.send("10", "agent reply", reply_to="7", metadata={"thread_id": "99"})
    assert trigger_reply.success is True
    assert calls[-1][1]["target"] == {"chatId": "99"}
    assert "replyToMsgId" not in calls[-1][1]

    await adapter.stop_typing("10", metadata={"thread_id": "99"})
    assert calls[-1] == ("/typing", {"target": {"chatId": "10"}, "state": "stop"})

    await adapter.send_typing("10", metadata={"thread_id": "99"})
    assert calls[-1] == ("/typing", {"target": {"chatId": "99"}, "state": "start"})
    await adapter.stop_typing("10", metadata={"thread_id": "99"})
    assert calls[-1] == ("/typing", {"target": {"chatId": "99"}, "state": "stop"})

    reused_thread = await adapter._create_reply_thread("10", "7", "please investigate the incident", "6")
    assert reused_thread == "99"
    await adapter.send_typing("10", metadata={"thread_id": "99"})
    assert calls[-1] == ("/typing", {"target": {"chatId": "99"}, "state": "start"})
    await adapter.stop_typing("10", metadata={"thread_id": "99"})
    assert calls[-1] == ("/typing", {"target": {"chatId": "99"}, "state": "stop"})

    quote_reply = await adapter.send("10", "agent reply", reply_to="6", metadata={"thread_id": "99"})
    assert quote_reply.success is True
    assert "replyToMsgId" not in calls[-1][1]

    in_thread_reply = await adapter.send("10", "agent reply", reply_to="sent-2", metadata={"thread_id": "99"})
    assert in_thread_reply.success is True
    assert calls[-1][1]["replyToMsgId"] == "sent-2"

asyncio.run(assert_forced_reply_thread_creation())

async def assert_default_dm_reply_thread_creation():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    events = []
    calls = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_sidecar_call(path, body):
        calls.append((path, body))
        if path == "/create-subthread":
            return {"ok": True, "result": {"chatId": "dm-thread-99"}}
        if path == "/send":
            return {"ok": True, "result": {"messageId": f"dm-sent-{len(calls)}"}}
        raise AssertionError(f"unexpected sidecar path {path}")

    adapter.handle_message = fake_handle_message
    adapter._sidecar_call = fake_sidecar_call
    await adapter._dispatch_message({
        "seq": 10,
        "chatId": "20",
        "message": {
            "id": "dm-7",
            "chatId": "20",
            "fromId": "u1",
            "message": "please keep this in a reply thread",
            "peerId": {"peer": {"oneofKind": "user"}},
        },
    })

    assert calls == [("/create-subthread", {
        "parentChatId": "20",
        "parentMessageId": "dm-7",
        "title": "please keep this in a reply thread",
    })]
    assert len(events) == 1
    assert events[0].source.chat_type == "dm"
    assert events[0].source.chat_id == "20"
    assert events[0].source.thread_id == "dm-thread-99"
    assert events[0].source.parent_chat_id == "20"
    assert "This turn is already scoped to an Inline reply thread." in events[0].channel_prompt
    assert events[0].metadata["inline"]["thread_id"] == "dm-thread-99"
    assert events[0].metadata["inline"]["parent_chat_id"] == "20"
    assert events[0].metadata["inline"]["parent_message_id"] == "dm-7"

    dm_reply = await adapter.send("20", "agent reply", reply_to="dm-7", metadata={"thread_id": "dm-thread-99"})
    assert dm_reply.success is True
    assert calls[-1][1]["target"] == {"chatId": "dm-thread-99"}
    assert "replyToMsgId" not in calls[-1][1]

asyncio.run(assert_default_dm_reply_thread_creation())

async def assert_reply_threads_disabled_preserves_existing_threads():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
        "reply_threads": False,
    }))
    events = []
    calls = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_get_chat_info(chat_id):
        return {"chatId": chat_id, "title": f"Chat {chat_id}"}

    async def fake_sidecar_call(path, body):
        calls.append((path, body))
        return {"ok": True, "result": {"chatId": "created"}}

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    adapter._sidecar_call = fake_sidecar_call
    await adapter._dispatch_message({
        "seq": 11,
        "chatId": "10",
        "message": {
            "id": "8",
            "chatId": "10",
            "fromId": "u1",
            "message": "top level",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })
    await adapter._dispatch_message({
        "seq": 12,
        "chatId": "10",
        "message": {
            "id": "9",
            "chatId": "10",
            "fromId": "u1",
            "message": "existing reply thread",
            "peerId": {"peer": {"oneofKind": "chat"}},
            "replies": {"chatId": "99"},
        },
    })

    assert calls == []
    assert len(events) == 2
    assert events[0].source.thread_id is None
    assert events[1].source.thread_id == "99"

asyncio.run(assert_reply_threads_disabled_preserves_existing_threads())

async def assert_inline_entity_context():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
        "reply_threads": False,
    }))
    events = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_get_chat_info(chat_id):
        return {"chatId": chat_id, "title": f"Chat {chat_id}"}

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    await adapter._dispatch_message({
        "seq": 15,
        "chatId": "10",
        "message": {
            "id": "20",
            "chatId": "10",
            "fromId": "u1",
            "message": "See Alice docs thread",
            "peerId": {"peer": {"oneofKind": "chat"}},
            "entities": {
                "entities": [
                    {
                        "type": 1,
                        "offset": 4,
                        "length": 5,
                        "entity": {"oneofKind": "mention", "mention": {"userId": "99"}},
                    },
                    {
                        "type": 3,
                        "offset": 10,
                        "length": 4,
                        "entity": {"oneofKind": "textUrl", "textUrl": {"url": "https://example.com/docs"}},
                    },
                    {
                        "type": 11,
                        "offset": 15,
                        "length": 6,
                        "entity": {"oneofKind": "thread", "thread": {"chatId": "77"}},
                    },
                ],
            },
        },
    })

    assert len(events) == 1
    summary = 'mention "Alice" -> user:99 | text link "docs" -> https://example.com/docs | thread link "thread" -> thread:77'
    assert events[0].channel_context == f"[Inline message entities]\n{summary}"
    assert events[0].metadata["inline"]["message_entities"] == summary
    assert events[0].metadata["inline"]["sender_user_id"] == "u1"
    assert "Current Inline sender is" in events[0].channel_prompt
    assert "user:u1" in events[0].channel_prompt
    assert '[@user:u1](inline://user?id=u1)' in events[0].channel_prompt
    assert '[this chat](inline://chat?id=10)' in events[0].channel_prompt
    assert "Inline entity metadata maps visible text to IDs" in events[0].channel_prompt
    assert "Alice" not in events[0].channel_prompt
    assert "https://example.com/docs" not in events[0].channel_prompt

asyncio.run(assert_inline_entity_context())

async def assert_inline_thread_context_history():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
        "reply_threads": False,
        "context_backfill": "selective",
        "thread_context_limit": 2,
    }))
    events = []
    calls = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_get_chat_info(chat_id):
        if chat_id == "456":
            return {
                "chatId": "456",
                "title": "Incident thread",
                "parentChatId": "123",
                "parentMessageId": "9001",
            }
        if chat_id == "123":
            return {"chatId": "123", "title": "Parent room"}
        return {"chatId": chat_id, "title": f"Chat {chat_id}"}

    async def fake_sidecar_call(path, body):
        calls.append((path, body))
        if path == "/messages":
            return {"ok": True, "result": {"messages": [{
                "id": "9001",
                "chatId": "123",
                "fromId": "u2",
                "message": "Original incident report",
                "date": "120",
            }]}}
        if path == "/history":
            return {"ok": True, "result": {"messages": [
                {"id": "9002", "chatId": "456", "fromId": "u1", "message": "current", "date": "130"},
                {"id": "9000", "chatId": "456", "fromId": "u3", "message": "Earlier analysis", "date": "121"},
                {"id": "8999", "chatId": "456", "fromId": "u4", "message": "Needs deploy follow-up", "date": "119"},
                {"id": "8998", "chatId": "456", "fromId": "u5", "message": "too old", "date": "118"},
            ]}}
        raise AssertionError(f"unexpected sidecar path {path}")

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    adapter._sidecar_call = fake_sidecar_call
    await adapter._dispatch_message({
        "seq": 16,
        "chatId": "456",
        "message": {
            "id": "9002",
            "chatId": "456",
            "fromId": "u1",
            "message": "what did we decide?",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert len(events) == 1
    assert events[0].source.thread_id == "456"
    assert events[0].source.parent_chat_id == "123"
    context = events[0].channel_context
    assert "[Inline thread context]" in context
    assert "chat: 456 (Incident thread)" in context
    assert "parent_chat: 123 (Parent room)" in context
    assert "parent_message: 9001" in context
    assert "[Inline parent message]" in context
    assert "message:9001 user:u2: Original incident report" in context
    assert "[Inline recent history]" in context
    assert "message:9000 user:u3: Earlier analysis" in context
    assert "message:8999 user:u4: Needs deploy follow-up" in context
    assert "message:9002" not in context
    assert "message:8998" not in context
    assert calls == [
        ("/messages", {"target": {"chatId": "123"}, "messageIds": ["9001"]}),
        ("/history", {"target": {"chatId": "456"}, "limit": 3}),
    ]

    await adapter._dispatch_message({
        "seq": 17,
        "chatId": "456",
        "message": {
            "id": "9003",
            "chatId": "456",
            "fromId": "u1",
            "message": "follow-up in the same thread",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert len(events) == 2
    assert "[Inline parent message]" in events[1].channel_context
    assert "[Inline recent history]" not in events[1].channel_context
    assert calls == [
        ("/messages", {"target": {"chatId": "123"}, "messageIds": ["9001"]}),
        ("/history", {"target": {"chatId": "456"}, "limit": 3}),
        ("/messages", {"target": {"chatId": "123"}, "messageIds": ["9001"]}),
    ]

asyncio.run(assert_inline_thread_context_history())

async def assert_inline_reply_context_window():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": False,
        "reply_threads": False,
        "context_backfill": "selective",
        "reply_context_limit": 3,
    }))
    events = []
    calls = []

    async def fake_handle_message(event):
        events.append(event)

    async def fake_fetch_message(chat_id, message_id):
        assert chat_id == "10"
        assert message_id == "50"
        return {"id": "50", "chatId": "10", "fromId": "u2", "message": "Can we ship this?"}

    async def fake_get_chat_info(chat_id):
        return {}

    async def fake_sidecar_call(path, body):
        calls.append((path, body))
        if path == "/history":
            return {"ok": True, "result": {"messages": [
                {"id": "51", "chatId": "10", "fromId": "u1", "message": "Hermes: answer?", "date": "130"},
                {"id": "50", "chatId": "10", "fromId": "u2", "message": "Can we ship this?", "date": "129"},
                {"id": "49", "chatId": "10", "fromId": "u3", "message": "Only after QA signs off", "date": "128"},
            ]}}
        raise AssertionError(f"unexpected sidecar path {path}")

    adapter.handle_message = fake_handle_message
    adapter._get_chat_info = fake_get_chat_info
    adapter._fetch_message = fake_fetch_message
    adapter._sidecar_call = fake_sidecar_call
    await adapter._dispatch_message({
        "seq": 17,
        "chatId": "10",
        "message": {
            "id": "51",
            "chatId": "10",
            "fromId": "u1",
            "message": "replying here",
            "replyToMsgId": "50",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert len(events) == 1
    context = events[0].channel_context
    assert "[Inline context around replied-to message]" in context
    assert "message:50 user:u2: Can we ship this?" in context
    assert "message:49 user:u3: Only after QA signs off" in context
    assert "message:51" not in context
    assert calls == [("/history", {
        "target": {"chatId": "10"},
        "limit": 4,
        "anchorId": "50",
        "includeAnchor": True,
    })]

asyncio.run(assert_inline_reply_context_window())

async def assert_observed_context_buffer():
    adapter = InlineAdapter(PlatformConfig(extra={
        **base_extra,
        "require_mention": True,
        "reply_threads": False,
        "context_backfill": "off",
        "observe_unmentioned_messages": True,
        "observed_context_limit": 2,
    }))
    events = []

    async def fake_handle_message(event):
        events.append(event)

    adapter.handle_message = fake_handle_message
    await adapter._dispatch_message({
        "seq": 18,
        "chatId": "10",
        "message": {
            "id": "60",
            "chatId": "10",
            "fromId": "u2",
            "message": "QA found one blocker",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })
    await adapter._dispatch_message({
        "seq": 19,
        "chatId": "10",
        "message": {
            "id": "61",
            "chatId": "10",
            "fromId": "u1",
            "message": "Hermes: what changed?",
            "peerId": {"peer": {"oneofKind": "chat"}},
        },
    })

    assert len(events) == 1
    assert events[0].text == "what changed?"
    assert "[Inline observed context]" in events[0].channel_context
    assert "message:60 user:u2: QA found one blocker" in events[0].channel_context
    assert "Inline observed context contains recent group messages" in events[0].channel_prompt
    assert adapter._observed_context == {}

asyncio.run(assert_observed_context_buffer())

async def assert_reply_thread_slash_command():
    with tempfile.TemporaryDirectory() as tmp:
        settings_path = Path(tmp) / "settings.json"
        adapter = InlineAdapter(PlatformConfig(extra={
            **base_extra,
            "settings_path": str(settings_path),
            "require_mention": True,
        }))
        sends = []
        edits = []
        answers = []

        async def fake_send(chat_id, content, reply_to=None, metadata=None, actions=None):
            sends.append((chat_id, content, reply_to, metadata, actions))
            return SendResult(success=True, message_id=f"sent-{len(sends)}")

        async def fake_edit_action_message(event, text, actions=None):
            edits.append((event, text, actions))
            return SendResult(success=True, message_id=str(event.get("messageId") or "edited"))

        async def fake_answer_action(interaction_id, toast):
            answers.append((interaction_id, toast))

        async def fake_handle_message(event):
            raise AssertionError("thread slash command should not reach Hermes handler")

        async def fake_get_chat_info(chat_id):
            if chat_id == "99":
                return {"chatId": "99", "title": "Child thread", "parentChatId": "10"}
            return {"chatId": chat_id, "title": f"Chat {chat_id}"}

        async def fake_fetch_message(chat_id, message_id):
            if chat_id == "20":
                return {"peerId": {"type": {"oneofKind": "user", "user": {"userId": chat_id}}}}
            return {"peerId": {"type": {"oneofKind": "chat", "chat": {"chatId": chat_id}}}}

        adapter.send = fake_send
        adapter._edit_action_message = fake_edit_action_message
        adapter._answer_action = fake_answer_action
        adapter.handle_message = fake_handle_message
        adapter._get_chat_info = fake_get_chat_info
        adapter._fetch_message = fake_fetch_message

        await adapter._dispatch_message({
            "seq": 13,
            "chatId": "10",
            "message": {
                "id": "cmd-1",
                "chatId": "10",
                "fromId": "u1",
                "message": "/threads off",
                "peerId": {"peer": {"oneofKind": "chat"}},
            },
        })
        assert adapter._reply_thread_mode_for_chat("10") == "off"
        assert sends[-1][0] == "10"
        assert sends[-1][2] == "cmd-1"
        assert sends[-1][3] is None
        assert sends[-1][4]["rows"][0]["actions"][0]["text"] == "Auto"
        assert sends[-1][4]["rows"][0]["actions"][1]["text"] == "On"
        assert sends[-1][4]["rows"][0]["actions"][2]["text"] == "Off"
        assert sends[-1][4]["rows"][1]["actions"][0]["text"] == "Reset"
        assert "off for this chat" in sends[-1][1]
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {"10": "off"}

        auto_action = sends[-1][4]["rows"][0]["actions"][0]["id"]
        assert auto_action.startswith("th:")
        assert await adapter._handle_action({
            "chatId": "10",
            "messageId": "sent-1",
            "interactionId": "thread-action-1",
            "actorUserId": "1600",
            "actionId": auto_action,
        })
        assert adapter._reply_thread_mode_for_chat("10") == "auto"
        assert "Inline reply threads updated: auto for this chat (chat override)." in edits[-1][1]
        assert "Use Auto, On, Off, or Reset." not in edits[-1][1]
        assert edits[-1][2] == {"rows": []}
        assert answers[-1] == ("thread-action-1", "Reply threads: auto")
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {"10": "auto"}

        await adapter._dispatch_message({
            "seq": 131,
            "chatId": "10",
            "message": {
                "id": "cmd-1-status",
                "chatId": "10",
                "fromId": "u1",
                "message": "/threads",
                "peerId": {"peer": {"oneofKind": "chat"}},
            },
        })
        assert "auto for this chat (chat override)" in sends[-1][1]
        reset_action = sends[-1][4]["rows"][1]["actions"][0]["id"]
        assert await adapter._handle_action({
            "chatId": "10",
            "messageId": "sent-2",
            "interactionId": "thread-action-2",
            "actorUserId": "1600",
            "actionId": reset_action,
        })
        assert adapter._reply_thread_mode_for_chat("10") == "auto"
        assert "Inline reply threads updated: auto for this chat (global default)." in edits[-1][1]
        assert "Use Auto, On, Off, or Reset." not in edits[-1][1]
        assert edits[-1][2] == {"rows": []}
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {}

        assert await adapter._handle_action({
            "chatId": "10",
            "messageId": "sent-1",
            "interactionId": "thread-action-expired",
            "actorUserId": "1600",
            "actionId": "th:missing:on",
        })
        assert answers[-1] == ("thread-action-expired", "Thread controls expired")

        await adapter._dispatch_message({
            "seq": 14,
            "chatId": "99",
            "message": {
                "id": "cmd-2",
                "chatId": "99",
                "fromId": "u1",
                "message": "/threads auto",
                "peerId": {"peer": {"oneofKind": "chat"}},
            },
        })
        assert adapter._reply_thread_mode_for_chat("10") == "auto"
        assert sends[-1][0] == "99"
        assert sends[-1][2] == "cmd-2"
        assert sends[-1][3] == {"thread_id": "99"}
        assert "auto for this chat (chat override)" in sends[-1][1]
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {"10": "auto"}

        await adapter._dispatch_message({
            "seq": 141,
            "chatId": "99",
            "message": {
                "id": "cmd-2-reset",
                "chatId": "99",
                "fromId": "u1",
                "message": "/threads reset",
                "peerId": {"peer": {"oneofKind": "chat"}},
            },
        })
        assert adapter._reply_thread_mode_for_chat("10") == "auto"
        assert sends[-1][0] == "99"
        assert sends[-1][2] == "cmd-2-reset"
        assert sends[-1][3] == {"thread_id": "99"}
        assert "auto for this chat (global default)" in sends[-1][1]
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {}

        await adapter._dispatch_message({
            "seq": 15,
            "chatId": "20",
            "message": {
                "id": "cmd-3",
                "chatId": "20",
                "fromId": "u1",
                "message": "/threads off",
                "peerId": {"peer": {"oneofKind": "user"}},
            },
        })
        assert adapter._reply_thread_mode_for_chat("20") == "off"
        assert sends[-1][0] == "20"
        assert sends[-1][2] == "cmd-3"
        assert sends[-1][3] is None
        assert "Reply-thread routing only applies" not in sends[-1][1]
        assert "off for this chat" in sends[-1][1]
        assert "Top-level replies stay in the parent chat." in sends[-1][1]

        await adapter._dispatch_message({
            "seq": 16,
            "chatId": "20",
            "message": {
                "id": "cmd-4",
                "chatId": "20",
                "fromId": "u1",
                "message": "/threads auto",
                "peerId": {"peer": {"oneofKind": "user"}},
            },
        })
        assert adapter._reply_thread_mode_for_chat("20") == "auto"
        assert sends[-1][0] == "20"
        assert sends[-1][2] == "cmd-4"
        assert sends[-1][3] is None
        assert "auto for this chat (chat override)" in sends[-1][1]
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {"20": "auto"}

        await adapter._dispatch_message({
            "seq": 17,
            "chatId": "20",
            "message": {
                "id": "cmd-5",
                "chatId": "20",
                "fromId": "u1",
                "message": "/threads default",
                "peerId": {"peer": {"oneofKind": "user"}},
            },
        })
        assert adapter._reply_thread_mode_for_chat("20") == "auto"
        assert sends[-1][0] == "20"
        assert sends[-1][2] == "cmd-5"
        assert sends[-1][3] is None
        assert "auto for this chat (global default)" in sends[-1][1]
        saved = json.loads(settings_path.read_text())
        assert saved["reply_threads"] == {}

asyncio.run(assert_reply_thread_slash_command())

async def assert_group_room_controls():
    async def run(adapter, msg, reply=None):
        events = []

        async def capture(event):
            events.append(event)

        async def fetch_message(chat_id, message_id):
            return reply

        adapter.handle_message = capture
        adapter._fetch_message = fetch_message
        await adapter._dispatch_message({"seq": 10, "chatId": msg["chatId"], "message": msg})
        return events

    base_msg = {
        "id": "room-msg",
        "chatId": "10",
        "fromId": "u1",
        "message": "hello",
        "peerId": {"peer": {"oneofKind": "chat"}},
    }

    restricted = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": False, "allowed_chats": "99"}))
    assert await run(restricted, base_msg) == []

    allowed = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": False, "allowed_chats": "10"}))
    assert len(await run(allowed, base_msg)) == 1

    thread_allowed = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": False, "allowed_chats": "99"}))
    thread_msg = {**base_msg, "replies": {"chatId": "99"}}
    assert len(await run(thread_allowed, thread_msg)) == 1

    async def child_thread_info(chat_id):
        if chat_id == "456":
            return {"chatId": "456", "title": "Child thread", "parentChatId": "10"}
        if chat_id == "10":
            return {"chatId": "10", "title": "Parent room"}
        raise AssertionError(f"unexpected chat info {chat_id}")

    parent_allowed = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": False, "allowed_chats": "10"}))
    parent_allowed._get_chat_info = child_thread_info
    child_events = await run(parent_allowed, {**base_msg, "id": "room-msg-child", "chatId": "456"})
    assert len(child_events) == 1
    assert child_events[0].source.thread_id == "456"
    assert child_events[0].source.parent_chat_id == "10"

    free = InlineAdapter(PlatformConfig(extra={**base_extra, "free_response_chats": "10"}))
    assert len(await run(free, base_msg)) == 1

    async def followed_info(chat_id):
        return {
            "chatId": chat_id,
            "title": f"Followed {chat_id}",
            "dialogFollowMode": "1",
            "followModeMentionEligible": True,
        }

    followed = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": True}))
    followed._get_chat_info = followed_info
    followed_events = await run(followed, base_msg)
    assert len(followed_events) == 1
    assert followed_events[0].source.chat_id == "10"

    async def followed_large_info(chat_id):
        return {
            "chatId": chat_id,
            "title": f"Large followed {chat_id}",
            "dialogFollowMode": "1",
            "followModeMentionEligible": False,
        }

    followed_large = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": True}))
    followed_large._get_chat_info = followed_large_info
    assert await run(followed_large, base_msg) == []

    strict_followed = InlineAdapter(PlatformConfig(extra={**base_extra, "require_mention": True, "strict_mention": True}))
    strict_followed._get_chat_info = followed_info
    assert await run(strict_followed, base_msg) == []

    strict = InlineAdapter(PlatformConfig(extra={**base_extra, "strict_mention": True}))
    strict._me_id = "bot"
    own_reply = {"id": "parent", "fromId": "bot", "message": "answer"}
    assert await run(strict, {**base_msg, "replyToMsgId": "parent"}, reply=own_reply) == []
    assert len(await run(strict, {**base_msg, "id": "room-msg-2", "message": "Hermes: hello", "replyToMsgId": "parent"}, reply=own_reply)) == 1

asyncio.run(assert_group_room_controls())

async def assert_action_thread_targets():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    calls = []

    async def fake_send_sidecar(path, body):
        calls.append((path, body))
        return SendResult(success=True, message_id=str(len(calls)), raw_response=body)

    adapter._send_sidecar = fake_send_sidecar
    metadata = {"thread_id": "chat:99"}
    await adapter.send_clarify("chat:10", "Choose", ["A", "B"], "clarify-1", "session-1", metadata=metadata)
    await adapter.send_exec_approval("chat:10", "echo ok", "session-2", metadata=metadata)
    await adapter.send_slash_confirm("chat:10", "Title", "Message", "session-3", "confirm-1", metadata=metadata)

    assert len(calls) == 3
    for path, body in calls:
        assert path == "/send"
        assert body["target"] == {"chatId": "99"}
        assert body["actions"]["rows"][0]["actions"]

asyncio.run(assert_action_thread_targets())

async def assert_upload_size_cap():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "large.bin"
        path.write_bytes(b"abcd")
        adapter = InlineAdapter(PlatformConfig(extra={**base_extra, "upload_max_mb": 0.000001}))
        calls = []

        async def fake_send_sidecar(path, body):
            calls.append((path, body))
            return SendResult(success=True, message_id="sent")

        adapter._send_sidecar = fake_send_sidecar
        relative_result = await adapter.send_document("chat:10", "relative.bin")
        assert relative_result.success is False
        assert "absolute" in (relative_result.error or "")

        directory_result = await adapter.send_document("chat:10", str(Path(tmp)))
        assert directory_result.success is False
        assert "regular file" in (directory_result.error or "")

        result = await adapter.send_document("chat:10", str(path))

        assert result.success is False
        assert "attachment exceeds Inline upload cap" in result.error
        assert calls == []

asyncio.run(assert_upload_size_cap())

async def assert_model_picker_flow():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    calls = []
    answers = []
    selected = []

    async def fake_send_sidecar(path, body):
        calls.append((path, body))
        message_id = body.get("messageId") or "42"
        return SendResult(success=True, message_id=message_id, raw_response=body)

    async def fake_answer_action(interaction_id, toast):
        answers.append((interaction_id, toast))

    async def on_selected(chat_id, model_id, provider_slug):
        selected.append((chat_id, model_id, provider_slug))
        return f"switched to {model_id} via {provider_slug}"

    adapter._send_sidecar = fake_send_sidecar
    adapter._answer_action = fake_answer_action
    metadata = {"thread_id": "chat:99"}
    providers = [{
        "slug": "openrouter",
        "name": "OpenRouter",
        "models": ["openai/gpt-5.5", "anthropic/claude-sonnet"],
        "total_models": 2,
        "is_current": True,
    }]

    result = await adapter.send_model_picker(
        "chat:10",
        providers,
        "old-model",
        "openrouter",
        "session-model",
        on_selected,
        metadata=metadata,
    )

    assert result.success
    assert calls[0][0] == "/send"
    assert calls[0][1]["target"] == {"chatId": "99"}
    assert calls[0][1]["actions"]["rows"][0]["actions"][0]["id"].startswith("mp:")
    picker_id = next(iter(adapter._model_picker_sessions.keys()))

    await adapter._handle_model_picker_action({
        "chatId": "99",
        "messageId": "42",
        "interactionId": "interaction-model-1",
        "actionId": f"mp:{picker_id}:openrouter",
    })
    assert calls[-1][0] == "/edit"
    assert calls[-1][1]["messageId"] == "42"
    model_actions = calls[-1][1]["actions"]["rows"][0]["actions"]
    assert model_actions[0]["id"] == f"mm:{picker_id}:0"
    assert answers[-1] == ("interaction-model-1", "Choose a model")

    warning_state["warning"] = types.SimpleNamespace(message="this one is expensive")
    await adapter._handle_model_picker_action({
        "chatId": "99",
        "messageId": "42",
        "interactionId": "interaction-model-2",
        "actionId": f"mm:{picker_id}:1",
    })
    assert selected == []
    assert calls[-1][1]["actions"]["rows"][0]["actions"][0]["id"] == f"mc:{picker_id}:1"
    assert "Expensive model warning" in calls[-1][1]["text"]
    assert answers[-1] == ("interaction-model-2", "Confirm expensive model")

    warning_state["warning"] = None
    await adapter._handle_model_picker_action({
        "chatId": "99",
        "messageId": "42",
        "interactionId": "interaction-model-3",
        "actionId": f"mc:{picker_id}:1",
    })
    assert selected == [("chat:10", "anthropic/claude-sonnet", "openrouter")]
    assert picker_id not in adapter._model_picker_sessions
    assert calls[-1][1]["actions"] == {"rows": []}
    assert "switched to anthropic/claude-sonnet" in calls[-1][1]["text"]
    assert answers[-1] == ("interaction-model-3", "Model switched")

    await adapter._handle_model_picker_action({
        "chatId": "99",
        "messageId": "42",
        "interactionId": "interaction-model-4",
        "actionId": f"mx:{picker_id}",
    })
    assert answers[-1] == ("interaction-model-4", "Picker expired")

asyncio.run(assert_model_picker_flow())

async def assert_transport_helpers():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    calls = []

    async def fake_send_sidecar(path, body):
        calls.append((path, body))
        return SendResult(success=True, message_id=body.get("messageId") or "message-1", raw_response=body)

    async def fake_sidecar_call(path, body):
        calls.append((path, body))
        return {"ok": True, "result": {}}

    adapter._send_sidecar = fake_send_sidecar
    adapter._sidecar_call = fake_sidecar_call
    metadata = {"thread_id": "chat:99"}

    edited = await adapter.edit_message("chat:10", "777", "updated", metadata=metadata)
    assert edited.success
    assert calls[-1] == ("/edit", {
        "target": {"chatId": "99"},
        "messageId": "777",
        "text": "updated",
        "parseMarkdown": False,
    })

    final_edit = await adapter.edit_message("chat:10", "777", "**final**", finalize=True, metadata=metadata)
    assert final_edit.success
    assert calls[-1] == ("/edit", {
        "target": {"chatId": "99"},
        "messageId": "777",
        "text": "**final**",
        "parseMarkdown": True,
    })

    sent_preview = await adapter.send("chat:10", "**streaming**", metadata={**metadata, "expect_edits": True})
    assert sent_preview.success
    assert calls[-1][0] == "/send"
    assert calls[-1][1]["parseMarkdown"] is False

    preview_overflow = await adapter.edit_message(
        "chat:10",
        "777",
        "x" * (adapter.MAX_MESSAGE_LENGTH + 12),
        metadata=metadata,
    )
    assert preview_overflow.success
    assert calls[-1][0] == "/edit"
    assert len(calls[-1][1]["text"]) <= adapter.MAX_MESSAGE_LENGTH
    assert calls[-1][1]["parseMarkdown"] is False

    calls.clear()
    final_overflow = await adapter.edit_message(
        "chat:10",
        "777",
        "y" * (adapter.MAX_MESSAGE_LENGTH + 12),
        finalize=True,
        metadata=metadata,
    )
    assert final_overflow.success
    assert final_overflow.message_id == "message-1"
    assert calls[0][0] == "/edit"
    assert calls[0][1]["messageId"] == "777"
    assert calls[0][1]["parseMarkdown"] is True
    assert calls[1][0] == "/send"
    assert calls[1][1]["replyToMsgId"] == "777"
    assert calls[1][1]["parseMarkdown"] is True

    assert await adapter.delete_message("chat:10", "777", metadata=metadata)
    assert calls[-1] == ("/delete", {"target": {"chatId": "99"}, "messageId": "777"})

    await adapter.send_typing("chat:10", metadata=metadata)
    assert calls[-1] == ("/typing", {"target": {"chatId": "99"}, "state": "start"})

    await adapter.stop_typing("chat:10", metadata=metadata)
    assert calls[-1] == ("/typing", {"target": {"chatId": "99"}, "state": "stop"})

    animation = await adapter.send_animation("chat:10", "https://example.com/a.gif", "gif", metadata=metadata)
    assert animation.success
    assert calls[-1][0] == "/send-attachment"
    assert calls[-1][1]["target"] == {"chatId": "99"}
    assert calls[-1][1]["kind"] == "document"
    assert calls[-1][1]["caption"] == "gif"

asyncio.run(assert_transport_helpers())

async def assert_action_authorization():
    os.environ.pop("GATEWAY_ALLOWED_USERS", None)
    os.environ.pop("GATEWAY_ALLOW_ALL_USERS", None)
    adapter = InlineAdapter(PlatformConfig(extra={**base_extra, "group_policy": "allowlist", "group_allow_from": "u1"}))
    answers = []

    async def fake_fetch_message(chat_id, message_id):
        return {"peerId": {"type": {"oneofKind": "chat", "chat": {"chatId": chat_id}}}}

    async def fake_answer_action(interaction_id, toast):
        answers.append((interaction_id, toast))

    adapter._fetch_message = fake_fetch_message
    adapter._answer_action = fake_answer_action
    adapter._approval_sessions["approval-1"] = "session-1"

    allowed = await adapter._action_allowed({
        "chatId": "10",
        "messageId": "20",
        "interactionId": "interaction-1",
        "actorUserId": "u1",
        "actionId": "appr:approval-1:approve",
    })
    assert allowed
    assert answers == []

    denied = await adapter._handle_action({
        "chatId": "10",
        "messageId": "20",
        "interactionId": "interaction-2",
        "actorUserId": "u2",
        "actionId": "appr:approval-1:approve",
    })
    assert denied
    assert answers == [("interaction-2", "Not authorized")]
    assert adapter._approval_sessions["approval-1"] == "session-1"

    unknown_context = await adapter._action_allowed({
        "chatId": "10",
        "interactionId": "interaction-3",
        "actorUserId": "u1",
        "actionId": "appr:approval-1:approve",
    })
    assert not unknown_context
    assert answers[-1] == ("interaction-3", "Not authorized")

    open_adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    open_answers = []
    open_adapter._fetch_message = fake_fetch_message

    async def fake_open_answer_action(interaction_id, toast):
        open_answers.append((interaction_id, toast))

    open_adapter._answer_action = fake_open_answer_action
    assert not await open_adapter._action_allowed({
        "chatId": "10",
        "messageId": "20",
        "interactionId": "interaction-4",
        "actorUserId": "u1",
        "actionId": "appr:approval-1:approve",
    })
    assert open_answers == [("interaction-4", "Not authorized")]

    os.environ["GATEWAY_ALLOWED_USERS"] = "u1"
    gateway_allowed = InlineAdapter(PlatformConfig(extra=base_extra))
    gateway_allowed._fetch_message = fake_fetch_message
    assert await gateway_allowed._action_allowed({
        "chatId": "10",
        "messageId": "20",
        "interactionId": "interaction-5",
        "actorUserId": "u1",
        "actionId": "appr:approval-1:approve",
    })
    os.environ.pop("GATEWAY_ALLOWED_USERS", None)

    inline_allowed = InlineAdapter(PlatformConfig(extra={**base_extra, "allow_from": "u1"}))
    inline_allowed._fetch_message = fake_fetch_message
    assert await inline_allowed._action_allowed({
        "chatId": "10",
        "messageId": "20",
        "interactionId": "interaction-6",
        "actorUserId": "u1",
        "actionId": "appr:approval-1:approve",
    })

asyncio.run(assert_action_authorization())

async def assert_callback_state_lifecycle():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    answers = []
    sends = []

    async def fake_answer_action(interaction_id, toast):
        answers.append((interaction_id, toast))

    async def fake_send(chat_id, content, reply_to=None, metadata=None):
        sends.append((chat_id, content, reply_to, metadata))
        return SendResult(success=True, message_id=str(len(sends)))

    adapter._answer_action = fake_answer_action
    adapter.send = fake_send

    adapter._approval_sessions["approval-2"] = "session-2"
    approval_state["fail"] = True
    assert await adapter._handle_approval_action("appr:approval-2:approve", "chat:10", "interaction-7")
    assert adapter._approval_sessions["approval-2"] == "session-2"
    assert answers == []

    approval_state["fail"] = False
    approval_state["count"] = 1
    assert await adapter._handle_approval_action("appr:approval-2:approve", "chat:10", "interaction-8")
    assert "approval-2" not in adapter._approval_sessions
    assert answers[-1] == ("interaction-8", "Approved")
    assert sends[-1][1] == "Approved."

    adapter._approval_sessions["approval-expired"] = "session-expired"
    approval_state["count"] = 0
    assert await adapter._handle_approval_action("appr:approval-expired:deny", "chat:10", "interaction-9")
    assert "approval-expired" not in adapter._approval_sessions
    assert answers[-1] == ("interaction-9", "Approval expired")
    approval_state["count"] = 1

    adapter._slash_sessions["confirm-2"] = "session-3"
    slash_state["fail"] = True
    assert await adapter._handle_slash_action("sc:once:confirm-2", "chat:10", "interaction-10")
    assert adapter._slash_sessions["confirm-2"] == "session-3"

    slash_state["fail"] = False
    slash_state["result"] = "slash done"
    assert await adapter._handle_slash_action("sc:once:confirm-2", "chat:10", "interaction-11")
    assert "confirm-2" not in adapter._slash_sessions
    assert answers[-1] == ("interaction-11", "Recorded")
    assert sends[-1][1] == "slash done"

    adapter._slash_sessions["confirm-cancel"] = "session-4"
    slash_state["result"] = None
    send_count = len(sends)
    assert await adapter._handle_slash_action("sc:cancel:confirm-cancel", "chat:10", "interaction-12")
    assert "confirm-cancel" not in adapter._slash_sessions
    assert len(sends) == send_count

    adapter._clarify_sessions["clarify-2"] = "session-5"
    adapter._clarify_choices["clarify-2"] = ["A", "B"]
    clarify_state["resolve"] = False
    assert await adapter._handle_clarify_action("cl:clarify-2:0", "chat:10", "interaction-13")
    assert "clarify-2" not in adapter._clarify_sessions
    assert "clarify-2" not in adapter._clarify_choices
    assert answers[-1] == ("interaction-13", "Prompt expired")

    adapter._clarify_sessions["clarify-3"] = "session-6"
    adapter._clarify_choices["clarify-3"] = ["A"]
    clarify_state["mark"] = False
    assert await adapter._handle_clarify_action("cl:clarify-3:other", "chat:10", "interaction-14")
    assert "clarify-3" not in adapter._clarify_sessions
    assert "clarify-3" not in adapter._clarify_choices
    assert answers[-1] == ("interaction-14", "Prompt expired")

asyncio.run(assert_callback_state_lifecycle())

async def assert_inline_lifecycle_events():
    adapter = InlineAdapter(PlatformConfig(extra={**base_extra, "group_policy": "open"}))
    adapter._me_id = "bot"
    events = []

    async def capture(event):
        events.append(event)

    async def own_message(chat_id, message_id):
        return {
            "id": message_id,
            "fromId": "bot",
            "message": "Bot answer",
            "peerId": {"type": {"oneofKind": "chat", "chat": {"chatId": chat_id}}},
        }

    adapter.handle_message = capture
    adapter._fetch_message = own_message

    await adapter._on_inbound(json.dumps({
        "kind": "reaction.add",
        "chatId": "10",
        "seq": 21,
        "date": "100",
        "reaction": {"chatId": "10", "messageId": "20", "userId": "u1", "emoji": "ok", "date": "100"},
    }))

    assert len(events) == 1
    assert events[0].text == "reaction:added:ok"
    assert events[0].reply_to_message_id == "20"
    assert events[0].reply_to_text == "Bot answer"
    assert events[0].reply_to_is_own_message is True
    assert events[0].source.chat_id == "10"
    assert events[0].source.user_id == "u1"

    async def human_message(chat_id, message_id):
        return {
            "id": message_id,
            "fromId": "u2",
            "message": "Human message",
            "peerId": {"type": {"oneofKind": "chat", "chat": {"chatId": chat_id}}},
        }

    adapter._fetch_message = human_message
    await adapter._on_inbound(json.dumps({
        "kind": "reaction.add",
        "chatId": "10",
        "seq": 22,
        "date": "101",
        "reaction": {"chatId": "10", "messageId": "21", "userId": "u1", "emoji": "ok", "date": "101"},
    }))
    assert len(events) == 1

    system_adapter = InlineAdapter(PlatformConfig(extra={**base_extra, "system_events": True}))
    system_adapter._me_id = "bot"
    system_events = []

    async def capture_system(event):
        system_events.append(event)

    system_adapter.handle_message = capture_system
    system_adapter._fetch_message = human_message

    await system_adapter._on_inbound(json.dumps({
        "kind": "chat.participant.add",
        "chatId": "10",
        "seq": 23,
        "date": "102",
        "participant": {"userId": "u3"},
    }))
    assert system_events[-1].text == "participant:joined:u3"
    assert system_events[-1].source.chat_type == "group"

    await system_adapter._on_inbound(json.dumps({
        "kind": "message.edit",
        "chatId": "30",
        "seq": 24,
        "date": "103",
        "message": {
            "id": "40",
            "fromId": "u1",
            "chatId": "30",
            "peerId": {"type": {"oneofKind": "user", "user": {"userId": "u1"}}},
            "message": "updated",
            "date": "103",
        },
    }))
    assert system_events[-1].text == "message:edited:updated"
    assert system_events[-1].source.chat_type == "dm"

asyncio.run(assert_inline_lifecycle_events())

async def assert_inline_media_normalization():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    calls = []

    async def fake_cache(url, *, kind, mime, file_name):
        calls.append((url, kind, mime, file_name))
        return f"/tmp/inline-{kind}"

    adapter._cache_inline_media_url = fake_cache
    text, urls, types_, msg_type = await adapter._normalize_media({
        "media": {
            "media": {
                "oneofKind": "photo",
                "photo": {
                    "photo": {
                        "id": "101",
                        "fileUniqueId": "INP_photo",
                        "format": 2,
                        "sizes": [
                            {"w": 320, "h": 240, "size": 1000, "cdnUrl": "https://cdn.inline.chat/small.png"},
                            {"w": 1280, "h": 720, "size": 4567, "cdnUrl": "https://cdn.inline.chat/large.png"},
                        ],
                    },
                },
            },
        },
    })
    assert text == "[Inline photo attachment: image/png, 1280x720, 4.5 KB, id=101, file=INP_photo]"
    assert urls == ["/tmp/inline-photo"]
    assert types_ == ["image/png"]
    assert msg_type == MessageType.PHOTO
    assert calls[-1] == ("https://cdn.inline.chat/large.png", "photo", "image/png", None)

    text, urls, types_, msg_type = await adapter._normalize_media({
        "media": {
            "oneofKind": "document",
            "document": {
                "document": {
                    "id": "202",
                    "fileName": "spec.pdf",
                    "mimeType": "application/pdf",
                    "size": 1048576,
                    "cdnUrl": "https://cdn.inline.chat/spec.pdf",
                },
            },
        },
    })
    assert text == "[Inline document attachment: spec.pdf, application/pdf, 1.0 MB, id=202]"
    assert urls == ["/tmp/inline-document"]
    assert types_ == ["application/pdf"]
    assert msg_type == MessageType.DOCUMENT
    assert calls[-1] == ("https://cdn.inline.chat/spec.pdf", "document", "application/pdf", "spec.pdf")

    text, urls, types_, msg_type = await adapter._normalize_media({
        "media": {
            "media": {
                "oneofKind": "voice",
                "voice": {
                    "voice": {
                        "id": "303",
                        "mimeType": "audio/ogg",
                        "duration": 12,
                        "size": 9000,
                    },
                },
            },
        },
    })
    assert text == "[Inline voice attachment: audio/ogg, 12s, 8.8 KB, id=303]"
    assert urls == []
    assert types_ == []
    assert msg_type == MessageType.VOICE

asyncio.run(assert_inline_media_normalization())

async def assert_standalone_sender():
    calls = []
    originals = {
        "connect": InlineAdapter.connect,
        "disconnect": InlineAdapter.disconnect,
        "send": InlineAdapter.send,
        "send_image_file": InlineAdapter.send_image_file,
        "send_video": InlineAdapter.send_video,
        "send_voice": InlineAdapter.send_voice,
        "send_document": InlineAdapter.send_document,
    }

    async def fake_connect(self, is_reconnect=False):
        calls.append(("connect", is_reconnect, self._sidecar_port))
        return True

    async def fake_disconnect(self):
        calls.append(("disconnect",))

    async def fake_send(self, chat_id, content, reply_to=None, metadata=None):
        calls.append(("send", chat_id, content, reply_to, metadata))
        return SendResult(success=True, message_id="text-1")

    async def fake_image(self, chat_id, path, caption=None, metadata=None):
        calls.append(("image", chat_id, path, caption, metadata))
        return SendResult(success=True, message_id="photo-1")

    async def fake_video(self, chat_id, path, caption=None, metadata=None):
        calls.append(("video", chat_id, path, caption, metadata))
        return SendResult(success=True, message_id="video-1")

    async def fake_voice(self, chat_id, path, caption=None, metadata=None):
        calls.append(("voice", chat_id, path, caption, metadata))
        return SendResult(success=True, message_id="voice-1")

    async def fake_document(self, chat_id, path, file_name=None, caption=None, metadata=None):
        calls.append(("document", chat_id, path, file_name, caption, metadata))
        return SendResult(success=True, message_id="document-1")

    try:
        InlineAdapter.connect = fake_connect
        InlineAdapter.disconnect = fake_disconnect
        InlineAdapter.send = fake_send
        InlineAdapter.send_image_file = fake_image
        InlineAdapter.send_video = fake_video
        InlineAdapter.send_voice = fake_voice
        InlineAdapter.send_document = fake_document

        result = await _standalone_send(
            PlatformConfig(token="standalone-token", extra={**base_extra, "sidecar_port": 6543}),
            "chat:10",
            "hello",
            thread_id="chat:99",
            media_files=[
                ("/tmp/photo.png", False),
                ("/tmp/voice.ogg", True),
                ("/tmp/movie.mp4", False),
                ("/tmp/spec.pdf", False),
            ],
        )

        assert result["success"] is True
        assert result["message_ids"] == ["text-1", "photo-1", "voice-1", "video-1", "document-1"]
        assert result["message_id"] == "document-1"
        assert result["thread_id"] == "chat:99"
        assert [call[0] for call in calls] == ["connect", "send", "image", "voice", "video", "document", "disconnect"]
        assert 1 <= calls[0][2] <= 65535
        assert calls[0][2] != 6543
        assert calls[1][4] == {"thread_id": "chat:99"}
        assert calls[2][4] == {"thread_id": "chat:99"}
        assert calls[3][4] == {"thread_id": "chat:99"}
        assert calls[4][4] == {"thread_id": "chat:99"}
        assert calls[5][5] == {"thread_id": "chat:99"}

        calls.clear()
        forced = await _standalone_send(
            PlatformConfig(token="standalone-token", extra=base_extra),
            "chat:10",
            "",
            media_files=[("/tmp/photo.png", False)],
            force_document=True,
        )
        assert forced["success"] is True
        assert [call[0] for call in calls] == ["connect", "document", "disconnect"]
        assert calls[1][3] == "photo.png"

        missing = await _standalone_send(PlatformConfig(extra={}), "chat:10", "hello")
        assert missing["error"] == "Inline token is required in INLINE_TOKEN, INLINE_BOT_TOKEN, or Hermes Inline config"
    finally:
        InlineAdapter.connect = originals["connect"]
        InlineAdapter.disconnect = originals["disconnect"]
        InlineAdapter.send = originals["send"]
        InlineAdapter.send_image_file = originals["send_image_file"]
        InlineAdapter.send_video = originals["send_video"]
        InlineAdapter.send_voice = originals["send_voice"]
        InlineAdapter.send_document = originals["send_document"]

asyncio.run(assert_standalone_sender())

def open_loopback_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port

async def assert_adapter_sidecar_loopback():
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        image_path = tmp_path / "photo.png"
        image_path.write_bytes(b"fake image")
        adapter = InlineAdapter(PlatformConfig(
            token="loopback-token",
            extra={
                **base_extra,
                "base_url": "http://127.0.0.1/mock-inline",
                "sidecar_port": open_loopback_port(),
                "state_path": str(tmp_path / "inline-state.json"),
                "parse_markdown": False,
            },
        ))

        connected = await adapter.connect()
        assert connected, getattr(adapter, "fatal_error", None)
        try:
            assert adapter.connected is True
            assert adapter._me_id == "999"

            metadata = {"thread_id": "chat:456"}
            sent = await adapter.send("chat:123", "hello", reply_to="7", metadata=metadata)
            assert sent.success is True
            assert sent.message_id == "9001"

            edited = await adapter.edit_message("chat:123", "9001", "updated", metadata=metadata)
            assert edited.success is True
            assert edited.message_id == "9001"

            assert await adapter.delete_message("chat:123", "9001", metadata=metadata)
            await adapter.send_typing("chat:123", metadata=metadata)
            await adapter.stop_typing("chat:123", metadata=metadata)

            image = await adapter.send_image_file("chat:123", str(image_path), caption="attached", reply_to="8", metadata=metadata)
            assert image.success is True
            assert image.message_id == "9002"

            info = await adapter.get_chat_info("chat:123")
            assert info["name"] == "Mock chat 123"

            thread_id = await adapter.create_handoff_thread("123", "Spec thread")
            assert thread_id == "321"
        finally:
            await adapter.disconnect()

        assert adapter.connected is False
        assert adapter._sidecar_proc is None

asyncio.run(assert_adapter_sidecar_loopback())

async def assert_connect_does_not_block_on_command_sync():
    adapter = InlineAdapter(PlatformConfig(extra={**base_extra, "sync_commands": True}))
    sync_started = asyncio.Event()
    sync_released = asyncio.Event()

    async def fake_start_sidecar():
        adapter._me_id = "999"

    async def fake_inbound_loop():
        await asyncio.sleep(30)

    async def fake_sync_bot_commands():
        sync_started.set()
        await sync_released.wait()

    adapter._start_sidecar = fake_start_sidecar
    adapter._inbound_loop = fake_inbound_loop
    adapter._sync_bot_commands = fake_sync_bot_commands

    connected = await adapter.connect()
    assert connected is True
    assert adapter.connected is True
    assert adapter._command_sync_task is not None
    await asyncio.wait_for(sync_started.wait(), timeout=1)

    await adapter.disconnect()
    assert adapter._command_sync_task is None
    assert adapter._inbound_task is None
    assert adapter.connected is False

asyncio.run(assert_connect_does_not_block_on_command_sync())

async def assert_disconnect_cleans_after_inbound_cancel():
    adapter = InlineAdapter(PlatformConfig(extra=base_extra))
    calls = []

    class FakeClient:
        async def aclose(self):
            calls.append("aclose")

    async def fake_stop_sidecar():
        calls.append("stop")

    adapter.connected = True
    adapter._http_client = FakeClient()
    adapter._stop_sidecar = fake_stop_sidecar
    adapter._inbound_running = True
    adapter._inbound_task = asyncio.create_task(asyncio.sleep(30))

    await adapter.disconnect()

    assert adapter._inbound_task is None
    assert adapter._http_client is None
    assert calls == ["stop", "aclose"]
    assert adapter.connected is False

asyncio.run(assert_disconnect_cleans_after_inbound_cancel())

print("adapter python smoke ok")
`

describe("python adapter smoke", () => {
  it("imports adapter and enforces access policy helpers", () => {
    const result = spawnSync("python3", ["-c", script], {
      cwd: packageRoot,
      encoding: "utf8",
      env: {
        ...process.env,
        INLINE_TOKEN: "",
        INLINE_BOT_TOKEN: "",
        INLINE_ALLOWED_USERS: "",
        INLINE_GROUP_ALLOW_FROM: "",
        INLINE_ALLOW_ALL_USERS: "",
        INLINE_SYSTEM_EVENTS: "",
        INLINE_SIDECAR_TEST_MOCK: "1",
        INLINE_SIDECAR_TEST_ALLOW_MOCK: "1",
        INLINE_NODE_BIN: nodeBin,
        GATEWAY_ALLOWED_USERS: "",
        GATEWAY_ALLOW_ALL_USERS: "",
      },
    })

    expect(result.status, result.stderr || result.stdout).toBe(0)
    expect(result.stdout).toContain("adapter python smoke ok")
  }, 30_000)
})
