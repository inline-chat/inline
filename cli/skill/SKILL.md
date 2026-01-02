---
name: inline-cli
description: Explain and use the Inline CLI (`inline`) for authentication, chats, users, spaces, messages, search, attachments, downloads, JSON output, and configuration. Use when asked how to use the Inline CLI or its commands, flags, outputs, or workflows.
---

# Inline CLI

## Overview
Explain that Inline is a Slack-replacement work chat app and this CLI lets you authenticate, read chats/messages/users/spaces, search messages, send messages (with attachments), and download attachments.

## Quick start
- Log in interactively: `inline auth login`
- List chats: `inline chats list`
- List messages: `inline messages list --chat-id 123`
- Send a message: `inline messages send --chat-id 123 --text "hello"`

## Global flag
- `--json`: Output JSON instead of human tables/details (available on all commands).

## Command reference
### auth
- `inline auth login [--email you@x.com | --phone +15551234567]`
  - Run an interactive login flow.
  - If code is wrong, prompt to try again or edit email/phone (no hard exit).
- `inline auth logout`
  - Clear the stored token and current user.

### chats
- `inline chats list`
  - List chats with human-readable names, unread count, and last message preview (sender + text in one column).

### users
- `inline users list`
  - List users that appear in your chats (derived from getChats).
- `inline users get --id 42`
  - Fetch one user by id (from the same getChats payload).

### spaces
- `inline spaces list`
  - List spaces referenced by your chats (derived from getChats).

### messages
- `inline messages list [--chat-id 123 | --user-id 42] [--limit 50] [--offset-id 456] [--translate en]`
  - List chat history for a chat or DM.
  - `--translate <lang>` fetches translations and includes them in output.
- `inline messages search [--chat-id 123 | --user-id 42] --query "onboarding" [--query "alpha beta"] [--limit 50]`
  - Search messages in a chat or DM.
  - `--query` is repeatable; each query is split by whitespace and normalized to lowercase.
- `inline messages get --chat-id 123 --message-id 456 [--translate en]`
  - Fetch one full message by id (includes media + attachments).
- `inline messages send [--chat-id 123 | --user-id 42] [--text "hi"] [--stdin] [--attach PATH ...] [--force-file]`
  - Send a message (markdown parsing enabled).
  - `--stdin` reads message text from stdin.
  - `--attach` is repeatable. Each attachment is sent as its own message; `--text` is reused as the caption.
  - Folders are zipped before upload. Attachments over 200MB are rejected.
  - `--force-file` uploads photos/videos as files (documents).
- `inline messages download [--chat-id 123 | --user-id 42] --message-id 456 [--output PATH | --dir PATH]`
  - Download the attachment from a message.

## Output notes
- Human mode prints tables and summaries; JSON mode returns full structured output.
- Dates are relative (e.g., `2d ago`, `3h ago`, `now`).
- Message previews include text, translation snippets (if requested), and media/attachment tags.

## Data files and configuration
- Token is stored at `~/.local/share/inline/secrets.json` with restrictive permissions.
- Local state (current user, update metadata) is stored at `~/.local/share/inline/state.json`.
- Override files/URLs with env vars:
  - `INLINE_TOKEN` (use token directly, bypass file)
  - `INLINE_API_BASE_URL` (default: `http://localhost:8000/v1` in debug, `https://api.inline.chat/v1` in release)
  - `INLINE_REALTIME_URL` (default: `ws://localhost:8000/realtime` in debug, `wss://api.inline.chat/realtime` in release)
  - `INLINE_DATA_DIR`, `INLINE_SECRETS_PATH`, `INLINE_STATE_PATH`

## Example workflows
- Login and greet user:
  - `inline auth login` (prompts for email/phone + code, then prints welcome name)
- Search messages in a chat:
  - `inline messages search --chat-id 123 --query "design review"`
  - JSON: `inline messages search --chat-id 123 --query "design review" --json`
- Translate and list messages:
  - `inline messages list --chat-id 123 --translate en`
- Send message with multiple attachments:
  - `inline messages send --chat-id 123 --text "FYI" --attach ./photo.jpg --attach ./spec.pdf`
- Download an attachment:
  - `inline messages download --chat-id 123 --message-id 456 --dir ./downloads`

## JSON samples
Chat list (truncated to essential fields):
```
{
  "items": [
    {
      "displayName": "Design Team",
      "spaceName": "Design",
      "unreadCount": 2,
      "lastMessageLine": "Ava: updated the mockups",
      "lastMessageRelativeDate": "2d ago",
      "peer": { "peerType": "chat", "id": 123 },
      "chat": { "id": 123, "title": "Design Team" },
      "dialog": null,
      "space": { "displayName": "Design", "space": { "id": 9, "name": "Design", "creator": false } },
      "lastMessage": {
        "preview": "updated the mockups",
        "senderName": "Ava",
        "relativeDate": "2d ago",
        "media": null,
        "attachments": []
      }
    }
  ],
  "raw": { "chats": [], "dialogs": [], "users": [], "spaces": [] }
}
```

Message list (truncated to essential fields):
```
{
  "peer": { "peerType": "chat", "id": 123 },
  "peerName": "Design Team",
  "items": [
    {
      "message": { "id": 456, "date": 1733184000, "fromId": 42, "message": "Ship it" },
      "preview": "Ship it",
      "senderName": "You",
      "relativeDate": "2d ago",
      "translation": { "messageId": 456, "language": "en", "translation": "Ship it" },
      "media": { "kind": "document", "fileName": "spec.pdf", "mimeType": "application/pdf", "size": 120431, "url": "https://..." },
      "attachments": [
        { "kind": "url_preview", "title": "Spec", "url": "https://...", "siteName": "Docs" }
      ]
    }
  ]
}
```
