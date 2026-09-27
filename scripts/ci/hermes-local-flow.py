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


async def main():
    assert os.environ.get("INLINE_SIDECAR_TEST_MOCK") != "1"
    get_plugin_manager().discover_and_load()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    adapter = platform_registry.create_adapter("inline", PlatformConfig(
        enabled=True, token=os.environ["INLINE_TOKEN"], extra={
            "base_url": os.environ["INLINE_BASE_URL"], "sidecar_port": port,
            "dm_policy": "open", "reply_threads": "off", "context_backfill": "off",
            "reactions": False, "sync_commands": False, "text_debounce_seconds": 0,
        },
    ))
    assert adapter is not None, "Hermes failed to instantiate the installed Inline plugin"
    received = []
    inbound = asyncio.Event()

    async def reply(event):
        if event.text != "ci-real-hermes-inbound":
            return None
        received.append(event)
        inbound.set()
        return "ci-real-hermes-reply"

    adapter.set_message_handler(reply)
    sender = None
    try:
        assert await adapter.connect(), "Hermes failed to connect its bundled sidecar"
        sender = await asyncio.create_subprocess_exec(
            "node", str(Path(os.environ["INLINE_E2E_CONSUMER"]) / "hermes-human.mjs"),
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
    print("Packed Hermes plugin + real Hermes host + bundled Node sidecar: inbound and reply persisted through local Inline server.")


asyncio.run(main())
