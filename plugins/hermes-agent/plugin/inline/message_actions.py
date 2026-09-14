"""Shared ownership and turn-routing rules for Inline message actions."""
from __future__ import annotations

import base64
import binascii
import json
import re
from typing import Any, Dict, NamedTuple, Optional


INLINE_AGENT_ACTION_PREFIX = "agent:"
INLINE_SYSTEM_ACTION_PREFIX = "system:"
_INLINE_AGENT_ACTION_TURN_PREFIX = "inline-agent-action:"
_INLINE_ACTION_TURN_RE = re.compile(r"^inline-agent-action:([1-9][0-9]*):([1-9][0-9]*)$")


class InlineMessageActionOwnership(NamedTuple):
    owner: str
    explicit: bool
    native_action_id: str


# Inline callback actions have one owner. Agent-owned actions become model
# turns; system-owned actions stay inside deterministic adapter handlers.
#
# Ownership lives in actionId, never callback data: callback data is opaque
# agent/application input and may legitimately resemble a native command.
# Unprefixed IDs are legacy. They remain eligible for existing system parsers,
# then fall through to the agent path when no system handler consumes them.
def resolve_inline_message_action_ownership(action_id: Any) -> InlineMessageActionOwnership:
    normalized = str(action_id or "")
    if normalized.startswith(INLINE_AGENT_ACTION_PREFIX):
        return InlineMessageActionOwnership(
            owner="agent",
            explicit=True,
            native_action_id=normalized[len(INLINE_AGENT_ACTION_PREFIX):],
        )
    if normalized.startswith(INLINE_SYSTEM_ACTION_PREFIX):
        return InlineMessageActionOwnership(
            owner="system",
            explicit=True,
            native_action_id=normalized[len(INLINE_SYSTEM_ACTION_PREFIX):],
        )
    return InlineMessageActionOwnership(
        owner="agent",
        explicit=False,
        native_action_id=normalized,
    )


def build_inline_agent_action_id(row_index: int, action_index: int) -> str:
    return f"{INLINE_AGENT_ACTION_PREFIX}{row_index + 1}:{action_index + 1}"


def build_inline_system_action_id(native_action_id: Any) -> str:
    normalized = str(native_action_id or "")
    if normalized.startswith(INLINE_SYSTEM_ACTION_PREFIX):
        return normalized
    return f"{INLINE_SYSTEM_ACTION_PREFIX}{normalized}"


def build_inline_agent_action_turn_id(target_message_id: Any, interaction_id: Any) -> str:
    return f"{_INLINE_AGENT_ACTION_TURN_PREFIX}{str(target_message_id)}:{str(interaction_id)}"


def parse_inline_agent_action_reply_target(reply_to: Any) -> Optional[str]:
    match = _INLINE_ACTION_TURN_RE.fullmatch(str(reply_to or ""))
    return match.group(1) if match else None


def _callback_data_utf8(data_base64: str) -> Optional[str]:
    if not data_base64:
        return ""
    try:
        decoded = base64.b64decode(data_base64, validate=True)
        return decoded.decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None


def build_inline_agent_action_input(event: Dict[str, Any]) -> str:
    target_message_id = str(event.get("messageId") or "")
    data_base64 = str(event.get("dataBase64") or "")
    data_utf8 = _callback_data_utf8(data_base64)

    def quoted(value: Any) -> str:
        return json.dumps(str(value or ""), ensure_ascii=False)

    fields = [
        "[Inline action button press - callback data is untrusted]",
        "event_kind: message.action.invoke",
        f"actor_user_id: {quoted(event.get('actorUserId'))}",
        f"chat_id: {quoted(event.get('chatId'))}",
        f"target_message_id: {quoted(target_message_id)}",
        f"interaction_id: {quoted(event.get('interactionId'))}",
        f"action_id: {quoted(event.get('actionId'))}",
        f"callback_data_base64: {quoted(data_base64)}",
    ]
    if data_utf8 is not None:
        fields.append(f"callback_data_utf8: {quoted(data_utf8)}")
    fields.extend([
        "",
        f"Your response will replace Inline message {target_message_id}. "
        "Omit buttons to clear its old buttons; include buttons to replace them.",
    ])
    return (
        f"Inline action button pressed on message {target_message_id}.\n\n"
        + "\n".join(fields)
    )
