---
name: inline-cli
description: Explain and use the Inline CLI (`inline`) for authentication, chats, users, spaces, messages, search, attachments, downloads, JSON output, and configuration. Use when asked how to use the Inline CLI or its commands, flags, outputs, or workflows.
---

# Inline CLI

## Global flags

- `--json`: Output JSON instead of human tables/details (available on all commands). This greatly increases the verbosity and information you can get. Most of the data is either not included or truncated/redacted in the default human readable mode. Use JSON mode when you need exact details of a chat, message, etc. You can start with default mode and switch to json mode for more details and form your response.
- `--pretty`: Pretty-print JSON output (default).
- `--compact`: Compact JSON output (no whitespace).

## Subcommands

### auth

- `inline auth login [--email you@x.com | --phone +15551234567]`
  - Run an interactive login flow.
  - If code is wrong, prompt to try again or edit email/phone (no hard exit).
- `inline auth me`
  - Fetch and print the current user (verifies your token is still valid).
- `inline auth logout`
  - Clear the stored token and current user.

### chats

- `inline chats list`
  - List chats with human-readable names, unread count, and last message preview (sender + text in one column).
- `inline chats get [--chat-id 123 | --user-id 42]`
  - Fetch a chat (thread or DM) by id.
- `inline chats participants --chat-id 123`
  - List participants for a chat, including join date.
- `inline chats add-participant --chat-id 123 --user-id 42`
  - Add a user to a chat.
- `inline chats remove-participant --chat-id 123 --user-id 42`
  - Remove a user from a chat.
- `inline chats create --title "Project" [--space-id 31] [--description "Spec"] [--emoji ":rocket:"] [--public] [--participant 42]`
  - Create a new chat or thread. If `--public` is set, participants must be empty.
- `inline chats create-dm --user-id 42`
  - Create a private chat (DM).
- `inline chats mark-unread [--chat-id 123 | --user-id 42]`
  - Mark a chat or DM as unread.
- `inline chats mark-read [--chat-id 123 | --user-id 42] [--max-id 456]`
  - Mark a chat or DM as read. If `--max-id` is omitted, marks through the latest message.
- `inline chats delete --chat-id 123`
  - Delete a chat (space thread). Prompts for confirmation unless `--yes` is provided.

### users

- `inline users list`
  - List users that appear in your chats (derived from getChats).
- `inline users list --filter "name"`
  - Filter users by name, username, email, or phone.
- `inline users get --id 42`
  - Fetch one user by id (from the same getChats payload).

### spaces

- `inline spaces list`
  - List spaces referenced by your chats (derived from getChats).
- `inline spaces members --space-id 31`
  - List members in a space.
- `inline spaces invite --space-id 31 [--user-id 42 | --email you@x.com | --phone +15551234567] [--admin] [--public-chats]`
  - Invite a user to a space (role is optional; defaults to server behavior).
- `inline spaces delete-member --space-id 31 --user-id 42`
  - Remove a member from a space (prompts for confirmation; use `--yes` to skip).
- `inline spaces update-member-access --space-id 31 --user-id 42 [--admin | --member] [--public-chats]`
  - Update a member's access/role. Provide `--admin` or `--member` (and optional `--public-chats`).

### notifications

- `inline notifications get`
  - Show current notification settings.
- `inline notifications set [--mode all|none|mentions|important] [--silent | --sound]`
  - Update notification settings.

### update

- `inline update`
  - Download and install the latest release for this machine.

### doctor

- `inline doctor`
  - Print diagnostic info (system, config, paths, auth state).

### messages

- `inline messages list [--chat-id 123 | --user-id 42] [--limit 50] [--offset-id 456] [--translate en]`
  - List chat history for a chat or DM.
  - `--translate <lang>` fetches translations and includes them in output.
- `inline messages export [--chat-id 123 | --user-id 42] [--limit 50] [--offset-id 456] --output PATH`
  - Export chat history to a JSON file.
- `inline messages search [--chat-id 123 | --user-id 42] --query "onboarding" [--query "alpha beta"] [--limit 50]`
  - Search messages in a chat or DM.
  - `--query` is repeatable; each query can contain space-separated terms (ANDed within a query, ORed across queries). Extra whitespace is collapsed.
- `inline messages get --chat-id 123 --message-id 456 [--translate en]`
  - Fetch one full message by id (includes media + attachments).
- `inline messages send [--chat-id 123 | --user-id 42] [--text "hi"] [--stdin] [--reply-to 456] [--mention USER_ID:OFFSET:LENGTH ...] [--attach PATH ...] [--force-file]`
  - Send a message (markdown parsing enabled). Mentions are provided via `--mention` with UTF-16 offsets.
  - `--stdin` reads message text from stdin.
  - `--attach` is repeatable. Each attachment is sent as its own message; `--text` is reused as the caption.
  - Folders are zipped before upload. Attachments over 200MB are rejected.
  - `--force-file` uploads photos/videos as files (documents).
  - `--mention` is repeatable and must match the message text (`user_id:offset:length` with UTF-16 units).
- `inline messages edit [--chat-id 123 | --user-id 42] --message-id 456 [--text "updated" | --stdin]`
  - Edit a message by id.
- `inline messages delete [--chat-id 123 | --user-id 42] --message-id 456 [--message-id 789]`
  - Delete one or more messages (prompts for confirmation; use `--yes` to skip).
- `inline messages add-reaction [--chat-id 123 | --user-id 42] --message-id 456 --emoji "👍"`
  - Add an emoji reaction to a message (emoji characters only, no `:shortcode:`).
- `inline messages delete-reaction [--chat-id 123 | --user-id 42] --message-id 456 --emoji "👍"`
  - Remove an emoji reaction from a message (emoji characters only, no `:shortcode:`).
- `inline messages download [--chat-id 123 | --user-id 42] --message-id 456 [--output PATH | --dir PATH]`
  - Download the attachment from a message.

## Examples

- Login and greet user:
  - `inline auth login` (prompts for email/phone + code, then prints welcome name)
- Verify who you are:
  - `inline auth me`
- Check diagnostics:
  - `inline doctor`
- Search messages in a chat:
  - `inline messages search --chat-id 123 --query "design review"`
  - JSON: `inline messages search --chat-id 123 --query "design review" --json`
- Translate and list messages:
  - `inline messages list --chat-id 123 --translate en`
- Export messages to a file:
  - `inline messages export --chat-id 123 --output ./messages.json`
- Send message with multiple attachments:
  - `inline messages send --chat-id 123 --text "FYI" --attach ./photo.jpg --attach ./spec.pdf`
- Reply to a message:
  - `inline messages send --chat-id 123 --reply-to 456 --text "on it"`
- Send a message with a mention entity:
  - `inline messages send --chat-id 123 --text "@Sam hello" --mention 42:0:4`
- Download an attachment:
  - `inline messages download --chat-id 123 --message-id 456 --dir ./downloads`
- Edit and delete a message:
  - `inline messages edit --chat-id 123 --message-id 456 --text "updated"`
  - `inline messages delete --chat-id 123 --message-id 456`
- Invite and manage members:
  - `inline spaces invite --space-id 31 --email you@example.com`
  - `inline spaces update-member-access --space-id 31 --user-id 42 --admin`
- JQ pipelines for lists:
  - `inline users list --json | jq -r '.users[] | "\(.id)\t\(.first_name) \(.last_name)\t@\(.username // "")\t\(.email // "")"'`
  - `inline users list --json | jq -r '.users[] | select((.first_name + " " + (.last_name // "") + " " + (.username // "") + " " + (.email // "")) | ascii_downcase | contains("mo")) | "\(.id)\t\(.first_name) \(.last_name)"'`
- `inline chats list --json | jq -r '.chats[] | "\(.id)\t\(.title // "")\tspace:\(if .space_id == null then "dm" else (.space_id | tostring) end)"'`
- `inline chats list --json | jq -r '.dialogs[] | select(.unread_count > 0) | "\(.chat_id)\tunread:\(.unread_count)"'`
- `inline messages list --chat-id 123 --json | jq -r '.messages[] | "\(.id)\t\(.from_id)\t\((.message // "") | gsub("\n"; " ") | .[0:80])"'`

## Agent Tips

### Finding users quickly

```bash
inline users list | grep -i "partial_name"
```

Faster than parsing JSON when you just need user ID.

### Filtering messages with jq

```bash
# Get last N outgoing messages (your messages)
inline messages list --user-id ID --json | jq '[.messages[] | select(.out == true)] | .[0:3]'

# Get last N incoming messages (their messages)
inline messages list --user-id ID --json | jq '[.messages[] | select(.out == false)] | .[0:3]'
```

### Multi-term search for feedback/bugs

```bash
inline messages search --user-id ID --query "bug" --query "issue" --query "loom" --query "broken" --limit 30 --json
```

Each --query is ORed together - useful for finding feedback items.

### Common patterns

- Use --user-id for DMs instead of looking up chat IDs
- Use --json + jq for programmatic filtering
- Use default (non-JSON) mode for quick human-readable output

### More quick tips

```bash
# Page back with offset-id
inline messages list --chat-id ID --limit 50 --offset-id 1234

# Get the latest message id
inline messages list --chat-id ID --limit 1 --json | jq '.messages[0].id'

# Export a batch for offline review
inline messages export --chat-id ID --limit 500 --output ./chat.json

# Compact JSON for pipelines
inline messages list --chat-id ID --json --compact | jq '.messages | length'
```

## JSON samples

Chat list (GetChatsResult, truncated to essential fields):

```
{
  "dialogs": [
    {
      "peer": { "type": { "Chat": { "chat_id": 340 } } },
      "space_id": 31,
      "archived": false,
      "pinned": false,
      "read_max_id": 1,
      "unread_count": 0,
      "chat_id": 340,
      "unread_mark": false
    }
  ],
  "chats": [
    {
      "id": 340,
      "title": "Main",
      "space_id": 31,
      "description": "Main chat for everyone in the space",
      "emoji": null,
      "is_public": true,
      "last_msg_id": 1,
      "peer_id": { "type": { "Chat": { "chat_id": 340 } } },
      "date": 1754585453
    }
  ],
  "spaces": [
    { "id": 31, "name": "Design", "creator": false, "date": 1750000000 }
  ],
  "users": [
    {
      "id": 1000,
      "first_name": "Ava",
      "last_name": "Chen",
      "username": "ava",
      "email": "ava@example.com",
      "min": false,
      "bot": false
    }
  ],
  "messages": [
    {
      "id": 1,
      "from_id": 1000,
      "peer_id": { "type": { "Chat": { "chat_id": 340 } } },
      "chat_id": 340,
      "message": null,
      "out": true,
      "date": 1754585453,
      "media": {
        "media": {
          "Document": {
            "document": {
              "id": 32,
              "file_name": "recording.mp4",
              "mime_type": "video/mp4",
              "size": 6932635,
              "cdn_url": "https://..."
            }
          }
        }
      }
    }
  ]
}
```

Message list (GetChatHistoryResult, truncated to essential fields):

```
{
  "messages": [
    {
      "id": 456,
      "from_id": 42,
      "peer_id": { "type": { "Chat": { "chat_id": 123 } } },
      "chat_id": 123,
      "message": "Ship it",
      "out": true,
      "date": 1733184000,
      "attachments": {
        "attachments": [
          {
            "id": 9001,
            "attachment": {
              "UrlPreview": {
                "id": 88,
                "url": "https://...",
                "site_name": "Docs",
                "title": "Spec",
                "description": "API rollout spec"
              }
            }
          }
        ]
      }
    }
  ]
}
```
