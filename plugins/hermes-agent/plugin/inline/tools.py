"""Model-callable Inline tool surface for Hermes Agent."""
from __future__ import annotations

import json
import http.client
from collections import OrderedDict
import os
import re
import urllib.error
import urllib.request
from typing import Any, Dict, Iterable, Optional

from .message_actions import build_inline_agent_action_id
from .profile import hermes_home, inline_env, multiplex_active

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
_MAX_ACTION_ROWS = 8
_MAX_ACTIONS_PER_ROW = 8
_MAX_ACTION_LABEL_CHARS = 64
_MAX_ACTION_CALLBACK_BYTES = 1024
_MAX_ACTION_COPY_TEXT_CHARS = 4096
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
    "do not treat thread ids as reply/quote message ids. Supported Markdown is "
    "emphasis, inline or fenced code, links, headings, lists or checklists, "
    "quotes, tables, separators, and HTTP(S) images. Do not rely on "
    "strikethrough, footnotes, or arbitrary HTML; unsupported or ambiguous "
    "incomplete syntax remains visible text. Use ordinary Markdown "
    "tables for tabular data, never fenced-code tables. For collapsible work, "
    "use <details open>, then <summary>Title</summary>, body Markdown, and "
    "</details>; put kind=\"progress\" on summary only while work is in progress. "
    "Use <footer>Attribution or brief metadata</footer> for a short footer."
)

# Where each turn's triggering message physically lives, and who sent it. Hermes tells tools
# the session's chat and message id, but a thread's opener is keyed on the thread while its
# message lives in the parent chat, so "this message" must be paired with its own chat.
_turn_messages: "OrderedDict[tuple[str, str, str, str], Dict[str, Any]]" = OrderedDict()
_TURN_MESSAGES_MAX = 1000


def remember_turn_message(
    *, session_chat_id: str, thread_id: str, message_id: str, chat_id: str, sender_id: str, sender_is_bot: bool,
    chat_type: str = "", in_reply_thread: bool = False,
) -> None:
    key = (str(hermes_home()), str(session_chat_id or ""), str(thread_id or ""), str(message_id or ""))
    _turn_messages[key] = {
        "chatId": str(chat_id), "senderId": str(sender_id or ""), "senderIsBot": bool(sender_is_bot),
        "chatType": str(chat_type or ""), "inReplyThread": bool(in_reply_thread),
    }
    _turn_messages.move_to_end(key)
    while len(_turn_messages) > _TURN_MESSAGES_MAX:
        _turn_messages.popitem(last=False)


def _current_turn() -> Dict[str, Any]:
    """This turn's message: its id, the chat it lives in, and its sender when known."""
    message_id = _session_message_id()
    session_chat = _session_chat_id(prefer_thread=False)
    thread_id = _inline_id(_session_env("HERMES_SESSION_THREAD_ID", ""))
    known = _turn_messages.get((str(hermes_home()), session_chat, thread_id, message_id)) or {}
    # The turn already runs in a thread when reply threads moved it there (its message lives
    # in the parent chat) or when its message was sent inside the thread.
    in_thread = bool(thread_id) and (bool(known.get("inReplyThread")) or (known.get("chatId") or session_chat) != thread_id)
    return {
        "messageId": message_id,
        "chatId": known.get("chatId") or session_chat,
        "senderId": known.get("senderId") or "",
        "senderIsBot": known.get("senderIsBot"),
        "chatType": known.get("chatType") or "",
        "inReplyThread": bool(known.get("inReplyThread")),
        "threadId": thread_id if in_thread else "",
    }


# Live sidecars by profile home: one gateway process can serve several profiles,
# and a tool call must reach the sidecar of the bot it runs for.
_sidecars: Dict[str, Dict[str, Any]] = {}
# The adapter that owns each profile's Inline settings (reply threads), for the same reason.
_settings_owners: Dict[str, Any] = {}

_ACTION_MANIFEST = [
    ("send_message", "(chat_id?|user_id?, text, buttons?)", "Send a message, including optional agent-owned buttons."),
    ("get_chat", "(chat_id?)", "Get metadata for a chat or reply thread, including whether you follow it."),
    ("set_follow_mode", "(chat_id?, mode)", "Follow a thread to join its conversation, or unfollow it to answer only mentions and replies. Applies to you only; mode is following or unfollowed."),
    ("get_messages", "(chat_id?, message_ids)", "Fetch specific Inline messages by ID."),
    ("get_history", "(chat_id?, limit?, anchor_id?)", "Fetch recent or anchored Inline history."),
    ("search_messages", "(chat_id?|user_id?, query, limit?, offset_id?)", "Search Inline message text in a chat, thread, or DM."),
    ("edit_message", "(chat_id?|user_id?, message_id, text, buttons?)", "Edit a bot-owned message and optionally replace or clear its buttons."),
    ("delete_message", "(chat_id?|user_id?, message_id)", "Delete a bot-owned message."),
    ("add_reaction", "(chat_id?|user_id?, message_id?, emoji)", "Add a reaction to an Inline message."),
    ("remove_reaction", "(chat_id?|user_id?, message_id?, emoji)", "Remove the bot's reaction from an Inline message."),
    ("get_reactions", "(chat_id?|user_id?, message_id?)", "Read reactions for an Inline message."),
    ("pin_message", "(chat_id?|user_id?, message_id?)", "Pin an Inline message for the conversation."),
    ("unpin_message", "(chat_id?|user_id?, message_id?)", "Unpin an Inline message for the conversation."),
    ("list_pins", "(chat_id?)", "List pinned Inline message IDs for a chat or reply thread."),
    ("create_thread", "(parent_chat_id?, parent_message_id?, title?)", "Create an Inline reply thread on a message. For the message you're answering, your answer goes into the thread; if this conversation already has its thread, you get that one back."),
    ("set_reply_threads", "(mode)", "Change where your answers go in this chat when someone asks you to: auto answers in the chat and starts a thread only when asked; on answers each message in a reply thread; default clears this chat's setting."),
    ("create_chat", "(title, space_id?, participant_user_ids?, is_public?, include_requester?)", "Create a top-level Inline thread/chat. A private chat includes the person who asked unless include_requester is false."),
    ("add_participants", "(chat_id?, user_ids)", "Add people or agents to a chat or thread you manage."),
    ("update_chat", "(chat_id?, title?, emoji?)", "Rename a chat or thread, or change its emoji."),
    ("delete_chat", "(chat_id)", "Delete a chat or thread you created. This can't be undone."),
    ("create_agent", "(name, skill_key?, instructions?)", "Create a named Inline Agent backed by this bot."),
    ("get_agent", "(agent_id)", "Inspect one Agent backed by this bot."),
    ("list_agents", "()", "List Agents backed by this bot."),
    ("update_agent", "(agent_id, fields...)", "Update a named Inline Agent; empty optional fields clear them."),
    ("delete_agent", "(agent_id)", "Delete an Agent backed by this bot."),
    ("set_presence", "(chat_id?|user_id?, kind, comment?)", "Set the bot avatar presence/status message."),
]
_ACTIONS = [name for name, _, _ in _ACTION_MANIFEST]
_PRESENCE_KINDS = ["idle", "happy", "waving", "jumping", "failed", "waiting", "running", "review"]


def configure_sidecar(*, bind: str, port: int, token: str) -> None:
    """Store live adapter sidecar details for model tools in this profile."""
    if not token:
        return
    _sidecars[str(hermes_home())] = {"bind": bind, "port": int(port), "token": token}


def _current_sidecar() -> Dict[str, Any]:
    current = _sidecars.get(str(hermes_home()))
    if current is not None:
        return current
    # Only a gateway serving one profile may fall back to its one sidecar; with several
    # profiles, another profile's sidecar would act as the wrong bot.
    if len(_sidecars) == 1 and not multiplex_active():
        return next(iter(_sidecars.values()))
    if _sidecars:
        raise InlineToolError("Inline is not connected for this profile", "forbidden")
    return {}


def configure_settings(owner: Any) -> None:
    """Register the adapter that keeps this profile's Inline settings."""
    _settings_owners[str(hermes_home())] = owner


def _current_settings_owner() -> Any:
    current = _settings_owners.get(str(hermes_home()))
    if current is not None or multiplex_active():
        return current
    return next(iter(_settings_owners.values())) if len(_settings_owners) == 1 else None


def check_inline_tool_requirements() -> bool:
    if multiplex_active():
        return str(hermes_home()) in _sidecars
    if _sidecars or inline_env("INLINE_SIDECAR_TOKEN"):
        return True
    return bool(inline_env("INLINE_TOKEN") or inline_env("INLINE_BOT_TOKEN"))


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
        "- Return normal replies as text. Use inline send_message only to create a message with action buttons or to send into a different destination.",
        "- An Inline action-button turn names its source message. A normal response replaces that message; omitted buttons clear the old buttons. Use edit_message with buttons to replace them explicitly.",
        "- If edit_message already finalized the source action card during this turn, return NO_REPLY so the automatic final response does not overwrite that edit.",
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
        "Return normal assistant replies as text. Use send_message only for a button card or a different destination. "
        "Agent-owned button presses return as ordinary turns, and the normal response replaces the source card while clearing omitted buttons. "
        "Use create_thread on the current triggering message when someone asks to continue in a thread; your answer then goes into it, so don't also post it in the chat. "
        "Use set_reply_threads when someone asks you to always or never answer in threads here. "
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
            "title": {"type": "string", "description": "Thread title. Required for create_chat, optional for create_thread, and the new name for update_chat."},
            "name": {"type": "string", "description": "Agent name for create_agent."},
            "agent_id": {"type": "string", "description": "Globally unique Inline Agent ID for get_agent, update_agent, or delete_agent."},
            "handle": {"type": "string", "description": "Optional Agent handle."},
            "skill_key": {"type": "string", "description": "Optional harness skill key for create_agent or update_agent."},
            "instructions": {"type": "string", "description": "Optional specialized Agent instructions for create_agent or update_agent."},
            "description": {"type": "string", "description": "Optional thread or Agent description."},
            "emoji": {"type": "string", "description": "Reaction emoji for reaction actions. For create_chat, create_thread and update_chat, one fitting emoji helps people spot the chat in their list; pass one unless the topic is sensitive or serious. Also an Agent's emoji."},
            "space_id": {"type": "string", "description": "Optional parent space ID for create_chat."},
            "participant_user_ids": {
                "type": "array",
                "items": {"type": "string"},
                "maxItems": 50,
                "description": "User IDs for a private create_chat destination. Omit or pass [] for a connected-account-only thread. Include intended human participants explicitly; bot ownership does not grant access.",
            },
            "is_public": {
                "type": "boolean",
                "description": "Whether create_chat is visible to the parent space. Defaults to false and requires space_id when true.",
            },
            "query": {"type": "string", "description": "Search query for search_messages."},
            "text": {"type": "string", "description": "Message text for send_message or edit_message."},
            "buttons": {
                "type": "array",
                "maxItems": _MAX_ACTION_ROWS,
                "description": "Button rows. Omit to preserve buttons on edit; pass [] to clear them.",
                "items": {
                    "type": "array",
                    "maxItems": _MAX_ACTIONS_PER_ROW,
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": {"type": "string", "description": "Visible button label."},
                            "callback_data": {"type": "string", "description": "Opaque data returned in an agent turn when pressed."},
                            "copy_text": {"type": "string", "description": "Text copied locally instead of invoking the agent."},
                        },
                        "required": ["text"],
                    },
                },
            },
            "parse_markdown": {"type": "boolean", "description": "Whether Inline should parse its supported Markdown surface. Defaults to true; false preserves the supplied syntax literally."},
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
            "user_ids": {"type": "array", "items": {"type": "string"}, "description": "add_participants: Inline user IDs of the people or agents to add."},
            "include_requester": {"type": "boolean", "description": "create_chat: include the person who asked (default true for private chats). Set false only for a deliberately bot-only chat."},
            "mode": {"type": "string", "enum": ["following", "unfollowed", "auto", "on", "default"], "description": "set_follow_mode: following joins the thread's conversation; unfollowed limits you to mentions and replies. set_reply_threads: auto, on, or default to clear this chat's setting."},
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
        if action == "set_follow_mode":
            return tool_result({"success": True, "action": action, "result": _set_follow_mode(args)})
        if action == "set_reply_threads":
            return tool_result({"success": True, "action": action, "result": _set_reply_threads(args)})
        if action == "create_thread":
            return tool_result({"success": True, "action": action, "result": _create_thread(args)})
        path, body = _request_for_action(action, args)
        response = _sidecar_call(path, body)
        result = _compact_result(action, response.get("result") or {})
        return tool_result({"success": True, "action": action, "result": result})
    except InlineToolError as exc:
        return tool_error(str(exc), action=action, error_kind=exc.error_kind)


def _request_for_action(action: str, args: Dict[str, Any]) -> tuple[str, Dict[str, Any]]:
    if action == "send_message":
        body = {
            "target": _target(args),
            "text": _required_str(args, "text", max_chars=_MAX_TEXT_CHARS),
            "parseMarkdown": _bool(args.get("parse_markdown"), True),
        }
        actions = _message_actions(args)
        if actions is not None:
            body["actions"] = actions
        return "/send", body

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
        body = {
            "target": _target(args),
            "messageId": _required_id(args, "message_id"),
            "text": _required_str(args, "text", max_chars=_MAX_TEXT_CHARS),
            "parseMarkdown": _bool(args.get("parse_markdown"), True),
        }
        actions = _message_actions(args)
        if actions is not None:
            body["actions"] = actions
        return "/edit", body

    if action == "delete_message":
        return "/delete", {
            "target": _target(args),
            "messageId": _required_id(args, "message_id"),
        }

    if action in {"add_reaction", "remove_reaction"}:
        target, message_id = _message_target(args)
        body = {
            "target": target,
            "messageId": message_id,
            "emoji": _required_str(args, "emoji", max_chars=64),
        }
        if action == "remove_reaction":
            body["remove"] = True
        return "/reaction", body

    if action == "get_reactions":
        target, message_id = _message_target(args)
        return "/reactions", {"target": target, "messageId": message_id}

    if action in {"pin_message", "unpin_message"}:
        target, message_id = _message_target(args)
        body = {"target": target, "messageId": message_id}
        if action == "unpin_message":
            body["unpin"] = True
        return "/pin", body

    if action == "list_pins":
        return "/pins", {"target": _target(args)}

    if action == "create_thread":
        turn = _current_turn()
        parent_chat_id = _inline_id(args.get("parent_chat_id")) or turn["chatId"]
        if not parent_chat_id:
            raise InlineToolError("create_thread requires parent_chat_id or current Inline chat context", "bad_format")
        body = {"parentChatId": parent_chat_id}
        # Message ids are per chat: anchor on this turn's message only inside its own chat.
        parent_message_id = _inline_id(args.get("parent_message_id")) or (
            turn["messageId"] if parent_chat_id == turn["chatId"] else ""
        )
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
        if not body["isPublic"] and _bool(args.get("include_requester"), True):
            # The person who asked can open the chat the agent made for them (Jack, J13).
            turn = _current_turn()
            requester = _inline_id(turn["senderId"])
            if requester and turn["senderIsBot"] is False and requester not in participant_user_ids:
                participant_user_ids = [requester, *participant_user_ids]
        body["participantUserIds"] = participant_user_ids
        for key, limit in (("description", 1000), ("emoji", 16)):
            value = _str(args.get(key))
            if value:
                body[key] = _truncate(value, limit)
        return "/create-chat", body

    if action == "add_participants":
        user_ids = _id_list(args.get("user_ids"), max_items=50)
        if not user_ids:
            raise InlineToolError("add_participants requires user_ids", "bad_format")
        return "/add-participants", {"chatId": _chat_id_or_current(args), "userIds": user_ids}

    if action == "update_chat":
        body = {"chatId": _chat_id_or_current(args)}
        title = _str(args.get("title"))
        emoji = _str(args.get("emoji"))
        if title:
            body["title"] = _truncate(title, 200)
        if emoji:
            body["emoji"] = _truncate(emoji, 16)
        if len(body) == 1:
            raise InlineToolError("update_chat requires title or emoji", "bad_format")
        return "/update-chat", body

    if action == "delete_chat":
        # Deleting is never implied by the current chat: name it.
        return "/delete-chat", {"chatId": _required_id(args, "chat_id")}

    if action == "create_agent":
        body = {"name": _required_str(args, "name", max_chars=256)}
        for key in ("handle", "emoji", "description", "skill_key", "instructions"):
            value = _str(args.get(key))
            if value:
                body[key] = value
        return "/create-agent", body

    if action == "get_agent":
        return "/get-agent", {"agentId": _required_id(args, "agent_id")}

    if action == "list_agents":
        return "/list-agents", {}

    if action == "update_agent":
        body = {"agentId": _required_id(args, "agent_id")}
        if "name" in args:
            body["name"] = _required_str(args, "name", max_chars=256)
        for key in ("handle", "emoji", "description", "skill_key", "instructions"):
            if key in args and args.get(key) is not None:
                body[key] = _str(args.get(key))
        if len(body) == 1:
            raise InlineToolError("update_agent requires at least one field", "bad_format")
        return "/update-agent", body

    if action == "delete_agent":
        return "/delete-agent", {"agentId": _required_id(args, "agent_id")}

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


def _set_follow_mode(args: Dict[str, Any]) -> Dict[str, Any]:
    mode = _str(args.get("mode")).lower()
    if mode not in {"following", "unfollowed"}:
        raise InlineToolError("set_follow_mode requires mode: following or unfollowed", "bad_format")
    target = _target(args)
    if "chatId" not in target:
        raise InlineToolError("Follow state applies to threads, not direct messages", "unsupported")
    write_error: Optional[InlineToolError] = None
    try:
        _sidecar_call("/follow-mode", {"target": target, "mode": mode})
    except InlineToolError as exc:
        if exc.error_kind != "transient":
            raise
        write_error = exc
    # Report the state the server holds, not the one requested: a lost response can
    # still have applied the change.
    chat = _sidecar_call("/chat", {"target": target}).get("result") or {}
    actual = _follow_mode_from_chat(chat)
    if actual == mode:
        return {"chatId": target["chatId"], "mode": actual, "message": _FOLLOW_CONFIRMATIONS[mode]}
    if write_error:
        raise write_error
    raise InlineToolError(f"Follow state is {actual or 'default'} after the change", "unknown")


def _set_reply_threads(args: Dict[str, Any]) -> Dict[str, Any]:
    mode = _str(args.get("mode")).lower()
    if mode not in {"auto", "on", "default"}:
        raise InlineToolError("set_reply_threads requires mode auto, on or default", "bad_format")
    owner = _current_settings_owner()
    if owner is None:
        raise InlineToolError("Inline settings aren't available for this profile", "unsupported")
    turn = _current_turn()
    if not turn.get("senderId"):
        raise InlineToolError("Only the person who asked can change reply threads, and this turn has no sender", "forbidden")
    try:
        return owner.set_reply_threads_from_tool(
            chat_id=turn["chatId"],
            chat_type=turn.get("chatType") or "group",
            in_reply_thread=bool(turn.get("inReplyThread")),
            actor_id=turn["senderId"],
            actor_is_bot=bool(turn.get("senderIsBot")),
            mode=mode,
        )
    except PermissionError as exc:
        raise InlineToolError(str(exc), "forbidden") from exc


def _create_thread(args: Dict[str, Any]) -> Dict[str, Any]:
    """One conversation, one thread. A thread for the message being answered is this turn's
    thread: if the turn already runs in one (reply threads on, or a message inside a thread),
    that thread comes back instead of a second one, and a new one receives the turn's answer."""
    path, body = _request_for_action("create_thread", args)
    turn = _current_turn()
    owner = _current_settings_owner()
    for_this_turn = bool(turn["messageId"]) and body["parentChatId"] == turn["chatId"] and (
        body.get("parentMessageId") in {None, turn["messageId"]}
    )
    if for_this_turn:
        existing = turn.get("threadId") or (owner.turn_thread(turn["chatId"], turn["messageId"]) if owner else "")
        if existing:
            return {"chatId": existing, "existing": True, "message": "This conversation already has its thread; your answer goes there."}
    result = _compact_result("create_thread", _sidecar_call(path, body).get("result") or {})
    thread_id = _inline_id(result.get("chatId"))
    if for_this_turn and owner is not None and thread_id:
        owner.note_turn_thread(turn["chatId"], turn["messageId"], thread_id)
    return result


_FOLLOW_CONFIRMATIONS = {
    "following": "Following this chat.",
    "unfollowed": "Unfollowed; mentions and replies still reach me.",
}


def _follow_mode_from_chat(chat: Dict[str, Any]) -> Optional[str]:
    value = chat.get("dialogFollowMode") if isinstance(chat, dict) else None
    dialog = chat.get("dialog") if isinstance(chat, dict) else None
    if value is None and isinstance(dialog, dict):
        value = dialog.get("followMode")
    text = _str(value).lower()
    if text in {"1", "following"}:
        return "following"
    if text in {"2", "unfollowed"}:
        return "unfollowed"
    return None


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
        # IPC stays on loopback even when the host configures an HTTP proxy.
        # The sidecar token must never be forwarded to that proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=15) as response:
            raw = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        status = exc.code
    except (OSError, http.client.HTTPException) as exc:
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
    _sidecar = _current_sidecar()
    token = _str(_sidecar.get("token")) or _str(inline_env("INLINE_SIDECAR_TOKEN"))
    if not token:
        raise InlineToolError("Inline sidecar token is not configured; start the Inline gateway adapter first", "forbidden")
    bind = _normalize_bind(_sidecar.get("bind") or inline_env("INLINE_SIDECAR_BIND"))
    port = _normalize_port(_sidecar.get("port") or inline_env("INLINE_SIDECAR_PORT"))
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


def _message_target(args: Dict[str, Any]) -> tuple[Dict[str, str], str]:
    """Target and message id; "this message" always goes with the chat it lives in."""
    explicit = _inline_id(args.get("message_id"))
    if explicit:
        return _target(args), explicit
    turn = _current_turn()
    if not turn["messageId"]:
        raise InlineToolError("message_id is required outside an Inline message context", "bad_format")
    own_chat = {"chatId": turn["chatId"]} if turn["chatId"] else None
    if (_inline_id(args.get("chat_id")) or _inline_id(args.get("user_id"))) and _target(args) != own_chat:
        raise InlineToolError("message_id is required when targeting a different chat", "bad_format")
    if own_chat is None:
        raise InlineToolError("message_id is required outside an Inline message context", "bad_format")
    return own_chat, turn["messageId"]


def _chat_id_or_current(args: Dict[str, Any]) -> str:
    chat_id = _inline_id(args.get("chat_id")) or _session_chat_id(prefer_thread=True)
    if not chat_id:
        raise InlineToolError("chat_id is required outside an Inline chat", "bad_format")
    return chat_id


def _message_actions(args: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    if "buttons" not in args:
        return None
    raw_rows = args.get("buttons")
    if not isinstance(raw_rows, list):
        raise InlineToolError("buttons must be an array of button rows", "bad_format")
    if len(raw_rows) > _MAX_ACTION_ROWS:
        raise InlineToolError(f"buttons supports at most {_MAX_ACTION_ROWS} rows", "bad_format")

    rows: list[Dict[str, Any]] = []
    for row_index, raw_row in enumerate(raw_rows):
        if not isinstance(raw_row, list) or not raw_row:
            raise InlineToolError("each buttons row must be a non-empty array", "bad_format")
        if len(raw_row) > _MAX_ACTIONS_PER_ROW:
            raise InlineToolError(
                f"each buttons row supports at most {_MAX_ACTIONS_PER_ROW} buttons",
                "bad_format",
            )
        actions: list[Dict[str, str]] = []
        for action_index, raw_button in enumerate(raw_row):
            if not isinstance(raw_button, dict):
                raise InlineToolError("each button must be an object", "bad_format")
            label = _str(raw_button.get("text"))
            if not label:
                raise InlineToolError("button text is required", "bad_format")
            if len(label) > _MAX_ACTION_LABEL_CHARS:
                raise InlineToolError(
                    f"button text supports at most {_MAX_ACTION_LABEL_CHARS} characters",
                    "bad_format",
                )
            has_callback = "callback_data" in raw_button
            has_copy = "copy_text" in raw_button
            if has_callback == has_copy:
                raise InlineToolError(
                    "each button requires exactly one of callback_data or copy_text",
                    "bad_format",
                )
            action: Dict[str, str] = {
                "id": build_inline_agent_action_id(row_index, action_index),
                "text": label,
            }
            if has_callback:
                callback_data = raw_button.get("callback_data")
                if not isinstance(callback_data, str):
                    raise InlineToolError("callback_data must be a string", "bad_format")
                if len(callback_data.encode("utf-8")) > _MAX_ACTION_CALLBACK_BYTES:
                    raise InlineToolError(
                        f"callback_data supports at most {_MAX_ACTION_CALLBACK_BYTES} UTF-8 bytes",
                        "bad_format",
                    )
                action["callback"] = callback_data
            else:
                copy_text = raw_button.get("copy_text")
                if not isinstance(copy_text, str) or not copy_text:
                    raise InlineToolError("copy_text must be a non-empty string", "bad_format")
                if len(copy_text) > _MAX_ACTION_COPY_TEXT_CHARS:
                    raise InlineToolError(
                        f"copy_text supports at most {_MAX_ACTION_COPY_TEXT_CHARS} characters",
                        "bad_format",
                    )
                action["copyText"] = copy_text
            actions.append(action)
        rows.append({"actions": actions})
    return {"rows": rows}


def _compact_result(action: str, result: Dict[str, Any]) -> Dict[str, Any]:
    if action in {"send_message", "edit_message"}:
        return {"messageId": _str(result.get("messageId"))}
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
    if action in {"create_agent", "update_agent"}:
        return {"agent": _summarize_value(result.get("agent"))}
    if action == "get_agent":
        return {
            "bot": _summarize_value(result.get("bot")),
            "agent": _summarize_value(result.get("agent")),
        }
    if action == "list_agents":
        return {"agents": _summarize_value(result.get("agents"))}
    if action == "delete_agent":
        return {"agentId": _str(result.get("agentId") or result.get("agent_id"))}
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
    if "chatId" in out:
        out["followMode"] = _follow_mode_from_chat(chat) or "default"
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
