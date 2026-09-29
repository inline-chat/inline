"""Real Hermes host contract test; fake HTTP transport and deterministic reply handler.

No Hermes modules are stubbed. This is offline host integration, not live messaging
or an LLM-provider test. Run with an isolated HERMES_HOME containing the installed plugin.
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
        adapter_module = sys.modules[type(adapter).__module__]
        public_dns = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))]
        cache = Path(tempfile.mkdtemp(prefix="inline-hermes-media-"))
        with patch("socket.getaddrinfo", return_value=public_dns), patch("httpx.AsyncClient", side_effect=media_client), patch.object(adapter_module, "_MEDIA_CACHE_DIR", cache):
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
print("Real Hermes admission, registration, authorization/pairing, receipt recovery, fatal teardown, local effects, inbound/reply delivery, deduplication and media safety passed (offline transport).")
