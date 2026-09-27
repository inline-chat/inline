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
from unittest.mock import patch

import httpx
try:
    import hermes_yaml as yaml
except ModuleNotFoundError as exc:
    if exc.name != "hermes_yaml":
        raise
    import yaml

home = Path(os.environ["HERMES_HOME"])
plugin = home / "plugins" / "inline"
manifest = yaml.safe_load((plugin / "plugin.yaml").read_text())
assert "inline" in manifest.get("provides_tools", []), "inline tool missing from plugin.yaml"

# Scan even before the removal deadline: deprecated facade imports are future failures.
if importlib.util.find_spec("hermes_cli.plugin_compat"):
    from hermes_cli.plugin_compat import scan_plugin
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
print("Real Hermes admission, registration, inbound/reply delivery, deduplication and media safety passed (offline transport).")
