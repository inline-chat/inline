"""Privacy-bounded Sentry error reporting for the Inline Hermes plugin.

The plugin sends only exception type/message, traceback paths/lines/functions,
release, and fixed runtime tags. It never sends Hermes events, messages,
request bodies, user/chat/account identifiers, breadcrumbs, or stack locals.
"""
from __future__ import annotations

import json
import os
import platform
import re
import threading
import time
import traceback
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence
from urllib.parse import urlparse

_HERMES_SENTRY_DSN = (
    "https://0d0eca8210b21c950e3ca2743725d2a7@o124360.ingest.us.sentry.io/4512015952576513"
)
_TELEMETRY_TIMEOUT_SECONDS = 2.0
_TELEMETRY_DEDUP_SECONDS = 5 * 60
_MAX_ERROR_MESSAGE_LENGTH = 8_000
_MAX_STACK_FRAMES = 80
_SENSITIVE_ENV_NAME = re.compile(r"(?:token|secret|password|api[_-]?key|authorization)", re.IGNORECASE)
_SAFE_TAG = re.compile(r"^[a-z0-9._-]+$")
_last_reports: dict[str, float] = {}
_report_lock = threading.Lock()


def _telemetry_disabled(env: Mapping[str, str]) -> bool:
    do_not_track = str(env.get("DO_NOT_TRACK") or "").strip().lower()
    plugin_telemetry = str(env.get("INLINE_PLUGIN_TELEMETRY") or "").strip().lower()
    return do_not_track in {"1", "true", "yes", "on"} or plugin_telemetry in {"0", "false", "off"}


def _resolve_dsn(env: Mapping[str, str]) -> str:
    if _telemetry_disabled(env):
        return ""
    if "INLINE_HERMES_SENTRY_DSN" in env:
        return str(env.get("INLINE_HERMES_SENTRY_DSN") or "").strip()
    if env.get("NODE_ENV") == "test" or env.get("VITEST") == "true":
        return ""
    return _HERMES_SENTRY_DSN


def _sensitive_values(env: Mapping[str, str], secrets: Sequence[str]) -> list[str]:
    values = [str(secret) for secret in secrets if len(str(secret)) >= 8]
    values.extend(
        str(value)
        for name, value in env.items()
        if _SENSITIVE_ENV_NAME.search(str(name)) and len(str(value)) >= 8
    )
    return list(dict.fromkeys(values))


def redact_telemetry_text(
    value: Any,
    *,
    env: Optional[Mapping[str, str]] = None,
    secrets: Sequence[str] = (),
) -> str:
    source_env = os.environ if env is None else env
    text = str(value or "")
    text = re.sub(
        r"\b(Authorization\s*[:=]\s*)(?:Basic|Bearer)\s+\S+",
        r"\1[REDACTED]",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r"\b((?:Basic|Bearer)\s+)\S+", r"\1[REDACTED]", text, flags=re.IGNORECASE)
    text = re.sub(r"(https?://)[^/\s:@]+:[^@\s/]+@", r"\1[REDACTED]@", text, flags=re.IGNORECASE)
    text = re.sub(
        r"([?&](?:access_token|auth|authorization|key|password|secret|token)[^=\s&]*)=([^&\s]+)",
        r"\1=[REDACTED]",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"\b([A-Za-z0-9_-]*(?:token|secret|password|api[_-]?key|authorization)[A-Za-z0-9_-]*)\s*([=:])\s*\S+",
        r"\1\2[REDACTED]",
        text,
        flags=re.IGNORECASE,
    )
    for secret in _sensitive_values(source_env, secrets):
        text = text.replace(secret, "[REDACTED]")
    return text[:_MAX_ERROR_MESSAGE_LENGTH]


def _safe_tag(value: str) -> str:
    normalized = str(value or "").strip().lower()
    if normalized and len(normalized) <= 80 and _SAFE_TAG.fullmatch(normalized):
        return normalized
    return "unknown"


def _release() -> Optional[str]:
    try:
        manifest = Path(__file__).with_name("plugin.yaml").read_text(encoding="utf-8")
        match = re.search(r"^version:\s*['\"]?([^'\"\n#]+)", manifest, flags=re.MULTILINE)
        if match and match.group(1).strip():
            return f"inline-hermes-plugin@{match.group(1).strip()}"
    except Exception:
        pass
    return None


def build_sentry_event(
    operation: str,
    error: BaseException,
    *,
    handled: bool = True,
    env: Optional[Mapping[str, str]] = None,
    secrets: Sequence[str] = (),
) -> dict[str, Any]:
    source_env = os.environ if env is None else env
    frames = []
    if error.__traceback__ is not None:
        for frame in traceback.extract_tb(error.__traceback__)[-_MAX_STACK_FRAMES:]:
            filename = redact_telemetry_text(frame.filename, env=source_env, secrets=secrets)
            frames.append({
                "filename": filename,
                "abs_path": filename,
                "function": redact_telemetry_text(frame.name or "<unknown>", env=source_env, secrets=secrets),
                "lineno": frame.lineno,
                "in_app": "/plugin/inline/" in filename or filename.endswith("/adapter.py"),
            })
    event: dict[str, Any] = {
        "event_id": uuid.uuid4().hex,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": "python",
        "level": "error",
        "logger": "inline.hermes.plugin",
        "exception": {"values": [{
            "type": redact_telemetry_text(type(error).__name__, env=source_env, secrets=secrets),
            "value": redact_telemetry_text(str(error), env=source_env, secrets=secrets),
            "mechanism": {"type": "inline_plugin_boundary", "handled": handled},
            **({"stacktrace": {"frames": frames}} if frames else {}),
        }]},
        "tags": {
            "operation": _safe_tag(operation),
            "component": "adapter",
            "runtime": "python",
            "os": platform.system().lower() or "unknown",
            "arch": platform.machine().lower() or "unknown",
        },
        "sdk": {"name": "inline.plugin.telemetry", "version": "1"},
    }
    release = _release()
    if release:
        event["release"] = release
    return event


def _sentry_target(dsn: str) -> Optional[tuple[str, str]]:
    parsed = urlparse(dsn)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or not parsed.username:
        return None
    parts = [part for part in parsed.path.split("/") if part]
    if not parts or not parts[-1].isdigit():
        return None
    project_id = parts.pop()
    prefix = "/" + "/".join(parts) if parts else ""
    port = f":{parsed.port}" if parsed.port is not None else ""
    endpoint = f"{parsed.scheme}://{parsed.hostname}{port}{prefix}/api/{project_id}/envelope/"
    return endpoint, parsed.username


def _send_envelope(target: tuple[str, str], dsn: str, event: Mapping[str, Any]) -> None:
    endpoint, public_key = target
    envelope = "\n".join([
        json.dumps({"event_id": event["event_id"], "dsn": dsn, "sent_at": event["timestamp"]}, separators=(",", ":")),
        json.dumps({"type": "event", "content_type": "application/json"}, separators=(",", ":")),
        json.dumps(event, separators=(",", ":")),
    ]).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=envelope,
        headers={
            "Content-Type": "application/x-sentry-envelope",
            "X-Sentry-Auth": (
                "Sentry sentry_version=7, "
                f"sentry_key={public_key}, sentry_client=inline.plugin.telemetry/1"
            ),
        },
        method="POST",
    )
    try:
        # Do not send private errors through user-configured HTTP proxies.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=_TELEMETRY_TIMEOUT_SECONDS) as response:
            response.read(1)
    except Exception:
        pass


def capture_plugin_error(
    operation: str,
    error: BaseException,
    *,
    handled: bool = True,
    secrets: Sequence[str] = (),
) -> Optional[threading.Thread]:
    env = dict(os.environ)
    dsn = _resolve_dsn(env)
    target = _sentry_target(dsn)
    if target is None:
        return None
    event = build_sentry_event(operation, error, handled=handled, env=env, secrets=secrets)
    value = event["exception"]["values"][0]
    key = f"{event['tags']['operation']}\0{value['type']}\0{value['value']}"
    now = time.monotonic()
    with _report_lock:
        if now - _last_reports.get(key, 0.0) < _TELEMETRY_DEDUP_SECONDS:
            return None
        _last_reports[key] = now
    thread = threading.Thread(
        target=_send_envelope,
        args=(target, dsn, event),
        name="inline-hermes-telemetry",
        daemon=True,
    )
    thread.start()
    return thread
