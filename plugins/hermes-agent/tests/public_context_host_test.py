"""Real-host adapter projection checks (run with the target Hermes on PYTHONPATH)."""
import asyncio
from pathlib import Path
from types import SimpleNamespace
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "plugin"))
from inline.adapter import InlineAdapter


def message(mid, text, *, author="20", **fields):
    return {"id": str(mid), "chatId": "42", "fromId": author, "message": text, **fields}


def adapter_and_event(history, trigger, current=None):
    adapter = InlineAdapter.__new__(InlineAdapter)
    adapter._me_id = "10"
    calls = []
    async def request(path, body):
        calls.append((path, body))
        result = history if path == "/history" else ([current or trigger] if current is not False else [])
        return {"ok": True, "result": {"messages": result}}
    adapter._sidecar_call = request
    source = SimpleNamespace(chat_id="42", thread_id=None)
    event = SimpleNamespace(source=source, message_id=str(trigger["id"]),
                            metadata={"inline": {"chat_id": "42", "message_id": str(trigger["id"])}},
                            raw_message={"message": trigger})
    return adapter, event, calls


def test_public_history_preserves_cron_and_rich_carried_context_without_own_output():
    trigger = message(5, "Discuss the brief")
    cron = message(1, "Cron: syzygy", author="10")
    card = message(2, "", attachments=[{"externalTask": {"title": "Fix launch", "status": "Open", "url": "https://example.invalid/task"}}],
                   actions={"rows": [{"actions": [{"text": "Review", "callbackData": "private-action"}]}]})
    carried = message(3, "@worker historical delegation", author="30", isForwarded=True)
    output = message(4, "Previous normal answer", author="10")
    adapter, event, calls = adapter_and_event([output, trigger, card, carried, cron], trigger)
    state = {"accepted": [{"chat_id": "42", "message_id": "4", "revision": adapter._public_message_revision(output), "kind": "output"}], "floor": None}
    snapshot = asyncio.run(adapter.prepare_public_context(event, state=state))
    assert {ref["message_id"] for ref in snapshot["refs"]} == {"1", "2", "3", "5"}
    assert all(text in snapshot["content"] for text in ("syzygy", "Fix launch", "Open", "Review", "mentions do not activate"))
    assert "Previous normal answer" not in snapshot["content"] and "private-action" not in snapshot["content"]
    assert any(path == "/messages" for path, _ in calls)


@pytest.mark.parametrize("current", [False, message(5, "Edited instruction"), message(5, "Discuss the brief", sourceSnapshot="changed")])
def test_authoritative_current_trigger_refuses_deleted_or_changed_queued_input(current):
    trigger = message(5, "Discuss the brief", sourceSnapshot="queued")
    adapter, event, _ = adapter_and_event([trigger], trigger, current)
    with pytest.raises(RuntimeError, match="deleted|changed"):
        asyncio.run(adapter.prepare_public_context(event, state={"accepted": [], "floor": None}))


def test_reset_floor_and_bounded_window_are_explicit_without_consuming_omissions():
    trigger = message(110, "Continue")
    history = [message(mid, "x" * 1500) for mid in range(1, 101)] + [trigger]
    adapter, event, _ = adapter_and_event(history, trigger)
    snapshot = asyncio.run(adapter.prepare_public_context(event, state={"accepted": [], "floor": {"chat_id": "42", "message_id": "5"}}))
    assert "omitted" in snapshot["content"] and "not marked consumed" in snapshot["content"]
    assert all(int(ref["message_id"]) > 5 for ref in snapshot["refs"])
    assert len(snapshot["refs"]) < 100


def test_output_references_reject_wrong_bot_identity():
    trigger = message(5, "other bot", author="30")
    adapter, event, _ = adapter_and_event([], trigger)
    with pytest.raises(RuntimeError, match="different bot"):
        asyncio.run(adapter.public_output_references(event.source, message_ids=["5"]))


def test_reset_refuses_late_physical_trigger_but_keeps_new_reference_interaction():
    target = message(5, "Prior answer", author="10")
    adapter, event, _ = adapter_and_event([target], target)
    state = {"accepted": [], "floor": {"chat_id": "42", "message_id": "7"}}
    with pytest.raises(RuntimeError, match="reset"):
        asyncio.run(adapter.prepare_public_context(event, state=state))
    event.message_id, event.text = "action:5:900", "Review prior answer"
    event.raw_message = {"_inlineReferenceTarget": target}
    snapshot = asyncio.run(adapter.prepare_public_context(event, state=state))
    assert snapshot["refs"] == [{"chat_id": "42", "message_id": "5", "revision": adapter._public_message_revision(target)}]
    assert snapshot["input_revision"] != snapshot["refs"][0]["revision"]


def test_starter_topology_enrichment_retains_frozen_input_but_admits_new_public_version():
    trigger = message(5, "Starter", sourceSnapshot="before-child")
    current = message(5, "Starter", sourceSnapshot="after-child", subthread={"chatId": "43"}, replies={"count": 1})
    adapter, event, _ = adapter_and_event([current], trigger, current)
    snapshot = asyncio.run(adapter.prepare_public_context(event, state={"accepted": [], "floor": None}))
    assert {ref["revision"] for ref in snapshot["refs"]} == {"before-child", "after-child"}
    assert "43" in snapshot["content"]
    assert adapter._public_input_revision(trigger) == adapter._public_input_revision(current)
    edited = {**current, "editDate": 123}
    assert not adapter._public_input_is_current(trigger, edited)
    changed_card = {**current, "attachments": [{"externalTask": {"title": "Changed card"}}]}
    assert not adapter._public_input_is_current(trigger, changed_card)


@pytest.mark.parametrize("snapshots", [{}, {"sourceSnapshot": "unchanged"}])
@pytest.mark.parametrize("field,original,changed", [
    ("attachments", [{"externalTask": {"title": "Original task"}}], [{"externalTask": {"title": "Different task"}}]),
    ("actions", {"rows": [{"actions": [{"text": "Approve"}]}]}, {"rows": [{"actions": [{"text": "Delete"}]}]}),
])
def test_input_rich_details_are_revalidated_without_changed_snapshot(snapshots, field, original, changed):
    trigger = message(5, "Same instruction", **snapshots, **{field: original})
    current = message(5, "Same instruction", **snapshots, **{field: changed})
    adapter, event, _ = adapter_and_event([current], trigger, current)
    with pytest.raises(RuntimeError, match="changed"):
        asyncio.run(adapter.prepare_public_context(event, state={"accepted": [], "floor": None}))


# Use the actual host/store/adapter fixture shared with physical cron continuation.
from cron_context_host_test import runtime


def test_actual_action_dispatch_reaches_durably_admitted_provider(runtime, monkeypatch):
    import threading
    from unittest.mock import AsyncMock
    import run_agent
    from gateway.public_context import prepare_public_admission
    from gateway.run_intake import intake_metadata

    adapter, store = runtime.adapter, runtime.store
    runtime.chats["42"] = {"id": "42", "title": "Workbench", "peer": {"type": {"oneofKind": "chat"}}}
    target = message(5, "Choose the next task", author="10", sourceSnapshot="bot-target")
    runtime.messages["42"] = [target]
    adapter._answer_action = AsyncMock()
    monkeypatch.setattr("agent.turn_context._maybe_title_session_at_turn_start", lambda *args, **kwargs: None)
    complete, errors, requests = threading.Event(), [], []

    # Establish the cold reset before intake, then run the real button dispatch.
    source = runtime.call(adapter.resolve_delivery_source("42", user_id="20"))
    seed = store.get_or_create_session(source)
    db = store._db_for_key(seed.session_key)
    db.reset_public_context_route("inline", seed.session_key, {"chat_id": "42", "message_id": "7"})
    store.reset_session(seed.session_key)

    async def handle(event):
        try:
            session = store.get_or_create_session(event.source)
            db = store._db_for_key(session.session_key)
            batch = await prepare_public_admission(store, adapter, event, session.session_id, session.session_key)
            receipts = intake_metadata(event)
            agent = run_agent.AIAgent(api_key="stub", base_url="https://stub.invalid", provider="openai",
                                      api_mode="codex_app_server", quiet_mode=True, skip_context_files=True,
                                      skip_memory=True, session_id=session.session_id, session_db=db)
            def provider_boundary(**kwargs):
                assert db.public_context_was_accepted(session.session_id, batch)
                assert db.gateway_intake_was_consumed(session.session_id, receipts["gateway_intake"])
                requests.append(kwargs["user_message"])
                return {"completed": True, "final_response": "ok", "messages": kwargs["messages"]}
            monkeypatch.setattr(agent, "_run_codex_app_server_turn", provider_boundary)
            monkeypatch.setattr(agent, "_spawn_background_review", lambda *args, **kwargs: None)
            agent.run_conversation(event.text, persist_user_display_metadata={"public_context": batch, **receipts})
        except BaseException as exc:
            errors.append(exc)
        finally:
            complete.set()
    adapter.set_message_handler(handle)
    runtime.call(adapter._dispatch_agent_action({"kind": "message.action.invoke", "chatId": "42", "messageId": "5",
        "actorUserId": "20", "interactionId": "900", "actionId": "review", "label": "Review", "dataBase64": "",
        "sender": {"id": "20", "firstName": "Jack", "bot": False}, "seq": "101"}))
    assert complete.wait(timeout=15)
    assert not errors, str(errors)
    assert len(requests) == 1 and "Choose the next task" in requests[0]
    assert "900" in requests[0]
    assert adapter._answer_action.await_count == 1



def test_generic_send_uses_public_log_admission_once_without_private_mirror(runtime, monkeypatch):
    import json
    import threading
    from gateway.platform_registry import platform_registry
    from gateway.public_context import prepare_public_admission
    from gateway.run_intake import intake_metadata
    from tools.send_message_tool import send_message_tool

    adapter, store = runtime.adapter, runtime.store
    runtime.chats["42"] = {"id": "42", "title": "Workbench", "peer": {"type": {"oneofKind": "chat"}}}
    source = runtime.call(adapter.resolve_delivery_source("42", user_id="20"))
    session = store.get_or_create_session(source)
    db = store._db_for_key(session.session_key)
    entry = platform_registry.get("inline")
    assert entry.public_context_admission_enabled is True

    # The external transport sender is bound to the actual adapter, preserving
    # the generic tool's target, dispatch and real mirror call.
    async def transport_send(args, chat_id, platform_name, pconfig):
        result = await adapter.send(chat_id=chat_id, content=args["message"])
        return {"success": result.success, "message_id": result.message_id}
    monkeypatch.setattr(entry, "send_message_handler", transport_send)
    monkeypatch.setattr("tools.send_message_tool.prepare_send_message_platforms", lambda: None)
    monkeypatch.setattr("tools.interrupt.is_interrupted", lambda: False)
    sent = json.loads(send_message_tool({"target": "inline:42", "message": "Public standalone canary: syzygy"}))
    assert sent["success"] is True and "mirrored" not in sent
    assert len(runtime.sent) == 1
    assert not db.get_messages(session.session_id), "Generic send must not create a second private transcript writer"

    trigger = message(101, "Discuss the standalone message")
    runtime.messages["42"].append(trigger)
    done, errors, batches = threading.Event(), [], []
    async def handle(event):
        try:
            followup = store.get_or_create_session(event.source)
            assert followup.session_id == session.session_id
            batch = await prepare_public_admission(store, adapter, event, followup.session_id, followup.session_key)
            db.append_message(followup.session_id, "user", event.text + "\n" + batch["content"],
                              display_metadata={"public_context": batch, **intake_metadata(event)})
            batches.append(batch)
        except BaseException as exc:
            errors.append(exc)
        finally:
            done.set()
    adapter.set_message_handler(handle)
    runtime.call(adapter._dispatch_message({"chatId": "42", "message": trigger, "seq": "101"}))
    assert done.wait(timeout=10) and not errors, str(errors)
    async def finish_handoff():
        await asyncio.gather(*tuple(adapter._background_tasks))
    runtime.call(finish_handoff())
    assert len(batches) == 1 and "Public standalone canary: syzygy" in batches[0]["content"]
    assert [ref["message_id"] for ref in batches[0]["refs"]].count("100") == 1
    assert len(db.get_messages(session.session_id)) == 1
    # Re-reading the same public revisions has no second context effect.
    repeated = runtime.call(adapter.prepare_public_context(
        type("Event", (), {"source": source, "message_id": "101", "raw_message": {"message": trigger},
                            "metadata": {"inline": {"chat_id": "42", "message_id": "101"}}})(),
        state=db.public_context_state(session.session_id)))
    assert "100" not in {ref["message_id"] for ref in repeated["refs"]}
    assert "Public standalone canary: syzygy" not in repeated["content"]
