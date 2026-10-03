"""Real Hermes host contract test; fake HTTP transport and deterministic reply handler.

No Hermes modules are stubbed. This is offline host integration, not live messaging
or an LLM-provider test. Run with isolated HERMES_HOME containing the installed plugin.
"""
import asyncio
import importlib.util
import json
import os
import socket
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import httpx
try:
    import hermes_yaml as yaml
except ModuleNotFoundError as exc:
    if exc.name != "hermes_yaml":
        raise
    import yaml

home = Path(os.environ["HERMES_HOME"])
# Every HTTP request below uses an offline transport. Register the configured
# platform without depending on a CI secret or an operator's inherited token.
os.environ["INLINE_TOKEN"] = "offline-test-token"
os.environ["INLINE_BOT_TOKEN"] = ""
plugin = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else home / "plugins" / "inline"
manifest = yaml.safe_load((plugin / "plugin.yaml").read_text())
assert "inline" in manifest.get("provides_tools", []), "inline tool missing from plugin.yaml"

# Older hosts retain the deprecated-import scanner. After the compat layer's
# removal, plugin_compat remains only as updater stubs; real loading below is
# the authoritative import check on those hosts.
if importlib.util.find_spec("hermes_cli.plugin_compat"):
    from hermes_cli import plugin_compat
    scan_plugin = getattr(plugin_compat, "scan_plugin", None)
    if scan_plugin is not None:
        hits = scan_plugin(plugin)
        assert not hits, f"deprecated Hermes imports: {hits}"
if importlib.util.find_spec("hermes_cli.plugin_validate"):
    from hermes_cli.plugin_validate import validate_plugin_dir
    report = validate_plugin_dir(plugin)
    print(json.dumps(report.to_dict(), indent=2))
    assert report.ok, report.failures

from hermes_cli.plugins import get_plugin_manager
from gateway.platform_registry import platform_registry
from gateway.config import PlatformConfig
from tools.registry import registry

manager = get_plugin_manager()
manager.discover_and_load()
# Platform registration can be deferred until the gateway asks for the adapter.
entry = platform_registry.get("inline")
assert entry is not None, "Hermes did not register Inline"
adapter = platform_registry.create_adapter("inline", PlatformConfig(
    enabled=True, token="offline-test-token", extra={
        "dm_policy": "open", "reply_threads": "off", "context_backfill": "off",
        "reactions": False, "sync_commands": False, "text_debounce_seconds": 0,
        "state_path": str(home / "inline" / "sdk-state.json"),
        "settings_path": str(home / "inline" / "adapter-settings.json"),
    },
))
assert adapter is not None, "Hermes rejected the adapter factory"
loaded = next(p for p in manager.list_plugins() if p["name"] == "inline-platform")
assert loaded["enabled"] and not loaded["error"], loaded
assert registry.get_schema("inline")["name"] == "inline", "tool registration failed"
cli = importlib.import_module(type(adapter).__module__.rsplit(".", 1)[0] + ".cli")
if hasattr(cli, "_compatibility_status"):
    compatibility = cli._compatibility_status()
    assert compatibility.get("ok") is True, compatibility


async def exercise_candidate_loader_and_send_only():
    """Stock-host compatibility is separate from the matching intake core gate."""
    from gateway.platforms.base import BasePlatformAdapter
    capability = cli._receiving_capability_status()
    assert capability["requiredIntakeVersion"] == 1
    assert capability["supported"] is (getattr(BasePlatformAdapter, "durable_intake_version", None) == 1), capability
    assert not await adapter.connect(), "An unwired host advertised receiving"
    assert adapter.fatal_error_code == "DURABLE_INTAKE_REQUIRED"
    assert not adapter.is_connected and adapter._sidecar_proc is None and adapter._inbound_task is None
    sender = type(adapter)(PlatformConfig(enabled=True, token="offline-test-token", extra={
        "sidecar_autostart": False, "sync_commands": False,
    }), send_only=True)
    writes = []
    real_client = httpx.AsyncClient

    def response(request):
        if request.url.path == "/healthz":
            return httpx.Response(200, json={"ok": True, "result": {
                "connected": True, "meId": "999", "baseUrl": sender._base_url, "sendOnly": True,
            }})
        assert request.url.path == "/send", "Send-only contacted an intake or settings writer"
        writes.append(json.loads(request.content))
        return httpx.Response(200, json={"ok": True, "result": {"messageId": "202"}})

    def client(*args, **kwargs):
        return real_client(*args, **kwargs, transport=httpx.MockTransport(response))

    with patch("httpx.AsyncClient", side_effect=client):
        assert await sender.connect()
        try:
            result = await sender.send("user:42", "Offline send-only compatibility")
            assert result.success and result.message_id == "202"
            assert writes[0]["target"] == {"userId": "42"}
            assert sender._inbound_task is None and not sender._state_file_locks
        finally:
            await sender.disconnect()


if getattr(adapter, "durable_intake", False) is True:
    asyncio.run(exercise_candidate_loader_and_send_only())
    print("Real Hermes loader/tool/send-only compatibility and actionable unwired receive refusal passed. Receiving requires the separately tested matching core, gateway handlers, and profile StateDB.")
    sys.exit(0)


async def exercise():
    sent = []
    received = []
    delivered = asyncio.Event()

    def transport(request):
        body = json.loads(request.content)
        if request.url.path == "/send":
            sent.append(body)
            delivered.set()
        return httpx.Response(200, json={"ok": True, "result": {"messageId": "202"}})

    async def reply(event):
        received.append(event)
        return "Hermes host reply"

    adapter._http_client = httpx.AsyncClient(transport=httpx.MockTransport(transport))
    adapter.set_message_handler(reply)
    adapter.set_authorization_check(lambda *_args, **_kwargs: True)
    event = {"kind": "message.new", "seq": 1, "chatId": "101", "meId": "999", "message": {
        "id": "201", "chatId": "101", "fromId": "42", "message": "hello Hermes",
        "peerId": {"peer": {"oneofKind": "user", "user": {"userId": "42"}}},
    }}
    try:
        await adapter._on_inbound(json.dumps(event))
        await asyncio.wait_for(delivered.wait(), timeout=10)
        assert len(received) == 1, received
        assert received[0].text == "hello Hermes"
        assert received[0].source.user_id == "42"
        assert sent[0]["text"] == "Hermes host reply", sent
        assert sent[0]["target"]["chatId"] == "101", sent
        await adapter._on_inbound(json.dumps(event))
        assert len(received) == 1, "duplicate inbound reached Hermes twice"

        # The real helper must reject these before HTTP construction, even if imports drift.
        for url in ("http://127.0.0.1/private", "http://10.0.0.1/private", "http://[::1]/private", "http://169.254.169.254/latest/meta-data/"):
            with patch("httpx.AsyncClient", side_effect=AssertionError("unsafe URL reached HTTP")):
                try:
                    await adapter._download_inline_media_url(url, mime="image/png", file_name="test.png")
                except ValueError as exc:
                    assert "unsafe" in str(exc).lower(), str(exc)
                else:
                    raise AssertionError(f"unsafe URL accepted: {url}")
        # Positive control: a public URL is downloaded through the actual helper.
        real_client = httpx.AsyncClient
        downloads = []
        def media_response(request):
            downloads.append(str(request.url))
            return httpx.Response(200, content=b"offline-image", headers={"content-type": "image/png"})
        def media_client(*args, **kwargs):
            return real_client(*args, **kwargs, transport=httpx.MockTransport(media_response))
        public_dns = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))]
        cache = Path(tempfile.mkdtemp(prefix="inline-hermes-media-"))
        with patch("socket.getaddrinfo", return_value=public_dns), patch("httpx.AsyncClient", side_effect=media_client), patch.object(adapter, "_media_cache_dir", cache):
            result = await adapter._download_inline_media_url("https://example.org/image.png", mime="image/png", file_name="test.png")
        assert Path(result).read_bytes() == b"offline-image"
        assert downloads == ["https://example.org/image.png"]
    finally:
        await adapter._http_client.aclose()

asyncio.run(exercise())


async def exercise_authorization():
    from gateway.run import GatewayRunner
    from gateway.pairing import PairingStore

    # Construct only the runner state required by its real authorization callback;
    # starting a gateway would introduce credentials, networking and provider work.
    runner = GatewayRunner.__new__(GatewayRunner)
    runner.config = SimpleNamespace(multiplex_profiles=False)
    runner.adapters = {adapter.platform: adapter}
    runner._profile_adapters = {}
    runner._primary_profile_name = "default"
    runner.pairing_store = PairingStore()
    runner.pairing_stores = {}
    adapter.set_authorization_check(runner._make_adapter_auth_check(adapter.platform))

    def authorized(user="42", chat="101", chat_type="dm"):
        return adapter._actor_authorized(chat_type, user, chat)

    # Pairing's allowlist mirroring is intentionally disabled: exercise the real
    # persisted pairing grant in isolation without reading or writing env files.
    auth_env = {key: "" for key in (
        "INLINE_ALLOWED_USERS", "INLINE_ALLOW_ALL_USERS", "GATEWAY_ALLOWED_USERS",
        "GATEWAY_ALLOW_ALL_USERS",
    )}
    with patch.dict(os.environ, auth_env), patch("gateway.pairing._sync_allowlist_add"), patch("gateway.pairing._sync_allowlist_remove"):
        assert authorized() is False, "unknown sender bypassed real host default deny"
        code = runner.pairing_store.generate_code("inline", "42", "Offline fixture")
        assert code is not None
        assert runner.pairing_store.approve_code("inline", code) is not None
        assert authorized() is True, "host pairing grant did not reach local authorization"
        assert authorized("43") is False

        secondary_store = PairingStore(profile="secondary")
        runner.pairing_stores["secondary"] = secondary_store
        runner._profile_adapters["secondary"] = {adapter.platform: adapter}
        adapter.set_authorization_check(runner._make_adapter_auth_check(adapter.platform, "secondary"))
        assert authorized() is False, "primary pairing grant leaked into secondary profile"
        secondary_code = secondary_store.generate_code("inline", "42", "Secondary fixture")
        assert secondary_code is not None
        assert secondary_store.approve_code("inline", secondary_code) is not None
        assert authorized() is True, "profile-bound callback missed its pairing grant"
        assert secondary_store.revoke("inline", "42")
        assert authorized() is False, "secondary pairing revocation was not observed"
        adapter.set_authorization_check(runner._make_adapter_auth_check(adapter.platform))
        assert authorized() is True, "secondary revocation removed primary grant"

        # The callback executes the actual runner predicate, which may consult
        # adapter policy. A recursion here must fail this positive pairing check.
        adapter._dm_policy = "disabled"
        assert authorized() is False, "host grant overrode disabled DM policy"
        adapter._dm_policy = "open"
        adapter._allowed_chats = {"102"}
        assert authorized(chat_type="group") is False, "host grant overrode allowed chats"
        adapter._allowed_chats = set()
        adapter._dm_policy = "allowlist"
        adapter._allow_from = {"43"}
        assert authorized() is False, "pairing bypassed explicit local sender restriction"
        adapter._allow_from = {"42"}
        assert authorized() is True
        adapter._dm_policy = "open"
        adapter._allow_from = set()

        # Exercise local mutations through ingress, with host-approved and unknown
        # actors. HTTP and final message delivery stay offline; no LLM is invoked.
        delivered, mutations = [], []

        async def receive(event):
            delivered.append(event)

        async def status(**kwargs):
            pass

        async def create_thread(*args):
            mutations.append(args)
            return "301"

        async def dispatch(user, message, seq):
            await adapter._dispatch_message({"kind": "message.new", "seq": seq, "chatId": "101", "message": {
                "id": str(seq), "chatId": "101", "fromId": user, "message": message,
                "peerId": {"peer": {"oneofKind": "user", "user": {"userId": user}}},
            }})

        with patch.object(adapter, "handle_message", receive), patch.object(adapter, "_send_thread_status", status), patch.object(adapter, "_create_reply_thread", create_thread):
            await dispatch("43", "/threads off", 1001)
            assert "101" not in adapter._reply_thread_overrides
            assert delivered[-1].text == "/threads off", "unknown DM lost host pairing ingress"
            assert delivered[-1].source.user_id == "43"
            await dispatch("42", "/threads off", 1002)
            assert adapter._reply_thread_overrides["101"] == "off"
            adapter._set_reply_threads_for_chat("101", "on")
            await dispatch("43", "ordinary unknown message", 1003)
            assert not mutations, "unknown sender created a reply thread before host authorization"
            await dispatch("42", "ordinary paired message", 1004)
            assert len(mutations) == 1, "paired sender lost automatic threads"

        assert runner.pairing_store.revoke("inline", "42")
        assert authorized() is False, "revocation was hidden by cached adapter authorization"
        adapter._dm_policy = "allowlist"
        adapter._allow_from = {"42"}
        assert authorized() is True, "real host adapter-policy delegation recursed or lost allowlist grant"
        adapter._dm_policy = "open"
        adapter._allow_from = set()

        # A real host denial must outrank an adapter-local allow-all setting.
        adapter._allow_all = True
        assert authorized() is False
        adapter._allow_all = False
        with patch.dict(os.environ, {"GATEWAY_ALLOW_ALL_USERS": "true"}):
            assert authorized() is True
            adapter._dm_policy = "disabled"
            assert authorized() is False
            adapter._dm_policy = "open"
            adapter._allowed_chats = {"102"}
            assert authorized(chat_type="group") is False
            adapter._allowed_chats = set()

        from gateway.profile_routing import ProfileRoute

        # Parent-routed Inline threads need the full source: the standard host
        # callback carries a child/thread ID but cannot carry parent_chat_id.
        runner.config.multiplex_profiles = True
        runner.config.profile_routes = [
            ProfileRoute(name="parent-work", platform="inline", profile="work", chat_id="700"),
        ]
        adapter.gateway_runner = runner
        for profile in ("work", "child"):
            (home / "profiles" / profile).mkdir(parents=True, exist_ok=True)
            (home / "profiles" / profile / "config.yaml").write_text("{}\n")
            runner.pairing_stores[profile] = PairingStore(profile=profile)

        def approve(store, user):
            code = store.generate_code("inline", user, "Route fixture")
            assert code is not None
            assert store.approve_code("inline", code) is not None

        approve(runner.pairing_stores["work"], "44")
        adapter.set_authorization_check(runner._make_adapter_auth_check(adapter.platform))
        assert adapter._is_sender_authorized("44", "group", "701", thread_id="701") is False
        with patch.object(runner, "_is_user_authorized_for_source", wraps=runner._is_user_authorized_for_source) as host_authorize:
            assert adapter._actor_authorized("group", "44", "701", thread_id="701", parent_chat_id="700") is True
            admitted = host_authorize.call_args.args[0]
            assert (admitted.chat_id, admitted.thread_id, admitted.parent_chat_id, admitted.profile) == ("701", "701", "700", "work")

        # A more specific child route wins; replacing the child ID with its
        # parent to authorize would accidentally admit the parent-profile user.
        runner.config.profile_routes.append(
            ProfileRoute(name="child-only", platform="inline", profile="child", thread_id="701"),
        )
        # GatewayConfig normally receives this order from parse_profile_routes.
        runner.config.profile_routes.sort(key=lambda route: route.specificity, reverse=True)
        approve(runner.pairing_stores["child"], "45")
        assert adapter._actor_authorized("group", "44", "701", thread_id="701", parent_chat_id="700") is False
        with patch.object(runner, "_is_user_authorized_for_source", wraps=runner._is_user_authorized_for_source) as host_authorize:
            assert adapter._actor_authorized("group", "45", "701", thread_id="701", parent_chat_id="700") is True
            admitted = host_authorize.call_args.args[0]
            assert (admitted.chat_id, admitted.thread_id, admitted.profile) == ("701", "701", "child")

        approve(runner.pairing_store, "44")
        runner.config.profile_routes = [
            ProfileRoute(name="unserved", platform="inline", profile="missing", chat_id="700"),
        ]
        rejected = adapter.build_source(chat_id="701", chat_type="group", user_id="44", thread_id="701", parent_chat_id="700")
        assert rejected.profile_route_rejected is True
        assert adapter._actor_authorized("group", "44", "701", thread_id="701", parent_chat_id="700") is False

        # Missing child metadata must not turn a routed thread into a default
        # profile chat and use that profile's otherwise valid pairing grant.
        async def missing_info(chat_id, **kwargs):
            return {}

        async def child_message(chat_id, message_id):
            return {"id": message_id, "peerId": {"type": {"oneofKind": "chat"}}}

        answers = []

        async def answer(interaction_id, message):
            answers.append(message)

        with patch.object(adapter, "_get_chat_info", missing_info), patch.object(adapter, "_fetch_message", child_message), patch.object(adapter, "_answer_action", answer), patch.object(adapter, "handle_message", receive):
            assert not await adapter._action_allowed({"chatId": "701", "messageId": "1", "actorUserId": "44", "interactionId": "missing-route"})
            assert answers == ["Access check temporarily unavailable. Try again."]
            delivered.clear()
            try:
                await adapter._dispatch_message({"kind": "message.new", "seq": 2001, "chatId": "701", "message": {
                    "id": "2001", "fromId": "44", "message": "@bot hello", "mentioned": True,
                    "peerId": {"type": {"oneofKind": "chat"}},
                }})
            except RuntimeError as exc:
                assert type(exc).__name__ == "InlineInboundDeferred"
            else:
                raise AssertionError("missing routing metadata was not deferred")
            assert not delivered, "missing routing metadata borrowed default pairing approval"


asyncio.run(exercise_authorization())
async def exercise_receipt_recovery():
    from gateway.run import GatewayRunner
    from gateway.pairing import PairingStore

    recovered = platform_registry.create_adapter("inline", PlatformConfig(
        enabled=True, token="offline-test-token", extra={
            "dm_policy": "open", "reply_threads": "off", "context_backfill": "off",
            "sync_commands": False, "text_debounce_seconds": 0,
            "state_path": str(home / "workflow" / "sdk-state.json"),
            "settings_path": str(home / "workflow" / "adapter-settings.json"),
        },
    ))
    assert recovered is not None
    module = sys.modules[type(recovered).__module__]
    runner = GatewayRunner.__new__(GatewayRunner)
    runner.config = SimpleNamespace(multiplex_profiles=False)
    runner.adapters = {recovered.platform: recovered}
    runner._profile_adapters = {}
    runner._primary_profile_name = "default"
    runner.pairing_store = PairingStore()
    runner.pairing_stores = {}
    recovered.set_authorization_check(runner._make_adapter_auth_check(recovered.platform))
    acknowledgements, received = [], []
    model_started, release_model, replied = asyncio.Event(), asyncio.Event(), asyncio.Event()

    def transport(request):
        body = json.loads(request.content)
        if request.url.path == "/inbound/ack":
            acknowledgements.append(body["deliveryId"])
        elif request.url.path == "/send":
            replied.set()
        return httpx.Response(200, json={"ok": True, "result": {"messageId": "9002"}})

    async def model(event):
        received.append(event)
        model_started.set()
        await release_model.wait()
        return "Recovered native turn"

    recovered._http_client = httpx.AsyncClient(transport=httpx.MockTransport(transport))
    recovered.set_message_handler(model)
    event = {"kind": "message.new", "seq": 9001, "chatId": "901", "meId": "999",
        "_inlineDeliveryId": "native-recovery", "message": {
            "id": "9001", "chatId": "901", "fromId": "46", "message": "recover native admission",
            "peerId": {"peer": {"oneofKind": "user", "user": {"userId": "46"}}},
        }}
    auth_env = {key: "" for key in (
        "INLINE_ALLOWED_USERS", "INLINE_ALLOW_ALL_USERS", "GATEWAY_ALLOWED_USERS", "GATEWAY_ALLOW_ALL_USERS",
    )}
    try:
        with patch.dict(os.environ, auth_env), patch("gateway.pairing._sync_allowlist_add"), patch("gateway.pairing._sync_allowlist_remove"):
            code = runner.pairing_store.generate_code("inline", "46", "Receipt recovery fixture")
            assert code is not None
            assert runner.pairing_store.approve_code("inline", code) is not None
            native_authorize = runner._is_user_authorized
            attempts = 0

            def transient_authorize(source):
                nonlocal attempts
                attempts += 1
                if attempts == 1:
                    raise RuntimeError("offline injected authorization outage")
                return native_authorize(source)

            with patch.object(runner, "_is_user_authorized", side_effect=transient_authorize), patch.object(module, "_INBOUND_RETRY_INITIAL_SECONDS", 0.001):
                await recovered._on_inbound(json.dumps(event))
                receipt = recovered._inbound_deliveries["native-recovery"]
                await asyncio.wait_for(receipt, timeout=10)
                await asyncio.wait_for(model_started.wait(), timeout=10)
            assert attempts == 2, "native unknown authorization was not retried"
            assert acknowledgements == ["native-recovery"]
            assert len(received) == 1 and received[0].source.user_id == "46"
            assert not release_model.is_set() and not replied.is_set(), "receipt waited for model completion"
            assert recovered._active_sessions, "real host did not retain the background turn"
            release_model.set()
            await asyncio.wait_for(replied.wait(), timeout=10)

        # Exercise the actual native shielded notification. Teardown cancels its
        # carrier delivery task, but the detached fatal handler must still finish.
        notified, teardown_finished = asyncio.Event(), asyncio.Event()

        async def fatal_handler(failed):
            assert failed is recovered
            notified.set()
            await failed.disconnect()
            await asyncio.sleep(0)
            teardown_finished.set()

        async def unexpected_failure(_event):
            raise RuntimeError("offline injected dispatch failure")

        recovered.set_fatal_error_handler(fatal_handler)
        with patch.object(recovered, "_dispatch_inbound", side_effect=unexpected_failure):
            await recovered._on_inbound(json.dumps({**event, "_inlineDeliveryId": "native-fatal"}))
            await asyncio.wait_for(notified.wait(), timeout=10)
            await asyncio.wait_for(teardown_finished.wait(), timeout=10)
        assert recovered.has_fatal_error and recovered.fatal_error_retryable
        assert recovered.fatal_error_code == "INBOUND_FAILED"
        assert acknowledgements == ["native-recovery"], "unexpected failure acknowledged its SDK receipt"
        assert not recovered._inbound_deliveries, "fatal teardown leaked delivery tasks"
    finally:
        release_model.set()
        await recovered.disconnect()


asyncio.run(exercise_receipt_recovery())


def exercise_profile_defaults():
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    fixtures = Path(tempfile.mkdtemp(prefix="inline-hermes-profile-defaults-"))
    profiles = []
    for name in ("a", "b"):
        profile_home = fixtures / name
        token = set_hermes_home_override(profile_home)
        try:
            profile = type(adapter)(PlatformConfig(enabled=True, token="offline-test-token", extra={"sync_commands": False}))
        finally:
            reset_hermes_home_override(token)
        assert profile._state_path == profile_home / "inline" / "sdk-state.json"
        assert profile._settings_path == profile_home / "inline" / "adapter-settings.json"
        assert profile._media_cache_dir == profile_home / "inline" / "media-cache"
        profiles.append(profile)
    profiles[0]._set_reply_threads_for_chat("101", "off")
    assert profiles[0]._reply_thread_mode_for_chat("101") == "off"
    assert profiles[1]._reply_thread_mode_for_chat("101") == "auto"
    assert profiles[0]._settings_path != profiles[1]._settings_path
    assert profiles[0]._settings_path.exists() and not profiles[1]._settings_path.exists()


exercise_profile_defaults()


async def exercise_thread_workflow():
    from gateway.session import build_session_key
    from gateway.platforms.base import _reply_anchor_for_event, _thread_metadata_for_event

    workflow = platform_registry.create_adapter("inline", PlatformConfig(
        enabled=True, token="offline-test-token", extra={
            "dm_policy": "allowlist", "allow_from": "42",
            "group_policy": "open", "group_allow_from": "42",
            "reply_threads": "off", "context_backfill": "off",
            "require_mention": False, "reactions": True,
            "sync_commands": False, "text_debounce_seconds": 0,
        },
    ))
    workflow._me_id = "999"
    workflow.set_authorization_check(lambda *_args, **_kwargs: True)
    received, sent = [], []
    state = {"parent_outage": False, "missing_peer": False, "reaction_child": False}
    parents = {"99": "10", "100": "10", "201": "20", "202": "20", "301": "201", "109": "99"}

    def transport(request):
        body = json.loads(request.content)
        if request.url.path == "/chat":
            chat = body["target"]["chatId"]
            if chat == "20" and state["parent_outage"]:
                state["parent_outage"] = False
                return httpx.Response(503, json={"ok": False, "error": {"kind": "transient", "message": "offline"}})
            result = {"chatId": chat, "title": "Offline fixture", "peer": {"type": {"oneofKind": "user" if chat == "20" else "chat"}}}
            if chat in parents:
                result.update(parentChatId=parents[chat], parentMessageId="7")
            if chat == "20" and state["missing_peer"]:
                result.pop("peer")
            return httpx.Response(200, json={"ok": True, "result": result})
        if request.url.path == "/messages":
            msg = {"id": body["messageIds"][0], "chatId": body["target"]["chatId"],
                   "fromId": "999", "message": "Fixture bot reply", "peerId": {"peer": {"oneofKind": "chat"}}}
            if state["reaction_child"]:
                msg["replies"] = {"chatId": "99"}
            return httpx.Response(200, json={"ok": True, "result": {"messages": [msg]}})
        if request.url.path in ("/send", "/send-attachment"):
            # The real sidecar accepts chat-scoped positive numeric IDs only.
            reply_id = body.get("replyToMsgId")
            assert reply_id is None or (reply_id.isdecimal() and int(reply_id) > 0), body
        sent.append((request.url.path, body))
        return httpx.Response(200, json={"ok": True, "result": {"messageId": "80"}})

    async def receive(event):
        received.append(event)

    def message(chat, seq, replies=None, user="42"):
        msg = {"id": str(seq), "chatId": chat, "fromId": user, "message": "Offline thread turn",
               "peerId": {"peer": {"oneofKind": "user" if chat == "20" else "chat"}}}
        if replies:
            msg["replies"] = {"chatId": replies}
        return {"kind": "message.new", "seq": seq, "chatId": chat, "message": msg}

    workflow._http_client = httpx.AsyncClient(transport=httpx.MockTransport(transport))
    workflow.handle_message = receive
    try:
        for chat, seq, child in [("10", 1, "99"), ("99", 2, None), ("10", 3, "100"),
                                 ("20", 4, "201"), ("201", 5, None), ("20", 6, "202"), ("20", 7, None)]:
            await workflow._dispatch_message(message(chat, seq, child))
        assert len(received) == 7
        keys = [build_session_key(event.source) for event in received]
        assert keys[0] == keys[1] and keys[0] != keys[2], keys
        assert keys[3] == keys[4] and len(set(keys[3:])) == 3, keys
        assert received[3].source.chat_type == received[4].source.chat_type == "dm"
        assert [e.metadata["inline"]["chat_id"] for e in received] == ["10", "99", "10", "20", "201", "20", "20"]
        # The opening turn and child follow-up use the same cached instructions,
        # while message actions receive the actual transport tuple per turn.
        for opening, followup in ((0, 1), (3, 4)):
            assert received[opening].channel_prompt == received[followup].channel_prompt
            assert "Triggering Inline message:" not in received[opening].channel_prompt
            assert "Current Inline sender" not in received[opening].channel_prompt
            assert "return NO_REPLY" in received[opening].channel_prompt
        assert "Triggering Inline message: `1` in chat `10`" in received[0].channel_context
        assert "Triggering Inline message: `2` in chat `99`" in received[1].channel_context
        assert "Triggering Inline message: `4` in chat `20`" in received[3].channel_context
        assert "Triggering Inline message: `5` in chat `201`" in received[4].channel_context
        for index, target in [(0, "10"), (1, "99"), (3, "20"), (4, "201")]:
            await workflow.on_processing_start(received[index])
            assert sent[-1][0] == "/reaction" and sent[-1][1]["target"] == {"chatId": target}, sent[-1]
        for index, target in [(0, "99"), (4, "201")]:
            event = received[index]
            assert (await workflow.send(event.source.chat_id, "Offline reply",
                                       reply_to=_reply_anchor_for_event(event), metadata=_thread_metadata_for_event(event))).success
            assert sent[-1][1]["target"] == {"chatId": target}, sent[-1]
            assert sent[-1][1].get("replyToMsgId") == (None if index == 0 else "5"), sent[-1]
        media = Path(tempfile.mkdtemp(prefix="inline-hermes-reply-media-")) / "photo.png"
        media.write_bytes(b"offline photo")
        for index, target in [(0, "99"), (4, "201")]:
            event = received[index]
            assert (await workflow.send_image_file(event.source.chat_id, str(media),
                reply_to=_reply_anchor_for_event(event), metadata=_thread_metadata_for_event(event))).success
            assert sent[-1][0] == "/send-attachment", sent[-1]
            assert sent[-1][1]["target"] == {"chatId": target}, sent[-1]
            assert sent[-1][1].get("replyToMsgId") == (None if index == 0 else "5"), sent[-1]

        equal = message("99", 901)
        equal["message"]["id"] = "7"
        await workflow._dispatch_message(equal)
        assert "[Inline parent message]" in received[-1].channel_context
        event = received[-1]
        assert (await workflow.send(event.source.chat_id, "Equal ID reply",
            reply_to=_reply_anchor_for_event(event), metadata=_thread_metadata_for_event(event))).success
        assert sent[-1][1]["replyToMsgId"] == "7", sent[-1]
        for chat, seq, child in (("99", 902, False), ("10", 903, True)):
            state["reaction_child"] = child
            await workflow._dispatch_reaction({"kind": "reaction.add", "seq": seq, "chatId": chat,
                "messageId": "80", "userId": "42", "emoji": "ok"}, added=True)
            event = received[-1]
            assert event.message_id.startswith("reaction.add:")
            assert (await workflow.send(event.source.chat_id, "Reaction reply",
                reply_to=_reply_anchor_for_event(event), metadata=_thread_metadata_for_event(event))).success
            assert sent[-1][1]["target"] == {"chatId": "99"}
            assert sent[-1][1].get("replyToMsgId") == (None if child else "80"), sent[-1]
        state["reaction_child"] = False
        workflow._system_events = True
        await workflow._dispatch_system_event({"kind": "message.delete", "seq": 904, "chatId": "99", "messageIds": ["80"]})
        event = received[-1]
        assert not _reply_anchor_for_event(event)
        assert (await workflow.send(event.source.chat_id, "System reply",
            reply_to=_reply_anchor_for_event(event), metadata=_thread_metadata_for_event(event))).success
        assert "replyToMsgId" not in sent[-1][1]
        for chat, index in (("99", 1), ("201", 4)):
            delivery_source = await workflow.resolve_delivery_source(chat, user_id="42")
            assert build_session_key(delivery_source) == keys[index]

        # Nested threads inherit root policy while retaining immediate edges.
        nested_start = len(received)
        for chat, seq, child in (("201", 610, "301"), ("301", 611, None), ("99", 612, "109"), ("109", 613, None)):
            await workflow._dispatch_message(message(chat, seq, child))
        nested = received[nested_start:]
        assert len(nested) == 4
        nested_keys = [build_session_key(event.source) for event in nested]
        assert nested_keys[0] == nested_keys[1] and nested_keys[2] == nested_keys[3], nested_keys
        assert [event.source.chat_type for event in nested] == ["dm", "dm", "group", "group"]
        assert nested[0].source.chat_id == nested[1].source.chat_id == "201"
        assert nested[0].source.parent_chat_id == nested[1].source.parent_chat_id == "201"
        assert nested[2].source.chat_id == nested[3].source.chat_id == "109"
        assert nested[0].channel_prompt == nested[1].channel_prompt
        count = len(received)
        await workflow._dispatch_message(message("301", 614, user="43"))
        assert len(received) == count, "DM grandchild replaced root DM policy with open group policy"
        assert not await workflow._action_allowed({"chatId": "301", "messageId": "80", "actorUserId": "43"})

        # Controls and reaction-triggered turns must share the DM policy/session.
        count = len(received)
        await workflow._dispatch_reaction({"kind": "reaction.add", "seq": 100, "chatId": "201",
                                           "messageId": "80", "userId": "42", "emoji": "👍"}, added=True)
        assert len(received) == count + 1
        assert build_session_key(received[-1].source) == keys[4]
        assert received[-1].channel_prompt == received[4].channel_prompt
        assert "Triggering Inline message: `80` in chat `201`" in received[-1].channel_context
        await workflow._dispatch_reaction({"kind": "reaction.add", "seq": 101, "chatId": "201",
                                           "messageId": "80", "userId": "43", "emoji": "👍"}, added=True)
        assert len(received) == count + 1, "DM restriction was replaced by open group policy"
        assert not await workflow._action_allowed({"chatId": "201", "messageId": "80", "actorUserId": "43"})
        workflow._system_events = True
        await workflow._dispatch_system_event({"kind": "chat.participant.add", "seq": 102, "chatId": "201", "userId": "42"})
        assert len(received) == count + 2
        assert build_session_key(received[-1].source) == keys[4]
        assert received[-1].channel_prompt == received[4].channel_prompt
        await workflow._dispatch_message(message("201", 103))
        assert len(received) == count + 3
        assert received[-1].channel_prompt == received[4].channel_prompt
        with patch.object(workflow, "_bot_settings_runner", return_value=None):
            settings = await workflow._bot_settings_context({"chatId": "201", "actorUserId": "42"})
            assert settings["access"] == "full", settings
            assert build_session_key(settings["source"]) == keys[4]
            assert settings["following"] is False, "DM child lost its native follow control"
            root_settings = await workflow._bot_settings_context({"chatId": "20", "actorUserId": "42"})
            assert root_settings["following"] is None, root_settings
            denied = await workflow._bot_settings_context({"chatId": "201", "actorUserId": "43"})
            assert denied["access"] == "guideOnly", denied

        for chat, seq, expected in (("201", 700, {"chatId": "201"}), ("20", 701, {"userId": "42"})):
            sent.clear()
            follow = message(chat, seq)
            follow["message"]["message"] = "/follow"
            await workflow._dispatch_message(follow)
            follow_requests = [body for path, body in sent if path == "/follow-mode"]
            assert len(follow_requests) == 1 and follow_requests[0]["target"] == expected, sent

        # A required parent dependency cannot consume dedup or acknowledge the turn.
        module = sys.modules[type(workflow).__module__]
        for chat, expected_key, base_seq in (("201", keys[4], 500), ("301", nested_keys[1], 510)):
            for offset, flag in enumerate(("parent_outage", "missing_peer")):
                state[flag] = True
                workflow._invalidate_chat_info("20")
                seq = base_seq + offset
                count = len(received)
                try:
                    await workflow._dispatch_message(message(chat, seq))
                except module.InlineInboundDeferred:
                    pass
                else:
                    raise AssertionError(f"{chat} {flag} was accepted or silently dropped")
                assert len(received) == count
                state[flag] = False
                await workflow._dispatch_message(message(chat, seq))
                assert len(received) == count + 1, "repaired ancestry could not replay the turn"
                assert build_session_key(received[-1].source) == expected_key
        parents["201"] = "301"
        workflow._invalidate_chat_info("201")
        count = len(received)
        try:
            await workflow._dispatch_message(message("301", 800))
        except module.InlineInboundDeferred:
            pass
        else:
            raise AssertionError("cyclic ancestry was accepted or silently dropped")
        assert len(received) == count
        parents["201"] = "20"
        await workflow._dispatch_message(message("301", 800))
        assert len(received) == count + 1 and build_session_key(received[-1].source) == nested_keys[1]
        for ancestor in range(400, 418):
            parents[str(ancestor)] = str(ancestor + 1) if ancestor < 417 else "20"
        count = len(received)
        try:
            await workflow._dispatch_message(message("400", 801))
        except module.InlineInboundDeferred:
            pass
        else:
            raise AssertionError("unbounded ancestry was accepted or silently dropped")
        assert len(received) == count
        parents["415"] = "20"
        await workflow._dispatch_message(message("400", 801))
        assert len(received) == count + 1 and received[-1].source.chat_type == "dm"
        assert received[-1].source.chat_id == "401" and received[-1].source.thread_id == "400"
        sent.clear()
        assert await workflow.create_handoff_thread("201", "Offline cron") is None
        assert not sent, "scheduled delivery created an automatic subthread"
    finally:
        await workflow._http_client.aclose()


def exercise_profile_upgrade():
    from hermes_constants import set_hermes_home_override, reset_hermes_home_override
    legacy = home / "inline"
    legacy.mkdir(parents=True, exist_ok=True)
    legacy_files = {legacy / "adapter-settings.json": b'{"version":1,"reply_threads":{"99":"on"}}\n',
                    legacy / "sdk-state.json": b'{"fixture":"legacy shared SDK"}\n'}
    for path, payload in legacy_files.items():
        path.write_bytes(payload)
    profiles = {p: home / "profiles" / p for p in ("upgrade-chief", "upgrade-scout")}
    paths = []
    for profile, profile_home in profiles.items():
        profile_home.mkdir(parents=True, exist_ok=True)
        token = set_hermes_home_override(str(profile_home))
        try:
            config = PlatformConfig(enabled=True, token="offline-test-token", extra={"reply_threads":"off", "sync_commands":False})
            # Reuse the class admitted above; the isolated fixture homes have no
            # plugin activation config and therefore no per-home registry entry.
            first = type(adapter)(config)
            assert first._state_path == profile_home / "inline" / "sdk-state.json"
            assert first._settings_path == profile_home / "inline" / "adapter-settings.json"
            assert first._media_cache_dir == profile_home / "inline" / "media-cache"
            assert first._reply_thread_mode_for_chat("99") == "off", "legacy overrides were silently shared"
            first._set_reply_threads_for_chat("99", "on" if profile == "upgrade-chief" else "off")
            first._state_path.write_text("{\"fixture\":\"profile SDK\"}\n")
            sdk_bytes = first._state_path.read_bytes()
            restarted = type(adapter)(config)
            assert restarted._reply_thread_mode_for_chat("99") == ("on" if profile == "upgrade-chief" else "off")
            assert restarted._state_path.read_bytes() == sdk_bytes
            paths.append((first._state_path, first._settings_path, first._media_cache_dir))
        finally:
            reset_hermes_home_override(token)
    assert all(a != b for a, b in zip(paths[0], paths[1]))
    assert all(path.read_bytes() == payload for path, payload in legacy_files.items())
    print("Named-profile upgrade/restart: legacy SDK and /threads settings preserved; named profiles start with configured defaults and own SDK/settings/media paths.")

exercise_profile_upgrade()

asyncio.run(exercise_thread_workflow())
print("Real Hermes admission, registration, authorization/pairing, receipt recovery, fatal teardown, local effects, inbound/reply delivery, deduplication and media safety passed (offline transport).")
