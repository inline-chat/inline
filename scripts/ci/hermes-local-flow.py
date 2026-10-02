"""Real Hermes -> bundled Node sidecar -> local Inline server round trip.

Hermes owns dispatch and reply delivery; only the LLM handler is deterministic.
No transport or Hermes modules are mocked. Tokens are inherited, never printed.
"""
import asyncio
import os
import socket
from pathlib import Path

from gateway.config import PlatformConfig
from gateway.platform_registry import platform_registry
from hermes_cli.plugins import get_plugin_manager


def matching_intake_runner(adapter):
    """Use real native adoption/FIFO and a physical isolated profile StateDB."""
    from gateway.config import GatewayConfig
    from gateway.platforms.base import BasePlatformAdapter
    from gateway.run import GatewayRunner
    from gateway.session import SessionStore
    from hermes_state import SessionDB
    assert getattr(BasePlatformAdapter, "durable_intake_version", None) == 1, (
        "Candidate receiving requires the matching Hermes durable-intake core; stock-host send-only compatibility is a separate gate"
    )
    assert callable(getattr(SessionDB, "adopt_gateway_intake", None))
    home = Path(os.environ["HERMES_HOME"]).resolve()
    runner = object.__new__(GatewayRunner)
    runner.config = GatewayConfig(platforms={adapter.platform: adapter.config},
                                  sessions_dir=home / "sessions", group_sessions_per_user=False)
    runner._primary_profile_name, runner._draining = "default", False
    runner._busy_input_mode, runner._busy_text_mode = "steer", "queue"
    runner.pairing_store, runner.pairing_stores = None, {}
    runner.session_store = SessionStore(runner.config.sessions_dir, runner.config)
    runner.adapters, runner._profile_adapters = {adapter.platform: adapter}, {}
    runner._gateway_loop = asyncio.get_running_loop()
    adapter.gateway_runner = runner
    return runner


async def main():
    assert os.environ.get("INLINE_SIDECAR_TEST_MOCK") != "1"
    get_plugin_manager().discover_and_load()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    adapter = platform_registry.create_adapter("inline", PlatformConfig(
        enabled=True, token=os.environ["INLINE_TOKEN"], extra={
            "base_url": os.environ["INLINE_BASE_URL"], "sidecar_port": port,
            "dm_policy": "allowlist", "allow_from": os.environ["INLINE_E2E_HUMAN_ID"],
            "group_allow_from": os.environ["INLINE_E2E_HUMAN_ID"],
            "reply_threads": "off", "context_backfill": "off",
            "reactions": False, "sync_commands": False, "text_debounce_seconds": 0,
        },
    ))
    assert adapter is not None, "Hermes failed to instantiate the installed Inline plugin"
    assert getattr(adapter, "durable_intake", False) is True, (
        "Receiving qualification requires this exact installed adapter to adopt durable intake"
    )
    runner = matching_intake_runner(adapter)
    received = []
    inbound = asyncio.Event()

    async def reply(event):
        if event.text != "ci-real-hermes-inbound":
            return None
        if runner is not None:
            from gateway.run_intake import intake_metadata
            admitted = await runner._hm_admit_event(event)
            assert admitted is not None, "Native current-source admission refused the local input"
            current, source, _ = admitted
            route = runner.session_store.get_or_create_session(source)
            db = runner.session_store._db_for_key(route.session_key)
            assert Path(db.db_path).resolve() == Path(os.environ["HERMES_HOME"]).resolve() / "state.db"
            assert current._gateway_durable_adopted is True and current._gateway_intake_receipts
            db.append_message(route.session_id, "user", current.text, display_metadata=intake_metadata(current))
            assert db.gateway_intake_was_consumed(route.session_id, current._gateway_intake_receipts)
        received.append(event)
        inbound.set()
        return "ci-real-hermes-reply"

    if runner is not None:
        runner._wire_adapter_handlers(adapter, message_handler=reply)
    else:
        adapter.set_message_handler(reply)
    sender = None
    try:
        assert await adapter.connect(), "Hermes failed to connect its bundled sidecar"
        sender = await asyncio.create_subprocess_exec(
            os.environ["INLINE_NODE_BIN"], str(Path(os.environ["INLINE_E2E_CONSUMER"]) / "hermes-human.mjs"),
        )
        assert await asyncio.wait_for(sender.wait(), 30) == 0, "human SDK sender failed"
        await asyncio.wait_for(inbound.wait(), 30)
        assert received[0].source.user_id == os.environ["INLINE_E2E_HUMAN_ID"]

        # Fetch from the server over the real sidecar RPC, proving outbound persistence.
        async def wait_for_reply():
            while True:
                history = await adapter._sidecar_call("/history", {
                    "target": {"userId": os.environ["INLINE_E2E_HUMAN_ID"]}, "limit": 20,
                })
                messages = history["result"]["messages"]
                replies = [m for m in messages if m.get("message") == "ci-real-hermes-reply"]
                if replies:
                    assert len(replies) == 1, "Hermes sent the reply more than once"
                    assert str(replies[0]["fromId"]) == os.environ["INLINE_E2E_BOT_ID"]
                    assert any(m.get("message") == "ci-real-hermes-inbound" for m in messages)
                    return
                await asyncio.sleep(0.2)

        await asyncio.wait_for(wait_for_reply(), 30)
        assert len(received) == 1, "Hermes dispatched the inbound message more than once"
    finally:
        if sender is not None and sender.returncode is None:
            sender.kill()
            await sender.wait()
        await adapter.disconnect()
        if runner is not None:
            runner.session_store.close_all_db_handles()
    print("Packed Hermes plugin + real Hermes host + bundled Node sidecar: inbound and reply persisted through local Inline server.")


asyncio.run(main())
