# MCP Ground-Up Refactor (2026-02-22)

## Problem
Current MCP tools force LLMs into inefficient multi-step behavior and weak disambiguation (for example selecting a thread named "Dena X Mo" instead of the DM with Dena).

## Goals
- Replace generic message-first tools with task-first utilities.
- Support broad "query data out / put data in" MCP usage.
- Keep tool APIs simple but expressive for common chat workflows.
- Avoid global message search until backend supports it natively.

## New Tool Surface (v2)
- `conversations.list`
  - Use for listing recent chats and for name/title/chat-id lookup (`query`).
  - Supports `unreadOnly` to focus inbox-style views.
- `messages.list`
  - Use for chat/DM history reads with paging.
  - Supports `direction`, `since`/`until`, `unreadOnly`, and `content` (`links|media|files` etc).
- `messages.search`
  - Chat-scoped search only (`chatId`/`userId` + optional `query` + `content`).
  - If query is omitted, falls back to content/time filtered history scan in that chat.
- `messages.unread`
  - Cross-chat unread listing (time/content constrained), for inbox prompts like "unread from yesterday".
- `conversations.create`
  - Create new threads/chats.
- `messages.send`
  - Send to chat or DM with optional reply-to.

## Behavioral Design
- Conversation ranking combines contact/name/title/chat-id matching with DM preference and recency.
- Message listing uses paged `GET_CHAT_HISTORY` reads and optional outgoing-only filtering.
- Chat search is constrained to a single selected chat for predictable cost and relevance.

## Example Prompts
1. "last message I sent to Dena"
  - `conversations.list` (`query: "Dena"`) + `messages.list` (`direction: "sent"`, `limit: 1`)
2. "find links in marketing thread from yesterday"
  - `conversations.list` (`query: "marketing"`) + `messages.search` (`content: "links"`, `since/until: "yesterday"`)
3. "create a release thread and send kickoff message"
  - `conversations.create` then `messages.send`
4. "list unread messages from yesterday"
  - `messages.unread` with `since/until: "yesterday"`

## Non-Goals
- No backward compatibility with legacy `search`/`fetch` IDs.
- No global message search tool until backend/API support exists.

## Media/File Upload + Send (v2 extension)
- Added `files.upload`
  - Accepts exactly one source: `base64` (including data URL) or `url` (HTTPS only).
  - Returns Inline-native media IDs (`photo|video|document`) plus `fileUniqueId`.
  - Security controls:
    - strict max payload limit
    - SSRF defenses (blocks localhost/private/link-local/reserved targets)
    - redirect limit + per-request timeout
    - URL credential rejection + filename sanitization
- Added `messages.send_media`
  - Sends media via `chatId` or `userId` with optional caption and reply target.
  - Reuses existing scope and chat-allowlist checks from write flow.
- Message outputs now include richer media metadata where present (`cdnUrl`, file name/mime/size, dimensions, duration) to improve file/photo retrieval workflows.

## Expected UX/Cost Improvement
- Typical person-targeted retrieval reduced to 2 calls.
- Better first-hit chat selection quality for DM intents.
- Reduced chat-by-chat brute-force scanning patterns.
