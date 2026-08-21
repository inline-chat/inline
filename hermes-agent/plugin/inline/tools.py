"""Model-callable Inline tool surface for Hermes Agent."""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from typing import Any, Dict, Iterable, Optional

try:
    from tools.registry import tool_error, tool_result
except Exception:  # pragma: no cover - used by lightweight package tests
    def tool_error(message: Any, **extra: Any) -> str:
        data = {"error": str(message)}
        data.update(extra)
        return json.dumps(data, ensure_ascii=False)

    def tool_result(data: Any = None, **kwargs: Any) -> str:
        return json.dumps(data if data is not None else kwargs, ensure_ascii=False)


_DEFAULT_SIDECAR_PORT = 8794
_DEFAULT_SIDECAR_BIND = "127.0.0.1"
_MAX_HISTORY_LIMIT = 100
_MAX_MESSAGE_IDS = 100
_MAX_INLINE_ID = 9_223_372_036_854_775_807
_DEFAULT_HISTORY_LIMIT = 20
_MAX_TEXT_CHARS = 4000
_MAX_QUERY_CHARS = 500
_MAX_RESULT_TEXT_CHARS = 1600
_MAX_MESSAGE_ENTITIES = 12
_ENTITY_TEXT_LIMIT = 120
_ENTITY_TYPE_NAMES = {
    1: "mention",
    2: "url",
    3: "text_link",
    4: "email",
    5: "bold",
    6: "italic",
    7: "username_mention",
    8: "code",
    9: "pre",
    10: "phone_number",
    11: "thread",
    12: "thread_title",
    13: "bot_command",
    14: "group_mention",
}

# User-editable, platform-wide Inline guidance. Per-turn sender-specific mention
# wording lives in inline_sender_guidance() below.
INLINE_PLATFORM_GUIDANCE = (
    "You are communicating via Inline, a work chat app. "
    "Use concise Markdown where helpful. The conversation may be a DM, "
    "group chat, or Inline reply thread. Mention users with Inline Markdown "
    "links whose visible label is their first name, falling back to username, "
    "while keeping the stable user ID in the link target. Link chats as "
    "[title](inline://chat?id=123), and link reply threads as "
    "[title](inline://thread?id=123). In Inline, reply threads are chat ids; "
    "do not treat thread ids as reply/quote message ids. Use ordinary Markdown "
    "tables for tabular data, never fenced-code tables. For collapsible work, "
    "use <details open>, then <summary>Title</summary>, body Markdown, and "
    "</details>; put kind=\"progress\" on summary only while work is in progress. "
    "Use <footer>Attribution or brief metadata</footer> for a short footer."
)

_sidecar: Dict[str, Any] = {}

_ACTION_MANIFEST = [
    ("get_chat", "(chat_id?)", "Get metadata for a chat or reply thread."),
    ("get_messages", "(chat_id?, message_ids)", "Fetch specific Inline messages by ID."),
    ("get_history", "(chat_id?, limit?, anchor_id?)", "Fetch recent or anchored Inline history."),
    ("search_messages", "(chat_id?|user_id?, query, limit?, offset_id?)", "Search Inline message text in a chat, thread, or DM."),
    ("edit_message", "(chat_id?|user_id?, message_id, text)", "Edit a bot-owned message."),
    ("delete_message", "(chat_id?|user_id?, message_id)", "Delete a bot-owned message."),
    ("add_reaction", "(chat_id?|user_id?, message_id?, emoji)", "Add a reaction to an Inline message."),
    ("remove_reaction", "(chat_id?|user_id?, message_id?, emoji)", "Remove the bot's reaction from an Inline message."),
    ("get_reactions", "(chat_id?|user_id?, message_id?)", "Read reactions for an Inline message."),
    ("pin_message", "(chat_id?|user_id?, message_id?)", "Pin an Inline message for the conversation."),
    ("unpin_message", "(chat_id?|user_id?, message_id?)", "Unpin an Inline message for the conversation."),
    ("list_pins", "(chat_id?)", "List pinned Inline message IDs for a chat or reply thread."),
    ("create_thread", "(parent_chat_id?, parent_message_id?, title?)", "Create an Inline reply thread."),
    ("create_chat", "(title, space_id?, participant_user_ids?, is_public?)", "Create a top-level Inline thread/chat."),
    ("create_agent", "(name, skill_key?, instructions?)", "Create a named Inline Agent backed by this bot."),
    ("set_presence", "(chat_id?|user_id?, kind, comment?)", "Set the bot avatar presence/status message."),
]
_ACTIONS = [name for name, _, _ in _ACTION_MANIFEST]
_PRESENCE_KINDS = ["idle", "happy", "waving", "jumping", "failed", "waiting", "running", "review"]


def configure_sidecar(*, bind: str, port: int, token: str) -> None:
    """Store live adapter sidecar details for model tools in this process."""
    if not token:
        return
    _sidecar.update({"bind": bind, "port": int(port), "token": token})


def check_inline_tool_requirements() -> bool:
    if _sidecar.get("token") or os.getenv("INLINE_SIDECAR_TOKEN"):
        return True
    return bool(os.getenv("INLINE_TOKEN") or os.getenv("INLINE_BOT_TOKEN"))


def inline_sender_guidance(
    *,
    sender_user_id: str,
    sender_name: Optional[str] = None,
    sender_first_name: Optional[str] = None,
    sender_username: Optional[str] = None,
) -> str:
    """Editable per-turn guidance for addressing and mentioning the Inline sender."""
    user_id = str(sender_user_id or "").strip()
    name = str(sender_name or "").strip()
    first_name = str(sender_first_name or "").strip()
    username = str(sender_username or "").strip().lstrip("@")
    identity = name or (f"@{username}" if username else "the current sender")
    lines = [f"- Current Inline sender is {identity} (`user:{user_id}`)."]
    label = f"@{first_name}" if first_name else (f"@{username}" if username else "")
    if label:
        lines.append(
            f"- When an actual user mention is appropriate, mention the sender as `[{label}](inline://user?id={user_id})`. "
            "Do not expose `user:<id>` as visible message text."
        )
    else:
        lines.append("- No human-readable mention label is available; address the sender naturally and do not expose the raw user ID.")
    return "\n".join(lines)


def tool_context_prompt(
    *,
    chat_id: str,
    message_id: str,
    thread_id: Optional[str] = None,
    parent_chat_id: Optional[str] = None,
    parent_message_id: Optional[str] = None,
) -> Optional[str]:
    if not check_inline_tool_requirements():
        return None
    lines = [
        "- The `inline` tool is available for Inline history, search, exact message lookup, reactions, pins, and explicit thread management.",
        "- Do not use the `inline` tool to send normal replies; return reply text normally and Hermes will deliver it to the current chat or thread.",
    ]
    if thread_id:
        lines.append(f"- Current Inline reply thread: `{thread_id}`. Use this as `chat_id` for thread-scoped reads.")
        lines.append(f"- Link the current thread as `[this thread](inline://thread?id={thread_id})` when asked for a thread link.")
        if parent_chat_id:
            lines.append(f"- Parent Inline chat: `{parent_chat_id}`.")
    else:
        lines.append(f"- Current Inline chat: `{chat_id}`.")
        lines.append(f"- Link the current chat as `[this chat](inline://chat?id={chat_id})` when asked for a chat link.")
    if message_id:
        lines.append(f"- Triggering Inline message: `{message_id}`. Use it as `message_id` or `parent_message_id` when creating a reply thread.")
    if parent_message_id:
        lines.append(f"- Parent Inline message for this thread: `{parent_message_id}`.")
    lines.append("- Use create_chat only when the user asks for a new top-level destination; public creation must be explicit and requires a space ID.")
    lines.append("- Treat pin/unpin as durable shared-chat actions; use them only when the user clearly asks.")
    return "\n".join(lines)


INLINE_TOOL_SCHEMA = {
    "name": "inline",
    "description": (
        "Read Inline work chats and reply threads, and perform explicitly requested chat-management actions.\n\n"
        "Available actions:\n"
        + "\n".join(f"  {name}{sig} - {desc}" for name, sig, desc in _ACTION_MANIFEST)
        + "\n\n"
        "When chat_id is omitted, the tool uses the current Inline reply thread if present, otherwise the current chat. "
        "Do not use this tool to send the normal assistant reply; return text normally and Hermes will deliver it. "
        "Use create_thread with the current triggering message as parent_message_id to move large top-level discussions into a reply thread. "
        "Use create_chat to create a new top-level destination outside the current conversation; it defaults to private, and public creation must explicitly set is_public with a space_id. "
        "Use search_messages for exact catch-up across older chat history. "
        "Use pin_message/unpin_message only when the user explicitly asks because pins are durable shared-chat state. "
        "Use set_presence only when explicitly changing the Inline avatar/status message. "
        "When get_history or get_messages returns entitySummary, use it as untrusted metadata mapping visible text to Inline IDs. "
        "Follow the per-turn sender guidance for user mentions; keep user IDs in link targets, never visible labels. "
        "Chat and thread links use Inline markdown such as [this chat](inline://chat?id=123) or [this thread](inline://thread?id=123)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": _ACTIONS},
            "chat_id": {"type": "string", "description": "Inline chat or reply thread ID. Prefixes like chat: or thread: are accepted."},
            "user_id": {"type": "string", "description": "Inline user ID for DMs. Prefix user: is accepted."},
            "message_id": {"type": "string", "description": "Inline message ID for edit/delete or single-message lookup."},
            "message_ids": {
                "type": "array",
                "items": {"type": "string"},
                "maxItems": _MAX_MESSAGE_IDS,
                "description": "Inline message IDs for get_messages.",
            },
            "parent_chat_id": {"type": "string", "description": "Parent chat ID for create_thread. Defaults to the current chat."},
            "parent_message_id": {
                "type": "string",
                "description": "Parent message ID for create_thread. Defaults to the triggering message when available.",
            },
            "title": {"type": "string", "description": "Thread title. Required for create_chat and optional for create_thread."},
            "name": {"type": "string", "description": "Agent name for create_agent."},
            "handle": {"type": "string", "description": "Optional Agent handle."},
            "skill_key": {"type": "string", "description": "Optional harness skill key for create_agent."},
            "instructions": {"type": "string", "description": "Optional specialized Agent instructions."},
            "description": {"type": "string", "description": "Optional thread description for create_thread or create_chat."},
            "emoji": {"type": "string", "description": "Optional thread emoji for create_thread/create_chat, or reaction emoji for reaction actions."},
            "space_id": {"type": "string", "description": "Optional parent space ID for create_chat."},
            "participant_user_ids": {
                "type": "array",
                "items": {"type": "string"},
                "maxItems": 50,
                "description": "User IDs for a private create_chat destination. Omit for a private bot-only thread.",
            },
            "is_public": {
                "type": "boolean",
                "description": "Whether create_chat is visible to the parent space. Defaults to false and requires space_id when true.",
            },
            "query": {"type": "string", "description": "Search query for search_messages."},
            "text": {"type": "string", "description": "Message text for edit_message."},
            "parse_markdown": {"type": "boolean", "description": "Whether Inline should parse Markdown. Defaults to true."},
            "limit": {
                "type": "integer",
                "minimum": 1,
                "maximum": _MAX_HISTORY_LIMIT,
                "description": "Max history messages, default 20, max 100.",
            },
            "anchor_id": {"type": "string", "description": "Anchor message ID for get_history pagination."},
            "offset_id": {"type": "string", "description": "Offset message ID for search_messages pagination."},
            "kind": {"type": "string", "enum": _PRESENCE_KINDS, "description": "Bot avatar presence/status kind."},
            "comment": {"type": "string", "description": "Optional bot avatar presence/status message."},
        },
        "required": ["action"],
    },
}


def register(ctx: Any) -> None:
    ctx.register_tool(
        name="inline",
        toolset="inline",
        schema=INLINE_TOOL_SCHEMA,
        handler=_handle_inline_tool,
        check_fn=check_inline_tool_requirements,
        description="Read Inline chats, messages, reply threads, and explicit chat-management state.",
        emoji="💬",
    )


def _handle_inline_tool(args: Dict[str, Any], **_: Any) -> str:
    if not isinstance(args, dict):
        return tool_error("inline: expected JSON object arguments")

    action = _str(args.get("action"))
    if action not in _ACTIONS:
        return tool_error(f"inline: unknown action {action or '(empty)'}", allowed_actions=_ACTIONS)

    try:
        path, body = _request_for_action(action, args)
        response = _sidecar_call(path, body)
        result = _compact_result(action, response.get("result") or {})
        return tool_result({"success": True, "action": action, "result": result})
    except InlineToolError as exc:
        return tool_error(str(exc), action=action, error_kind=exc.error_kind)


def _request_for_action(action: str, args: Dict[str, Any]) -> tuple[str, Dict[str, Any]]:
    if action == "get_chat":
        return "/chat", {"target": _target(args)}

    if action == "get_messages":
        ids = _message_ids(args)
        if not ids:
            raise InlineToolError("get_messages requires message_ids or message_id", "bad_format")
        return "/messages", {"target": _target(args), "messageIds": ids}

    if action == "get_history":
        body = {
            "target": _target(args),
            "limit": _limit(args.get("limit")),
        }
        anchor_id = _inline_id(args.get("anchor_id"))
        if anchor_id:
            body["anchorId"] = anchor_id
        return "/history", body

    if action == "search_messages":
        body = {
            "target": _target(args),
            "query": _required_str(args, "query", max_chars=_MAX_QUERY_CHARS),
            "limit": _limit(args.get("limit")),
        }
        offset_id = _inline_id(args.get("offset_id"))
        if offset_id:
            body["offsetId"] = offset_id
        return "/search", body

    if action == "edit_message":
        return "/edit", {
            "target": _target(args),
            "messageId": _required_id(args, "message_id"),
            "text": _required_str(args, "text", max_chars=_MAX_TEXT_CHARS),
            "parseMarkdown": _bool(args.get("parse_markdown"), True),
        }

    if action == "delete_message":
        return "/delete", {
            "target": _target(args),
            "messageId": _required_id(args, "message_id"),
        }

    if action in {"add_reaction", "remove_reaction"}:
        body = {
            "target": _target(args),
            "messageId": _message_id_or_current(args),
            "emoji": _required_str(args, "emoji", max_chars=64),
        }
        if action == "remove_reaction":
            body["remove"] = True
        return "/reaction", body

    if action == "get_reactions":
        return "/reactions", {
            "target": _target(args),
            "messageId": _message_id_or_current(args),
        }

    if action in {"pin_message", "unpin_message"}:
        body = {
            "target": _target(args),
            "messageId": _message_id_or_current(args),
        }
        if action == "unpin_message":
            body["unpin"] = True
        return "/pin", body

    if action == "list_pins":
        return "/pins", {"target": _target(args)}

    if action == "create_thread":
        parent_chat_id = _inline_id(args.get("parent_chat_id")) or _session_chat_id(prefer_thread=False)
        if not parent_chat_id:
            raise InlineToolError("create_thread requires parent_chat_id or current Inline chat context", "bad_format")
        body = {"parentChatId": parent_chat_id}
        parent_message_id = _inline_id(args.get("parent_message_id")) or _session_message_id()
        if parent_message_id:
            body["parentMessageId"] = parent_message_id
        for key in ("title", "description", "emoji"):
            value = _str(args.get(key))
            if value:
                body[key] = value
        return "/create-subthread", body

    if action == "create_chat":
        body = {
            "title": _required_str(args, "title", max_chars=200),
            "isPublic": _bool(args.get("is_public"), False),
        }
        space_id = _inline_id(args.get("space_id"))
        if space_id:
            body["spaceId"] = space_id
        participant_user_ids = _id_list(args.get("participant_user_ids"), max_items=50)
        if body["isPublic"]:
            if not space_id:
                raise InlineToolError("public create_chat requires space_id", "bad_format")
            if participant_user_ids:
                raise InlineToolError("public create_chat cannot include participant_user_ids", "bad_format")
        body["participantUserIds"] = participant_user_ids
        for key, limit in (("description", 1000), ("emoji", 16)):
            value = _str(args.get(key))
            if value:
                body[key] = _truncate(value, limit)
        return "/create-chat", body

    if action == "create_agent":
        body = {"name": _required_str(args, "name", max_chars=256)}
        for key in ("handle", "emoji", "description", "skill_key", "instructions"):
            value = _str(args.get(key))
            if value:
                body[key] = value
        return "/create-agent", body

    if action == "set_presence":
        kind = _str(args.get("kind"))
        if kind not in _PRESENCE_KINDS:
            raise InlineToolError(f"set_presence requires kind: {', '.join(_PRESENCE_KINDS)}", "bad_format")
        body = {"target": _target(args), "kind": kind}
        comment = _str(args.get("comment"))
        if comment:
            body["comment"] = comment
        return "/presence", body

    raise InlineToolError(f"inline: unimplemented action {action}", "bad_format")


def _sidecar_call(path: str, body: Dict[str, Any]) -> Dict[str, Any]:
    base_url, token = _sidecar_config()
    request = urllib.request.Request(
        f"{base_url}{path}",
        data=json.dumps({k: v for k, v in body.items() if v is not None}).encode("utf-8"),
        headers={
            "content-type": "application/json; charset=utf-8",
            "x-hermes-sidecar-token": token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        status = exc.code
    except urllib.error.URLError as exc:
        raise InlineToolError(f"Inline sidecar is not reachable: {exc}", "transient") from exc

    try:
        data = json.loads(raw or "{}")
    except json.JSONDecodeError as exc:
        raise InlineToolError(f"Inline sidecar returned invalid JSON: {exc}", "unknown") from exc

    if status != 200 or not data.get("ok"):
        error = str(data.get("error") or f"Inline sidecar returned HTTP {status}")
        error_kind = str(data.get("errorKind") or "unknown")
        raise InlineToolError(error, error_kind)
    return data


def _sidecar_config() -> tuple[str, str]:
    token = _str(_sidecar.get("token")) or _str(os.getenv("INLINE_SIDECAR_TOKEN"))
    if not token:
        raise InlineToolError("Inline sidecar token is not configured; start the Inline gateway adapter first", "forbidden")
    bind = _normalize_bind(_sidecar.get("bind") or os.getenv("INLINE_SIDECAR_BIND"))
    port = _normalize_port(_sidecar.get("port") or os.getenv("INLINE_SIDECAR_PORT"))
    host = f"[{bind}]" if ":" in bind and not bind.startswith("[") else bind
    return f"http://{host}:{port}", token


def _target(args: Dict[str, Any]) -> Dict[str, str]:
    chat_id = _inline_id(args.get("chat_id"))
    user_id = _inline_id(args.get("user_id"))
    if chat_id and user_id:
        raise InlineToolError("target cannot include both chat_id and user_id", "bad_format")
    if chat_id:
        return {"chatId": chat_id}
    if user_id:
        return {"userId": user_id}
    current = _session_chat_id(prefer_thread=True)
    if current:
        return {"chatId": current}
    raise InlineToolError("target requires chat_id, user_id, or current Inline chat context", "bad_format")


def _session_chat_id(*, prefer_thread: bool) -> str:
    if _session_env("HERMES_SESSION_PLATFORM", "") not in {"", "inline"}:
        return ""
    if prefer_thread:
        thread_id = _inline_id(_session_env("HERMES_SESSION_THREAD_ID", ""))
        if thread_id:
            return thread_id
    return _inline_id(_session_env("HERMES_SESSION_CHAT_ID", ""))


def _session_message_id() -> str:
    if _session_env("HERMES_SESSION_PLATFORM", "") not in {"", "inline"}:
        return ""
    return _inline_id(_session_env("HERMES_SESSION_MESSAGE_ID", ""))


def _session_env(name: str, default: str = "") -> str:
    try:
        from gateway.session_context import get_session_env
        return str(get_session_env(name, default) or "")
    except Exception:
        return str(os.getenv(name, default) or "")


def _message_ids(args: Dict[str, Any]) -> list[str]:
    raw = args.get("message_ids")
    values: Iterable[Any]
    if isinstance(raw, list):
        values = raw
    elif _str(raw):
        values = _str(raw).split(",")
    else:
        values = []
    items = list(values)
    single_value = args.get("message_id")
    if _str(single_value):
        items.append(single_value)
    if len(items) > _MAX_MESSAGE_IDS:
        raise InlineToolError(f"message_ids supports at most {_MAX_MESSAGE_IDS} items", "bad_format")
    ids: list[str] = []
    seen: set[str] = set()
    for item in items:
        inline_id = _inline_id(item)
        if not inline_id or inline_id in seen:
            continue
        seen.add(inline_id)
        ids.append(inline_id)
    return ids


def _message_id_or_current(args: Dict[str, Any]) -> str:
    message_id = _inline_id(args.get("message_id")) or _session_message_id()
    if not message_id:
        raise InlineToolError("message_id is required outside an Inline message context", "bad_format")
    return message_id


def _compact_result(action: str, result: Dict[str, Any]) -> Dict[str, Any]:
    if action == "get_chat":
        return _compact_chat(result)
    if action in {"get_messages", "get_history", "search_messages"}:
        messages = result.get("messages") if isinstance(result, dict) else []
        if not isinstance(messages, list):
            messages = []
        return {
            "count": len(messages),
            "messages": [_compact_message(msg) for msg in messages],
        }
    if action == "get_reactions":
        message = result.get("message") if isinstance(result, dict) else None
        return {
            "message": _compact_message(message) if message else None,
            "reactions": _summarize_value(result.get("reactions")) if isinstance(result, dict) else None,
        }
    if action in {"add_reaction", "remove_reaction"}:
        return {
            "messageId": _str(result.get("messageId")),
            "emoji": _str(result.get("emoji")),
            "removed": bool(result.get("removed")),
        }
    if action in {"pin_message", "unpin_message"}:
        return {
            "messageId": _str(result.get("messageId")),
            "unpinned": bool(result.get("unpinned")),
        }
    if action == "list_pins":
        pins = result.get("pinnedMessageIds") if isinstance(result, dict) else []
        return {
            "chatId": _str(result.get("chatId")) if isinstance(result, dict) else "",
            "pinnedMessageIds": pins if isinstance(pins, list) else [],
            "anchorMessage": _compact_message(result.get("anchorMessage")) if isinstance(result, dict) and result.get("anchorMessage") else None,
        }
    if action in {"create_thread", "create_chat"}:
        return {
            "chatId": _str(result.get("chatId")),
            "chat": _compact_chat(result.get("chat") if isinstance(result.get("chat"), dict) else {}),
            "dialog": _summarize_value(result.get("dialog")) if result.get("dialog") is not None else None,
        }
    if action == "create_agent":
        return {"agent": _summarize_value(result.get("agent"))}
    return result


def _compact_chat(chat: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(chat, dict):
        return {}
    out: Dict[str, Any] = {}
    for source, dest in [
        ("chatId", "chatId"),
        ("id", "chatId"),
        ("title", "title"),
        ("spaceId", "spaceId"),
        ("parentChatId", "parentChatId"),
        ("parentMessageId", "parentMessageId"),
        ("description", "description"),
        ("emoji", "emoji"),
        ("isPublic", "isPublic"),
        ("lastMsgId", "lastMsgId"),
        ("date", "date"),
        ("createdBy", "createdBy"),
        ("untitled", "untitled"),
        ("number", "number"),
        ("pinnedMessageIds", "pinnedMessageIds"),
    ]:
        if source in chat and chat[source] is not None and dest not in out:
            out[dest] = chat[source]
    return out


def _compact_message(message: Any) -> Dict[str, Any]:
    if not isinstance(message, dict):
        return {"raw": _truncate(str(message), 200)}
    out: Dict[str, Any] = {}
    for key in ["id", "chatId", "fromId", "date", "out", "replyToMsgId", "mentioned", "rev"]:
        if key in message and message[key] is not None:
            out[key] = message[key]
    sender = message.get("sender")
    if isinstance(sender, dict):
        compact_sender = {
            key: str(sender.get(key) or "").strip()
            for key in ("id", "firstName", "lastName", "username")
            if str(sender.get(key) or "").strip()
        }
        if compact_sender:
            out["sender"] = compact_sender
    text = message.get("message")
    if text is None:
        text = message.get("text")
    if text is not None:
        out["text"] = _truncate(str(text), _MAX_RESULT_TEXT_CHARS)
    for key in ["media", "attachments", "reactions", "replies", "actions"]:
        if key in message and message[key] is not None:
            out[key] = _summarize_value(message[key])
    entity_summary, entity_count = _entity_summary_text(message, str(text or ""))
    if entity_summary:
        out["entitySummary"] = entity_summary
    if entity_count > 0:
        out["entityCount"] = entity_count
        if entity_count > _MAX_MESSAGE_ENTITIES:
            out["entitiesMore"] = entity_count - _MAX_MESSAGE_ENTITIES
    return out


def _message_entities(message: Dict[str, Any]) -> list[Dict[str, Any]]:
    candidates: list[Any] = [message.get("entities")]
    raw = message.get("raw")
    if isinstance(raw, dict):
        candidates.append(raw.get("entities"))
    for container in candidates:
        if isinstance(container, dict):
            entities = container.get("entities")
        else:
            entities = container
        if isinstance(entities, list):
            return [entity for entity in entities if isinstance(entity, dict)]
    return []


def _entity_summary_text(message: Dict[str, Any], text: str) -> tuple[str, int]:
    entities = _message_entities(message)
    parts: list[str] = []
    for entity in entities[:_MAX_MESSAGE_ENTITIES]:
        summary = _format_entity_summary(entity, text)
        if summary:
            parts.append(summary)
    if len(entities) > _MAX_MESSAGE_ENTITIES:
        parts.append(f"+{len(entities) - _MAX_MESSAGE_ENTITIES} more")
    return " | ".join(parts), len(entities)


def _format_entity_summary(entity: Dict[str, Any], text: str) -> Optional[str]:
    kind = _entity_kind(entity)
    label = _entity_slice(text, entity)
    quoted = f' "{label}"' if label else ""

    if kind == "mention":
        user_id = _entity_id(_entity_payload(entity, "mention"), "userId")
        return f"mention{quoted} -> user:{user_id}" if user_id else f"mention{quoted}"
    if kind == "group_mention":
        group_id = _entity_id(_entity_payload(entity, "groupMention", "group_mention"), "groupId")
        return f"group mention{quoted} -> group:{group_id}" if group_id else f"group mention{quoted}"
    if kind == "text_link":
        url = _compact_text(_entity_payload(entity, "textUrl", "text_url").get("url"), 240)
        return f"text link{quoted} -> {url}" if url else f"text link{quoted}"
    if kind == "thread":
        chat_id = _entity_id(_entity_payload(entity, "thread"), "chatId")
        return f"thread link{quoted} -> thread:{chat_id}" if chat_id else f"thread link{quoted}"
    if kind == "thread_title":
        payload = _entity_payload(entity, "threadTitle", "thread_title")
        space_id = _entity_id(payload, "spaceId")
        title = _compact_text(payload.get("title"), _ENTITY_TEXT_LIMIT)
        if space_id and title:
            return f"thread title link{quoted} -> space:{space_id} title:\"{title}\""
        return f"thread title link{quoted} -> space:{space_id}" if space_id else f"thread title link{quoted}"
    if kind == "pre":
        language = _compact_text(_entity_payload(entity, "pre").get("language"), 80)
        return f"preformatted block{quoted} (language: {language})" if language else f"preformatted block{quoted}"
    if kind == "username_mention":
        return f"username mention{quoted}"
    if kind == "phone_number":
        return f"phone number{quoted}"
    if kind == "bot_command":
        return f"bot command{quoted}"
    if kind == "unknown" and not label:
        return None
    return f"{kind.replace('_', ' ')}{quoted}"


def _entity_kind(entity: Dict[str, Any]) -> str:
    payload = entity.get("entity")
    oneof = str(payload.get("oneofKind") or "") if isinstance(payload, dict) else ""
    if oneof == "textUrl":
        return "text_link"
    if oneof == "threadTitle":
        return "thread_title"
    if oneof == "groupMention":
        return "group_mention"
    if oneof:
        return re.sub(r"[^a-z0-9_]", "_", oneof.strip().lower())

    type_id = _to_int(entity.get("type"))
    if type_id is not None:
        return _ENTITY_TYPE_NAMES.get(type_id, "unknown")
    text = str(entity.get("type") or "").strip().lower()
    text = re.sub(r"^type_", "", text).replace("-", "_")
    if text in {"text_url", "texturl"}:
        return "text_link"
    if text in {"threadtitle", "thread_title"}:
        return "thread_title"
    if text in {"groupmention", "group_mention"}:
        return "group_mention"
    return text or "unknown"


def _entity_payload(entity: Dict[str, Any], *keys: str) -> Dict[str, Any]:
    payload = entity.get("entity")
    if not isinstance(payload, dict):
        return {}
    for key in keys:
        value = payload.get(key)
        if isinstance(value, dict):
            return value
    return {}


def _entity_id(payload: Dict[str, Any], key: str) -> Optional[str]:
    value = payload.get(key)
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _entity_slice(text: str, entity: Dict[str, Any]) -> str:
    offset = _to_int(entity.get("offset"))
    length = _to_int(entity.get("length"))
    if offset is None or length is None or offset < 0 or length <= 0:
        return ""
    return _compact_text(text[offset: offset + length], _ENTITY_TEXT_LIMIT)


def _summarize_value(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        return _truncate(value, 240)
    if isinstance(value, list):
        return [_summarize_value(item) for item in value[:8]]
    if isinstance(value, dict):
        out: Dict[str, Any] = {}
        for key, item in list(value.items())[:12]:
            if str(key).lower() == "raw":
                continue
            out[str(key)] = _summarize_value(item)
        return out
    return _truncate(str(value), 240)


def _compact_text(value: Any, limit: int) -> str:
    return _truncate(str(value or "").replace("\n", " ").strip(), limit)


def _to_int(value: Any) -> Optional[int]:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _required_str(args: Dict[str, Any], key: str, *, max_chars: int) -> str:
    value = _str(args.get(key))
    if not value:
        raise InlineToolError(f"{key} is required", "bad_format")
    return _truncate(value, max_chars)


def _required_id(args: Dict[str, Any], key: str) -> str:
    value = _inline_id(args.get(key))
    if not value:
        raise InlineToolError(f"{key} is required", "bad_format")
    return value


def _inline_id(value: Any) -> str:
    text = _str(value)
    if not text:
        return ""
    if ":" in text:
        prefix, rest = text.split(":", 1)
        if prefix.lower() in {"chat", "thread", "user", "space", "message", "msg"}:
            text = rest.strip()
    if not text.isdigit():
        raise InlineToolError("Inline IDs must be positive signed 64-bit integers", "bad_format")
    parsed = int(text)
    if parsed <= 0 or parsed > _MAX_INLINE_ID:
        raise InlineToolError("Inline IDs must be positive signed 64-bit integers", "bad_format")
    return str(parsed)


def _id_list(value: Any, *, max_items: int) -> list[str]:
    if value is None:
        return []
    items = list(value) if isinstance(value, (list, tuple)) else [value]
    if len(items) > max_items:
        raise InlineToolError(f"too many IDs (max {max_items})", "bad_format")
    ids: list[str] = []
    seen: set[str] = set()
    for item in items:
        inline_id = _inline_id(item)
        if not inline_id or inline_id in seen:
            continue
        seen.add(inline_id)
        ids.append(inline_id)
    return ids


def _limit(value: Any) -> int:
    try:
        limit = int(value)
    except (TypeError, ValueError):
        return _DEFAULT_HISTORY_LIMIT
    return min(max(limit, 1), _MAX_HISTORY_LIMIT)


def _bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    text = _str(value).lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    return default


def _normalize_bind(value: Any) -> str:
    text = _str(value) or _DEFAULT_SIDECAR_BIND
    if text == "[::1]":
        return "::1"
    if text in {"127.0.0.1", "localhost", "::1"}:
        return text
    raise InlineToolError(f"INLINE_SIDECAR_BIND must be loopback, got {text}", "bad_format")


def _normalize_port(value: Any) -> int:
    text = _str(value)
    if not text:
        return _DEFAULT_SIDECAR_PORT
    try:
        port = int(text)
    except ValueError as exc:
        raise InlineToolError("INLINE_SIDECAR_PORT must be an integer from 1 to 65535", "bad_format") from exc
    if port < 1 or port > 65535:
        raise InlineToolError("INLINE_SIDECAR_PORT must be an integer from 1 to 65535", "bad_format")
    return port


def _str(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _truncate(text: str, limit: int) -> str:
    if limit <= 0 or len(text) <= limit:
        return text
    return text[: max(0, limit - 3)] + "..."


class InlineToolError(RuntimeError):
    def __init__(self, message: str, error_kind: str = "unknown"):
        self.error_kind = error_kind
        super().__init__(message)
