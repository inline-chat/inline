"""Physical Inline input/restore checks against the matching real Hermes host."""
import asyncio
import copy
import json
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))
from gateway.config import PlatformConfig
from gateway.platforms.base import MessageType
from gateway.platform_registry import PlatformEntry, platform_registry
from gateway.session_context import clear_session_vars, set_session_vars
from gateway.session_identity import replace_source
from gateway.run_intake import DurableIntakeRefused
from inline.adapter import InlineAdapter, InlineAuthorUnavailable, InlineInboundDeferred, InlineSidecarError
from inline import tools as inline_tools
from inline import cli as inline_cli
from cron_context_host_test import runtime


def test_receiving_status_checks_actual_core_apis_without_starting_gateway_or_db(tmp_path, monkeypatch):
    from gateway.platforms.base import BasePlatformAdapter
    from hermes_state import SessionDB
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    assert inline_cli._receiving_capability_status() == {
        "supported": True, "requiredIntakeVersion": 1, "reason": "core_capability_available",
    }
    assert not (tmp_path / "state.db").exists()
    with monkeypatch.context() as missing:
        missing.setattr(BasePlatformAdapter, "durable_intake_version", 0)
        assert inline_cli._receiving_capability_status()["supported"] is False
    with monkeypatch.context() as missing:
        missing.setattr(SessionDB, "_consume_gateway_intake", None)
        assert inline_cli._receiving_capability_status()["supported"] is False
    assert not (tmp_path / "state.db").exists()


@pytest.fixture
def environment(tmp_path, monkeypatch):
    for name in ("INLINE_TOKEN", "INLINE_BOT_TOKEN", "INLINE_BASE_URL", "INLINE_ALLOW_ALL_USERS",
                 "INLINE_ALLOWED_USERS", "INLINE_GROUP_ALLOW_FROM", "INLINE_ALLOWED_CHATS"):
        monkeypatch.setenv(name, "")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    platform_registry.register(PlatformEntry(
        name="inline", label="Inline", adapter_factory=InlineAdapter, check_fn=lambda: True,
    ))
    adapter = InlineAdapter(PlatformConfig(token="10:fake", extra={
        "reply_threads": "off", "require_mention": False, "context_backfill": "off", "allow_all": True,
    }))
    adapter._me_id = "10"
    adapter._profile_home = str(tmp_path.resolve())
    adapter.set_authorization_check(lambda *args, **kwargs: True)
    trigger = {"id": "5", "chatId": "42", "fromId": "20", "date": "1700000000",
               "message": "Continue this task", "peerId": {"type": {"oneofKind": "chat"}},
               "sourceSnapshot": "original"}
    state = {"current": copy.deepcopy(trigger), "sender": {"id": "20", "firstName": "Alex", "bot": False},
             "calls": [], "acks": [], "deny": False, "handoffs": [], "agent": None,
             "sender_provenance": True, "sender_error": False}

    async def request(path, body):
        state["calls"].append((path, copy.deepcopy(body)))
        if path == "/chat":
            if state["deny"]:
                raise InlineSidecarError(path, 403, "No longer permitted", "forbidden")
            chat_id = body["target"]["chatId"]
            result = {"id": chat_id, "peer": {"type": {"oneofKind": "chat"}}}
            if chat_id == "43":
                result.update(parentChatId="42", parentMessageId="5")
            if state["agent"]:
                result["agentContext"] = {"botUserId": "10", "agentId": str(state["agent"]["id"])}
            return {"ok": True, "result": result}
        if path == "/messages":
            return {"ok": True, "result": {"messages": [] if state["current"] is None else [copy.deepcopy(state["current"])]}}
        if path == "/sender":
            if state["sender_error"]:
                raise TimeoutError("Current directory temporarily unavailable")
            return {"ok": True, "result": {"profile": copy.deepcopy(state["sender"]),
                                            "provenanceVerified": state["sender_provenance"]}}
        if path == "/get-agent":
            return {"ok": True, "result": {"agent": copy.deepcopy(state["agent"])}}
        if path == "/inbound/ack":
            state["acks"].append(body["deliveryId"])
            return {"ok": True}
        raise AssertionError(path)

    async def handoff(event):
        state["handoffs"].append(event)
        # The host boundary is deliberately absent in this capture. A mere
        # process-local acceptance must never advance the SDK cursor.
        event._gateway_accepted = True

    adapter._sidecar_call = request
    adapter.handle_message = handoff
    raw = {"kind": "message.new", "chatId": "42", "seq": "7", "meId": "10",
           "message": copy.deepcopy(trigger), "sender": copy.deepcopy(state["sender"]),
           "_inlineSenderProvenanceVerified": True, "_inlineDeliveryId": "delivery"}
    return adapter, raw, state


def freeze(adapter, raw):
    event = asyncio.run(adapter._dispatch_message(copy.deepcopy(raw), projection_only=True))
    assert event is not None
    event.channel_context = "private-provider-history-must-not-be-persisted"
    event.channel_prompt = "private-system-prompt-must-not-be-persisted"
    snapshot = adapter.serialize_durable_intake(event)
    assert snapshot is not None
    assert "private-provider" not in repr(snapshot) and "private-system" not in repr(snapshot)
    assert "_inlineDeliveryId" not in repr(snapshot) and "_gateway_" not in repr(snapshot)
    return snapshot


def test_restore_preserves_frozen_input_without_controls_topology_or_handoff(environment):
    adapter, raw, state = environment
    snapshot = freeze(adapter, raw)
    state["sender"]["firstName"] = "Renamed Alex"
    adapter._seen_messages["already-seen"] = 1
    seen = copy.deepcopy(adapter._seen_messages)
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert adapter.serialize_durable_intake(restored) == snapshot
    assert restored.source.user_name == "Renamed Alex"
    assert restored.source.author_kind_verified is True and restored.source.is_bot is False
    assert restored.allow_gateway_control is False
    assert adapter._seen_messages == seen and state["handoffs"] == []
    assert all(path not in {"/create-subthread", "/send", "/follow-mode"} for path, _ in state["calls"])
    raw["message"]["message"] = "/reset"
    control = asyncio.run(adapter._dispatch_message(raw, projection_only=True))
    assert control is None


def test_task_default_uses_current_verified_human_not_cron_env_or_generic_source(environment, monkeypatch):
    adapter, raw, state = environment
    source = asyncio.run(adapter._dispatch_message(raw, projection_only=True)).source
    monkeypatch.setenv("HERMES_SESSION_PLATFORM", "inline")
    monkeypatch.setenv("HERMES_SESSION_USER_ID", "20")
    monkeypatch.setenv("HERMES_SESSION_CHAT_ID", "42")
    tokens = set_session_vars(platform="inline", user_id="20", chat_id="42", current_turn_source=source)
    try:
        path, body = inline_tools._request_for_action("create_chat", {"title": "My task"})
        assert path == "/create-chat" and body["initiatingUserId"] == "20" and body["initiatingChatId"] == "42"
    finally:
        clear_session_vars(tokens)
    for current in (None, replace_source(source, user_id="21"), replace_source(source, is_bot=True)):
        tokens = set_session_vars(platform="inline", user_id="20", chat_id="42", current_turn_source=current)
        try:
            with pytest.raises(inline_tools.InlineToolError, match="no current Inline person"):
                inline_tools._request_for_action("create_chat", {"title": "Cron or delegated task"})
            _, body = inline_tools._request_for_action("create_chat", {"title": "Explicit worker task", "participant_user_ids": []})
            assert body["participantUserIds"] == [] and "initiatingUserId" not in body
        finally:
            clear_session_vars(tokens)


@pytest.mark.parametrize("change", ["deleted", "edited", "same_text_edit", "snapshot", "rich_card", "carried", "receiver", "api", "profile", "access", "native_auth", "recipient"])
def test_restart_refuses_changed_source_recipient_and_authority(environment, change):
    adapter, raw, state = environment
    snapshot = freeze(adapter, raw)
    if change == "deleted":
        state["current"] = None
    elif change == "edited":
        state["current"]["message"] = "New instruction"
    elif change == "same_text_edit":
        state["current"]["editDate"] = "1700000001"
    elif change == "snapshot":
        state["current"]["sourceSnapshot"] = "unexplained-new-version"
    elif change == "rich_card":
        state["current"]["attachments"] = [{"externalTask": {"title": "Edited public card"}}]
    elif change == "carried":
        state["current"]["isForwarded"] = True
    elif change == "receiver":
        adapter._me_id = "11"
    elif change == "api":
        adapter._base_url = "https://another.inline.invalid"
    elif change == "profile":
        adapter._profile_home += "/another-profile"
    elif change == "access":
        state["deny"] = True
    elif change == "native_auth":
        adapter.set_authorization_check(lambda *args, **kwargs: False)
    elif change == "recipient":
        adapter.require_mention = True
    with pytest.raises(DurableIntakeRefused):
        asyncio.run(adapter.restore_durable_intake(snapshot))
    assert state["handoffs"] == [] and state["acks"] == []


def test_restore_reloads_current_agent_instructions_and_refuses_a_new_agent(environment):
    adapter, raw, state = environment
    state["agent"] = {"id": 73, "bot_user_id": 10, "name": "Worker", "instructions": "Original instructions"}
    snapshot = freeze(adapter, raw)
    assert snapshot["event"]["selected_agent_id"] == "73"
    state["agent"]["instructions"] = "Current instructions"
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert "Current instructions" in restored.channel_context
    assert "Original instructions" not in restored.channel_context
    assert adapter.serialize_durable_intake(restored) == snapshot
    state["agent"]["id"] = 74
    with pytest.raises(DurableIntakeRefused, match="selected Agent"):
        asyncio.run(adapter.restore_durable_intake(snapshot))


def test_media_url_refresh_does_not_rewrite_the_immutable_receipt(environment):
    adapter, raw, state = environment
    raw["message"]["media"] = {"media": {"oneofKind": "photo", "photo": {"id": "700", "cdnUrl": "original-url"}}}
    state["current"]["media"] = copy.deepcopy(raw["message"]["media"])
    async def media(message):
        return "", [message["media"]["media"]["photo"]["cdnUrl"]], ["image/png"], MessageType.PHOTO
    adapter._normalize_media = media
    snapshot = freeze(adapter, raw)
    state["current"]["media"]["media"]["photo"]["cdnUrl"] = "fresh-url"
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert restored.media_urls == ["fresh-url"]
    assert adapter.serialize_durable_intake(restored) == snapshot


def test_reply_thread_topology_enrichment_preserves_the_starter_receipt(environment):
    adapter, raw, state = environment
    event = asyncio.run(adapter._dispatch_message(raw, projection_only=True, restore_route={
        "thread_id": "43", "parent_chat_id": "42",
    }))
    snapshot = adapter.serialize_durable_intake(event)
    state["current"].update(sourceSnapshot="thread-enriched", replies={"chatId": "43"})
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert restored.source.chat_id == "43" and restored.source.thread_id == "43"
    assert adapter.serialize_durable_intake(restored) == snapshot


def test_process_local_acceptance_never_acknowledges_transport(environment):
    adapter, raw, state = environment
    with pytest.raises(RuntimeError, match="did not durably adopt"):
        asyncio.run(adapter._handle_inbound_delivery("delivery", raw))
    assert len(state["handoffs"]) == 1 and state["acks"] == []
    assert adapter._seen_messages == {}
    with pytest.raises(RuntimeError, match="receiver"):
        asyncio.run(adapter._dispatch_inbound({**raw, "meId": "11"}))
    assert adapter._me_id == "10" and len(state["handoffs"]) == 1


def test_action_receipt_has_its_own_identity_and_private_callback_scope(environment):
    adapter, raw, state = environment
    state["current"].update(fromId="10", actions={"rows": [{"actions": [
        {"id": "agent:1:1", "text": "Continue", "callbackData": "original-private-data"},
    ]}]})
    action = {"kind": "message.action.invoke", "chatId": "42", "messageId": "5", "actorUserId": "20",
              "interactionId": "71", "actionId": "agent:1:1", "dataBase64": "b3BhcXVl", "seq": "8"}
    synthetic = {**raw, "_inlineAgentAction": action, "_inlineReferenceTarget": copy.deepcopy(state["current"])}
    synthetic["message"].update(message="An explicit button instruction", mentioned=True)
    snapshot = freeze(adapter, synthetic)
    assert snapshot["physical_message_id"] == "action:71"
    assert "b3BhcXVl" in repr(snapshot) and "original-private-data" not in repr(snapshot)
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert adapter.serialize_durable_intake(restored) == snapshot
    state["current"]["actions"]["rows"][0]["actions"][0]["callbackData"] = "changed-private-data"
    with pytest.raises(DurableIntakeRefused, match="buttons changed"):
        asyncio.run(adapter.restore_durable_intake(snapshot))


def test_reaction_receipt_uses_update_identity_and_rechecks_its_real_reference(environment):
    adapter, raw, state = environment
    state["current"]["fromId"] = "10"
    reaction = {"kind": "reaction.add", "chatId": "42", "messageId": "5", "userId": "20",
                "emoji": "👍", "seq": "9", "sender": copy.deepcopy(state["sender"])}
    event = asyncio.run(adapter._dispatch_reaction(reaction, added=True, projection_only=True))
    snapshot = adapter.serialize_durable_intake(event)
    assert snapshot["physical_message_id"] == "reaction:9"
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert adapter.serialize_durable_intake(restored) == snapshot
    assert adapter._seen_messages == {} and state["handoffs"] == []
    state["current"] = None
    with pytest.raises(DurableIntakeRefused, match="deleted"):
        asyncio.run(adapter.restore_durable_intake(snapshot))


@pytest.mark.parametrize("failure", ["missing_kind", "wrong_id", "missing_profile", "unverified", "timeout"])
def test_explicit_mentions_and_restart_retain_unknown_author_kind(environment, failure):
    adapter, raw, state = environment
    snapshot = freeze(adapter, raw)
    raw["_inlineSenderProvenanceVerified"] = False
    raw["sender"] = {"id": "20"}
    raw["message"]["entities"] = {"entities": [{"type": 4, "entity": {"oneofKind": "mention", "mention": {"userId": "10"}}}]}
    assert adapter._message_entity_mentions_me(raw["message"])
    if failure == "missing_kind":
        state["sender"].pop("bot")
    elif failure == "wrong_id":
        state["sender"]["id"] = "21"
    elif failure == "missing_profile":
        state["sender"] = None
    elif failure == "unverified":
        state["sender_provenance"] = False
    else:
        state["sender_error"] = True
    with pytest.raises(InlineInboundDeferred):
        asyncio.run(adapter._dispatch_message(raw, projection_only=True))
    with pytest.raises((InlineInboundDeferred, TimeoutError)):
        asyncio.run(adapter.restore_durable_intake(snapshot))
    assert state["acks"] == [] and state["handoffs"] == [] and adapter._seen_messages == {}
    state.update(sender={"id": "20", "firstName": "Alex", "bot": False},
                 sender_provenance=True, sender_error=False)
    event = asyncio.run(adapter._dispatch_message(raw, projection_only=True))
    assert event.source.author_kind_verified is True and event.source.is_bot is False
    assert asyncio.run(adapter.restore_durable_intake(snapshot)).source.author_kind_verified is True


def test_verified_bot_kind_cannot_use_human_mention_or_reaction_policy(environment):
    adapter, raw, state = environment
    state["sender"]["bot"] = True
    raw["sender"] = {"id": "20"}
    raw["_inlineSenderProvenanceVerified"] = False
    raw["message"]["entities"] = {"entities": [{"type": 4, "entity": {"oneofKind": "mention", "mention": {"userId": "10"}}}]}
    decisions = []
    def authorize(*args, **kwargs):
        decisions.append(kwargs.get("is_bot", False))
        return kwargs.get("is_bot", False) is not True
    adapter.set_authorization_check(authorize)
    assert asyncio.run(adapter._dispatch_message(raw, projection_only=True)) is None
    state["current"]["fromId"] = "10"
    reaction = {"kind": "reaction.add", "chatId": "42", "messageId": "5", "userId": "20",
                "emoji": "👍", "seq": "9"}
    assert asyncio.run(adapter._dispatch_reaction(reaction, added=True, projection_only=True)) is None
    assert True in decisions and state["handoffs"] == [] and state["acks"] == []


def test_action_author_lookup_keeps_receipt_beyond_the_old_retirement_limit(environment, monkeypatch):
    adapter, raw, state = environment
    attempts = []
    async def dispatch(event):
        attempts.append(event)
        if len(attempts) < 4:
            raise InlineAuthorUnavailable("Directory recovering")
    async def retry_wait(delay):
        assert state["acks"] == []
    adapter._dispatch_inbound = dispatch
    monkeypatch.setattr(asyncio, "sleep", retry_wait)
    action = {"kind": "message.action.invoke", "interactionId": "71"}
    asyncio.run(adapter._handle_inbound_delivery("action-delivery", action))
    assert len(attempts) == 4 and state["acks"] == ["action-delivery"]


@pytest.mark.parametrize("physical_text", ["Continue this task", "/plan Continue this task"])
def test_exact_admitted_text_survives_hook_or_llm_command_resolution(environment, physical_text):
    adapter, raw, state = environment
    raw["message"]["message"] = state["current"]["message"] = physical_text
    event = asyncio.run(adapter._dispatch_message(raw, projection_only=True, restore_route={}))
    event.text = "Exact authorized hook or command output\nwith intentional whitespace  "
    event.allow_gateway_control = False
    snapshot = adapter.serialize_durable_intake(event)
    restored = asyncio.run(adapter.restore_durable_intake(snapshot))
    assert restored.text == event.text and restored.allow_gateway_control is False
    assert adapter.serialize_durable_intake(restored) == snapshot
    assert state["handoffs"] == [] and not any(path == "/send" for path, _ in state["calls"])
    event.source.author_kind_verified = False
    with pytest.raises(InlineAuthorUnavailable):
        adapter.serialize_durable_intake(event)


def normalized_delivery(message, seq):
    """Run the production TS sender-resolution/normalization path, not a raw fixture."""
    bun = shutil.which("bun") or str(Path.home() / ".bun" / "bin" / "bun")
    source = """
      import { deliverInboundEvent } from './src/sidecar/inbound-delivery.ts';
      const message = JSON.parse(await Bun.stdin.text());
      await deliverInboundEvent({kind:'message.new',chatId:'42',seq:""" + str(seq) + """,message}, {
        meId:'10', meUsername:'worker', signal:new AbortController().signal,
        resolveSender:async()=>({profile:{id:'20',firstName:'Jack',bot:false},provenanceVerified:true}),
        deliver:async event=>process.stdout.write(JSON.stringify(event)),
      });
    """
    result = subprocess.run([bun, "-e", source], cwd=Path(__file__).resolve().parents[1],
                            input=json.dumps(message), text=True, capture_output=True, check=True)
    event = json.loads(result.stdout)
    event["_inlineDeliveryId"] = "normalized-" + str(seq)
    return event


def test_normalized_forwarded_mentions_never_adopt_or_control_but_live_rich_input_does(runtime):
    from gateway.public_context import prepare_public_admission
    from gateway.run_intake import intake_metadata

    adapter, store = runtime.adapter, runtime.store
    runtime.chats["42"] = {"id": "42", "title": "Workbench", "peer": {"type": {"oneofKind": "chat"}}}
    original_request, acknowledgements = adapter._sidecar_call, []
    async def request(path, body):
        if path == "/inbound/ack":
            acknowledgements.append(body["deliveryId"])
            return {"ok": True}
        return await original_request(path, body)
    adapter._sidecar_call = request
    source = runtime.call(adapter.resolve_delivery_source("42", user_id="20"))
    session = store.get_or_create_session(source)
    db = store._db_for_key(session.session_key)
    complete, errors, admitted = threading.Event(), [], []
    async def handle(event):
        try:
            assert event.source.author_kind_verified is True and event.source.is_bot is False
            batch = await prepare_public_admission(store, adapter, event, session.session_id, session.session_key)
            snapshot = adapter.serialize_durable_intake(event)
            admitted.append(snapshot)
            db.append_message(session.session_id, "user", event.text + "\n" + batch["content"],
                              display_metadata={"public_context": batch, **intake_metadata(event)})
            assert db.gateway_intake_was_consumed(session.session_id, event._gateway_intake_receipts)
        except BaseException as exc:
            errors.append(exc)
        finally:
            complete.set()
    adapter.set_message_handler(handle)
    mention = {"entities": [{"type": 4, "entity": {"oneofKind": "mention", "mention": {"userId": "10"}}}]}
    for mid, text in ((5, "@worker old delegation"), (6, "/reset")):
        carried = {"id": str(mid), "chatId": "42", "fromId": "20", "message": text,
                   "peerId": {"type": {"oneofKind": "chat"}}, "mentioned": True,
                   "entities": mention, "isForwarded": True, "sourceSnapshot": "carried-" + str(mid)}
        runtime.messages["42"] = [carried]
        normalized = normalized_delivery(carried, mid)
        assert normalized["message"]["isForwarded"] is True
        runtime.call(adapter._handle_inbound_delivery(normalized["_inlineDeliveryId"], normalized))
    assert admitted == [] and not complete.is_set() and not db.get_messages(session.session_id)
    assert not db.pending_gateway_intakes() and acknowledgements == ["normalized-5", "normalized-6"]
    live = {"id": "7", "chatId": "42", "fromId": "20", "message": "Continue the current task",
            "peerId": {"type": {"oneofKind": "chat"}}, "sourceSnapshot": "current-rich",
            "editDate": "1700000001", "blockContent": {"blocks": [{"text": "Public detail"}]},
            "subthread": {"chatId": "43"}, "attachments": [{"externalTask": {"title": "Current task"}}],
            "media": {"media": {"oneofKind": "document", "document": {"id": "700", "cdnUrl": "https://example.invalid/public"}}}}
    media = []
    async def normalize_media(message):
        media.append(copy.deepcopy(message["media"]))
        return "", [], [], MessageType.TEXT
    adapter._normalize_media = normalize_media
    runtime.messages["42"].append(live)
    normalized = normalized_delivery(live, 7)
    assert normalized["_inlineSenderProvenanceVerified"] is True
    runtime.call(adapter._handle_inbound_delivery(normalized["_inlineDeliveryId"], normalized))
    assert complete.wait(timeout=10) and not errors, str(errors)
    async def finish_handoff():
        await asyncio.gather(*tuple(adapter._background_tasks))
    runtime.call(finish_handoff())
    assert len(admitted) == 1 and media == [live["media"]]
    saved = admitted[0]["event"]["raw"]["message"]
    for field in ("sourceSnapshot", "editDate", "blockContent", "subthread", "attachments", "media"):
        assert saved[field] == live[field]
    assert not db.pending_gateway_intakes() and len(db.get_messages(session.session_id)) == 1
