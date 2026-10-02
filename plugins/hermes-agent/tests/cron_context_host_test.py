"""Cron delivery and ordinary continuation against the actual Hermes host."""

import asyncio
from pathlib import Path
import sys
import threading

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))

from inline.adapter import InlineAdapter, _target_registration_hooks
from cron import scheduler
from cron.scheduler_delivery import _deliver_result
from gateway.config import GatewayConfig, Platform, PlatformConfig
from gateway.platform_registry import PlatformEntry, platform_registry
from gateway.platforms.base import SendResult
from gateway.public_context import prepare_public_admission
from gateway.run import GatewayRunner
from gateway.run_intake import intake_metadata
from gateway.session import SessionStore


@pytest.fixture
def runtime(tmp_path, monkeypatch):
    # Host imports can hydrate profile environment after the runner's scrub.
    # Blank these inputs so credential precedence and startup fallback cannot
    # select a real or unrelated account over this fixture's explicit token.
    for name in ("INLINE_TOKEN", "INLINE_BOT_TOKEN", "INLINE_BASE_URL", "INLINE_ALLOW_ALL_USERS",
                 "INLINE_ALLOWED_USERS", "INLINE_GROUP_ALLOW_FROM", "INLINE_ALLOWED_CHATS"):
        monkeypatch.setenv(name, "")
    home = tmp_path / "hermes" / "profiles" / "scout"
    home.mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.delenv("HERMES_PROFILE", raising=False)
    monkeypatch.delenv("HERMES_PROFILE_NAME", raising=False)
    entry = PlatformEntry(
        name="inline", label="Inline", adapter_factory=InlineAdapter,
        check_fn=lambda: True, source="builtin", **_target_registration_hooks(),
    )
    monkeypatch.setitem(platform_registry._entries, "inline", entry)
    platform = Platform("inline")
    pconfig = PlatformConfig(enabled=True, token="10:fake", typing_indicator=False, extra={
        "sidecar_autostart": False, "require_mention": False, "reply_threads": "off",
        "allow_from": "20", "group_allow_from": "20", "reactions": False,
        "cron_continuable_surface": "in_channel",
    })
    config = GatewayConfig(platforms={platform: pconfig}, sessions_dir=home / "sessions",
                           group_sessions_per_user=False, multiplex_profiles=True)
    store = SessionStore(config.sessions_dir, config)
    adapter = InlineAdapter(pconfig, send_only=True)
    adapter.set_owner_profile("scout")
    adapter.set_session_store(store)
    adapter._running, adapter._me_id = True, "10"
    monkeypatch.setattr("gateway.config.load_gateway_config", lambda: config)
    monkeypatch.setattr(scheduler, "load_config", lambda: {"cron": {"wrap_response": False}})

    loop = asyncio.new_event_loop()
    ready = threading.Event()

    def serve():
        asyncio.set_event_loop(loop)
        loop.call_soon(ready.set)
        loop.run_forever()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    assert ready.wait(timeout=5)

    class Runtime:
        chats, messages, requests, sent = {}, {}, [], []

        def call(self, coroutine):
            return asyncio.run_coroutine_threadsafe(coroutine, loop).result(timeout=10)

    result = Runtime()
    result.adapter, result.store, result.loop, result.platform = adapter, store, loop, platform
    runner = GatewayRunner.__new__(GatewayRunner)
    runner.config, runner.session_store = config, store
    runner.adapters, runner._profile_adapters = {platform: adapter}, {}
    runner._primary_profile_name, runner._gateway_loop = "scout", loop
    adapter.gateway_runner = runner

    async def drain(session_key):
        await runner._drain_durable_intakes(adapter=adapter, session_key=session_key, unclaimed_only=True)

    adapter.set_durable_intake_handler(runner._make_durable_intake_handler(adapter),
                                      finish=runner._finish_durable_intake_handoff, drain=drain)
    result.runner = runner

    async def request(path, body):
        result.requests.append((path, body))
        if path == "/sender":
            assert str(body["userId"]) == "20", "Only the fixture's verified human has sender proof"
            return {"ok": True, "result": {"provenanceVerified": True,
                "profile": {"id": "20", "bot": False, "firstName": "Jack"}}}
        chat_id = str(body["target"]["chatId"])
        if path == "/chat":
            return {"ok": True, "result": result.chats[chat_id]}
        if path == "/history":
            return {"ok": True, "result": {"messages": list(result.messages.get(chat_id, []))}}
        if path == "/messages":
            ids = {str(mid) for mid in body["messageIds"]}
            return {"ok": True, "result": {"messages": [
                message for message in result.messages.get(chat_id, []) if str(message["id"]) in ids
            ]}}
        raise AssertionError(f"Unexpected transport request: {path}")

    async def send(path, body):
        assert path == "/send", "Same-chat cron must not create a task or reply thread"
        result.sent.append(body)
        chat_id = str(body["target"]["chatId"])
        message = {"id": "100", "chatId": chat_id, "fromId": "10", "message": body["text"]}
        result.messages.setdefault(chat_id, []).append(message)
        return SendResult(success=True, message_id="100")

    adapter._sidecar_call, adapter._send_sidecar = request, send
    yield result
    loop.call_soon_threadsafe(loop.stop)
    thread.join(timeout=5)
    loop.close()
    for db in store._db_handles.values():
        db.close()


@pytest.mark.parametrize("kind", ["group", "group_child", "dm_child"])
def test_cron_plain_followup_uses_same_public_chat_and_existing_session(runtime, kind):
    adapter, store = runtime.adapter, runtime.store
    physical = "42" if kind == "group" else "43"
    root_peer = {"type": {"oneofKind": "user" if kind == "dm_child" else "chat"}}
    child_peer = {"type": {"oneofKind": "chat"}}
    runtime.chats["42"] = {"id": "42", "title": "Workbench", "peer": root_peer}
    if kind != "group":
        runtime.chats["43"] = {"id": "43", "title": "Task", "peer": child_peer, "parentChatId": "42"}
    source = runtime.call(adapter.resolve_delivery_source(physical, user_id="20"))
    existing = store.get_or_create_session(source)
    db = store._db_for_key(existing.session_key)
    assert db is not None
    job = {"id": "scout-brief", "name": "Daily brief", "deliver": "origin", "attach_to_session": True,
           "origin": {"platform": "inline", "profile": "scout", "chat_id": source.chat_id,
                      "thread_id": source.thread_id, "chat_type": source.chat_type, "user_id": "20"}}
    error = _deliver_result(job, "Novel public cron brief: syzygy",
                            adapters={runtime.platform: adapter}, loop=runtime.loop)
    assert error is None
    assert len(runtime.sent) == 1 and runtime.sent[0]["target"] == {"chatId": physical}
    assert not db.get_messages(existing.session_id), "Cron must not clone or seed a private transcript"

    trigger = {"id": "101", "chatId": physical, "fromId": "20", "message": "Discuss the brief",
               "peerId": root_peer if kind == "group" else child_peer}
    runtime.messages.setdefault(physical, []).append(trigger)
    completed, errors, admitted = threading.Event(), [], []

    async def handle(event):
        try:
            followup = store.get_or_create_session(event.source)
            assert followup.session_id == existing.session_id
            assert (event.source.chat_id, event.source.thread_id, event.source.profile) == (
                source.chat_id, source.thread_id, "scout")
            batch = await prepare_public_admission(store, adapter, event, followup.session_id, followup.session_key)
            assert "Novel public cron brief: syzygy" in batch["content"]
            assert {ref["chat_id"] for ref in batch["refs"]} == {physical}
            assert {ref["message_id"] for ref in batch["refs"]} == {"100", "101"}
            db.append_message(followup.session_id, "user", event.text + "\n" + batch["content"],
                              display_metadata={"public_context": batch, **intake_metadata(event)})
            assert db.public_context_was_accepted(followup.session_id, batch)
            assert event._gateway_durable_adopted is True
            assert not db.gateway_intake_is_pending(event._gateway_intake_receipts)
            admitted.append(batch)
        except BaseException as exc:
            errors.append(exc)
        finally:
            completed.set()

    adapter.set_message_handler(handle)
    runtime.call(adapter._dispatch_message({"chatId": physical, "message": trigger, "seq": "101"}))
    assert completed.wait(timeout=10), "Plain follow-up did not reach the normal host handler"
    assert not errors, str(errors)
    assert len(admitted) == 1
    assert len(runtime.sent) == 1, "Continuation must not resend the cron output"
    assert any(path == "/messages" for path, _ in runtime.requests)


@pytest.mark.parametrize("unavailable", ["access", "wrong_profile"])
def test_unavailable_canonical_route_never_sends_or_falls_back(runtime, monkeypatch, unavailable):
    runtime.chats["42"] = {"id": "42", "peer": {"type": {"oneofKind": "chat"}}}
    if unavailable == "access":
        async def denied(path, body):
            raise PermissionError("Task chat is no longer accessible")
        runtime.adapter._sidecar_call = denied
    else:
        runtime.adapter.set_owner_profile("chief")
    def forbidden_fallback(*args, **kwargs):
        raise AssertionError("Unresolved canonical continuation must fail before standalone delivery")
    monkeypatch.setattr("cron.scheduler_delivery._standalone_send", forbidden_fallback)
    job = {"id": "scout-brief", "deliver": "origin", "attach_to_session": True,
           "origin": {"platform": "inline", "profile": "scout", "chat_id": "42", "user_id": "20"}}
    error = _deliver_result(job, "Brief must stay in Scout's task chat",
                            adapters={runtime.platform: runtime.adapter}, loop=runtime.loop)
    assert "canonical in-channel reply route unavailable" in error
    assert not runtime.sent


def test_legacy_host_does_not_advertise_public_continuation(runtime, monkeypatch):
    import hermes_state
    assert runtime.adapter.supports_inchannel_continuable
    monkeypatch.setattr(hermes_state, "SessionDB", type("LegacySessionDB", (), {}))
    assert not runtime.adapter.supports_inchannel_continuable
