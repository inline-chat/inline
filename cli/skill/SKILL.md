---
name: inline-cli
description: Explain and use the Inline CLI (`inline`) for authentication, chats, users, spaces, messages, search, bots, typing, notifications, tasks, schema, attachments, downloads, JSON output, and configuration. Use when asked how to use the Inline CLI or its commands, flags, outputs, or workflows.
---

# Inline CLI

## Global flags

- `--json`: Output raw JSON payloads (proto/RPC results) to stdout (available on all commands).
  - When `--json` is set and a command fails, the CLI prints a structured error JSON to stderr and exits non-zero. Common fields are `code`, `message`, `status`, `apiError`, `apiErrorCode`, `body`, `hint`, and `examples`.
  - Table-only convenience flags are disabled in `--json` mode. Specifically: `inline users list --ids/--id`, `inline bots list --ids/--id`, and `inline chats list --ids/--id`.
  - `inline chats list --json` supports `--filter`, `--limit`, and `--offset` for pre-filtered/paginated payloads. `inline users list --json --filter ...` and `inline bots list --json --filter ...` also return pre-filtered payloads.
  - Destructive commands never prompt in `--json` mode; pass `--yes`/`-y` explicitly.
- `--pretty`: Pretty-print JSON output (default).
- `--compact`: Compact JSON output (no whitespace).

## Output behavior

- Use `--json --compact` for pipelines and agent parsing.
- Human table output adapts to terminal width through the `COLUMNS` environment variable. Set `COLUMNS=120` before a command to allow wider previews, or a smaller value to force denser truncation.
- `inline chats list` gives chat titles extra room and wraps long titles onto a second table row before truncating, so prefer the normal table before falling back to JSON for title disambiguation.
- Non-JSON runtime errors print a short human report with `Error`, `Code`, and any available status/API error/body preview/hint/examples.
- Color is only used on TTY stdout/stderr by default. Set `NO_COLOR=1` to disable it, or `CLICOLOR_FORCE=1` to force it in a non-TTY.

## Subcommands

### auth

- `inline login [--email you@x.com | --phone +15551234567]`
  - Shortcut for `inline auth login`.
  - Run an interactive login flow.
  - Requires an interactive terminal. In agent/CI/non-interactive flows, use an existing token via `INLINE_TOKEN`.
  - If code is wrong, prompt to try again or edit email/phone (no hard exit).
- `inline me`
  - Shortcut for `inline auth me`.
  - Fetch and print the current user (verifies your token is still valid).
- `inline logout`
  - Shortcut for `inline auth logout`.
  - Clear the stored token and current user.
  - If `INLINE_TOKEN` is set, the CLI remains authenticated from the environment; JSON output reports this as `effectiveTokenSource: "INLINE_TOKEN"`.

### shortcuts and aliases

- `inline me` and `inline whoami`
  - Shortcut for `inline auth me`.
- `inline login`
  - Shortcut for `inline auth login`.
- `inline logout`
  - Shortcut for `inline auth logout`.
- `inline search ...`
  - Shortcut for `inline messages search ...`.
  - Supports the same message search filters, including `--translate`.
- `inline transcript ...`
  - Shortcut for `inline messages transcript ...`.
  - Preferred starting point for long thread review, summarization, and Notion-friendly pasteable transcripts.
  - For media-heavy chats, use `inline transcript --chat-id ID --limit 500 --download-media --output ./transcript-bundle` so the CLI writes `transcript.md` plus local media links in `media/`.
- `inline chat ...`, `inline thread ...`, `inline threads ...`
  - Aliases for `inline chats ...`.
- `inline bot ...`
  - Alias for `inline bots ...`.

### chats

- `inline chats list`
  - List chats with human-readable names, unread count, and last message preview (sender + text in one column).
- `inline chats list --json --filter "launch"`
  - Same `GetChatsResult` JSON payload, but pre-filtered by chat name/space/id for agent pipelines.
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
- `inline chats update-visibility --chat-id 123 [--public | --private --participant 42 --participant 99]`
  - Change a chat between public/private.
  - `--public` cannot include participants.
  - `--private` requires one or more `--participant` values.
- `inline chats rename --chat-id 123 --title "New title" [--emoji "🚀"]`
  - Rename a chat or thread.
- `inline chats mark-unread [--chat-id 123 | --user-id 42]`
  - Mark a chat or DM as unread.
- `inline chats mark-read [--chat-id 123 | --user-id 42] [--max-id 456]`
  - Mark a chat or DM as read. If `--max-id` is omitted, marks through the latest message.
- `inline chats delete --chat-id 123`
  - Delete a chat (space thread). Prompts for confirmation unless `--yes`/`-y` is provided (`--json` requires `--yes`/`-y`).

### bots

- Alias: `inline bot ...` maps to `inline bots ...`.
- `inline bots list [--filter "name"] [--ids | --id]`
  - List bots you can access.
  - `--filter` works in table and JSON modes. `--ids`/`--id` are table-only line-output helpers.
- `inline bots create --name "Build Bot" --username build_bot [--add-to-space 31]`
  - Create a bot. Token is not printed in table output; use `inline bots reveal-token` explicitly. JSON includes the token.
- `inline bots reveal-token --bot-user-id 42`
  - Print (or JSON-return) an existing bot token by bot user id.

### typing

- `inline typing start [--chat-id 123 | --user-id 42]`
  - Send a "typing" compose action.
- `inline typing stop [--chat-id 123 | --user-id 42]`
  - Clear the compose action (stop typing).

### users

- `inline users list [--filter "name"] [--ids | --id]`
  - List users that appear in your chats (derived from getChats).
  - `--filter` matches name, username, email, or phone in table and JSON modes.
  - `--ids` prints one user id per line.
  - `--id` requires exactly one match and prints that id.
  - `--ids`/`--id` are table-only line-output helpers.
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
  - Remove a member from a space (prompts for confirmation; use `--yes`/`-y` to skip; `--json` requires `--yes`/`-y`).
- `inline spaces update-member-access --space-id 31 --user-id 42 [--admin | --member] [--public-chats]`
  - Update a member's access/role. Provide `--admin` or `--member` (and optional `--public-chats`).

### notifications

- `inline notifications get`
  - Show current notification settings.
- `inline notifications set [--mode all|none|mentions|only-mentions|important] [--silent | --sound]`
  - Update notification settings.

### update

- `inline update`
  - Download and install the latest release for this machine.

### doctor

- `inline doctor`
  - Print diagnostic info (system, config, paths, auth state).
  - `--json` includes client identity diagnostics: client type/version, user-agent, OS version, device name, and metadata header names sent to the server.

### tasks

- `inline tasks create-linear --chat-id 123 --message-id 456 [--space-id 31]`
  - Create a Linear issue from a message.
- `inline tasks create-notion --chat-id 123 --message-id 456 --space-id 31`
  - Create a Notion task from a message.

### schema

- `inline schema proto`
  - Print bundled protobuf source files.

### messages

- `inline messages list [--chat-id 123 | --user-id 42] [--limit 50] [--offset-id 456] [--has-media] [--empty-text] [--forwarded] [--translate en] [--since "yesterday"] [--until "today"]`
  - List chat history for a chat or DM.
  - `--has-media`, `--empty-text`, and `--forwarded` can be combined and work in table or JSON mode.
  - `--translate <lang>` fetches translations and includes them in output.
- `inline messages transcript [--chat-id 123 | --user-id 42] [--limit 500] [--offset-id 456 | --from-msg-id 456 | --message-id SELECTOR ...] [--output PATH]`
  - Export a clean markdown transcript for reading, summarizing, or pasting into Notion.
  - Root shortcut: `inline transcript ...`.
  - Transcript output keeps metadata minimal: sender, sparse timestamps, content, natural reply/forward context, media/file links, an Open in Inline link, and hidden `MSG` comments.
  - Markdown media links use CDN URLs by default. Add `--download-media [--media-dir DIR] [--parallel N]` to download photos/files in one pass and rewrite transcript links to local paths.
  - If `--output` is a directory, or a no-extension path with `--download-media`, transcript writes `transcript.md` and uses `media/` inside that directory.
  - Messages without downloadable media are skipped during media download; failed media downloads are reported without failing the whole export.
- `inline messages export [--chat-id 123 | --user-id 42] [--limit 50] [--offset-id 456 | --from-msg-id 456 | --message-id SELECTOR ...] [--format json|jsonl|markdown|csv] [--since "1w ago"] [--until "today"] [--output PATH]`
  - Export chat history or exact message IDs to JSON, JSONL, markdown, or CSV.
  - If `--output` is omitted, payload content prints to stdout.
  - Add `--download-media [--media-dir DIR] [--parallel N]` to populate media `localPath` values; markdown and CSV include those local paths.
  - If `--output` is a directory, or a no-extension path with `--download-media`, export writes `transcript.<format>` there and defaults media to `media/`.
  - JSON exports include top-level `users`, `chats`, and `spaces` records so agents do not need jq joins for common sender/source names.
- `inline messages search [--chat-id 123 | --user-id 42] --query "onboarding" [--query "alpha beta"] [--limit 50] [--translate en] [--since "today"] [--until "tomorrow"]`
  - Search messages in a chat or DM.
  - `--query` is repeatable; each query can contain space-separated terms (ANDed within a query, ORed across queries). Extra whitespace is collapsed.
  - `--since` and `--until` accept relative time expressions like `yesterday`, `2h ago`, `monday`, `2024-01-15`, or RFC3339.
  - With `--translate`, JSON output keeps raw search fields and adds a top-level `translations` array; table output includes translated previews.
- `inline messages get [--chat-id 123 | --user-id 42] --message-id SELECTOR [--message-id SELECTOR ...] [--translate en]`
  - Fetch one or more full messages from a chat or DM (includes media + attachments).
  - Selectors support single IDs (`456`), comma lists (`91,92,100`), ranges (`91-100`), and repeated flags.
  - Single-ID output keeps the detailed message view. Multiple IDs print a compact table, or JSON with `messages` and any `missingMessageIds`.
- `inline messages send [--chat-id 123 | --user-id 42] [--text "hi" | --message "hi" | --msg "hi" | -m "hi"] [--stdin] [--reply-to 456] [--mention USER_ID:OFFSET:LENGTH ...] [--attach PATH ...] [--force-file]`
  - Send a message (markdown parsing enabled). Mentions are provided via `--mention` with UTF-16 offsets.
  - `--stdin` reads message text from piped or redirected stdin; it fails fast if stdin is an interactive terminal.
  - `--attach` is repeatable. Each attachment is sent as its own message; `--text` is reused as the caption.
  - Folders are zipped before upload. Attachments over 200MB are rejected.
  - `--force-file` uploads photos/videos as files (documents).
  - `--mention` is repeatable and must match the message text (`user_id:offset:length` with UTF-16 units).
- `inline messages forward [--from-chat-id 123 | --from-user-id 42] --message-id 456 [--message-id 789] [--to-chat-id 321 | --to-user-id 84] [--no-header]`
  - Forward one or more messages between chats or DMs.
  - Repeat `--message-id` to forward multiple messages.
- `inline messages edit [--chat-id 123 | --user-id 42] --message-id 456 [--text "updated" | --message "updated" | --msg "updated" | -m "updated" | --stdin]`
  - Edit a message by id.
  - `--stdin` expects piped or redirected stdin, not an interactive prompt.
- `inline messages delete [--chat-id 123 | --user-id 42] --message-id 456 [--message-id 789]`
  - Delete one or more messages (prompts for confirmation; use `--yes`/`-y` to skip; `--json` requires `--yes`/`-y`).
- `inline messages add-reaction [--chat-id 123 | --user-id 42] --message-id 456 --emoji "👍"`
  - Add an emoji reaction to a message (emoji characters only, no `:shortcode:`).
- `inline messages delete-reaction [--chat-id 123 | --user-id 42] --message-id 456 --emoji "👍"`
  - Remove an emoji reaction from a message (emoji characters only, no `:shortcode:`).
- `inline messages download [--chat-id 123 | --user-id 42] [--message-id SELECTOR ... | --from-msg-id 456 --limit 50] [--output PATH | --dir PATH] [--parallel 8]`
  - Download media from one or more messages.
  - Single-ID downloads may use `--output` or `--dir`.
  - Batch downloads require `--dir`, use bounded concurrency, skip messages without media, and prefix filenames with date, `MSG` ID, media type, and media ID.
  - Use `--from-msg-id ID --limit N --dir DIR` to download media from a contiguous history window without enumerating IDs.
  - Human output reports downloaded, skipped, missing, and failed counts; JSON output includes `files`, `skippedMessageIds`, `missingMessageIds`, and `errors`.

## Examples

- Login and greet user:
  - `inline login` (prompts for email/phone + code, then prints welcome name)
- Verify who you are:
  - `inline me`
- Log out:
  - `inline logout`
- Check diagnostics:
  - `inline doctor`
- List chats/threads:
  - `inline chats list`
  - Alias: `inline thread list`
- Update chat visibility:
  - `inline chats update-visibility --chat-id 123 --public`
  - `inline chats update-visibility --chat-id 123 --private --participant 42 --participant 99`
- Search messages in a chat:
  - `inline messages search --chat-id 123 --query "design review"`
  - JSON: `inline messages search --chat-id 123 --query "design review" --json`
  - Translated JSON: `inline messages search --chat-id 123 --query "diseño" --translate en --json`
  - Shortcut: `inline search --chat-id 123 --query "design review"`
- Translate and list messages:
  - `inline messages list --chat-id 123 --translate en`
- Filter messages by time:
  - `inline messages list --chat-id 123 --since "yesterday"`
  - `inline messages list --chat-id 123 --since "2h ago" --until "1h ago"`
- Export messages to a file:
  - `inline transcript --chat-id 123 --limit 500 --download-media --output ./feedback-bundle`
  - `inline transcript --chat-id 123 --from-msg-id 600 --limit 50 --download-media --output ./feedback-bundle`
  - `inline transcript --chat-id 123 --limit 500 --download-media --media-dir ./feedback-media --output ./feedback.md`
  - `inline messages export --chat-id 123 --output ./messages.json`
  - `inline messages export --chat-id 123 --format markdown --output ./messages.md`
  - `inline messages export --chat-id 123 --format csv --output ./messages.csv`
  - `inline messages export --chat-id 123 --since "1w ago" --output ./recent.json`
- Send message with multiple attachments:
  - `inline messages send --chat-id 123 --text "FYI" --attach ./photo.jpg --attach ./spec.pdf`
- Reply to a message:
  - `inline messages send --chat-id 123 --reply-to 456 --text "on it"`
- Forward a message:
  - `inline messages forward --from-chat-id 123 --message-id 456 --to-chat-id 789`
  - `inline messages forward --from-user-id 42 --message-id 456 --to-user-id 84`
- Send a message with a mention entity:
  - `inline messages send --chat-id 123 --text "@Sam hello" --mention 42:0:4`
- Download an attachment:
  - `inline messages download --chat-id 123 --message-id 456 --dir ./downloads`
  - `inline messages download --chat-id 123 --message-id 80-100 --dir ./downloads`
- Rename a thread:
  - `inline chats rename --chat-id 123 --title "New title"`
- Bots:
  - `inline bots list`
  - `inline bots create --name "Build Bot" --username build_bot`
  - `inline bots reveal-token --bot-user-id 42` (token is not printed by default)
- Tasks:
  - `inline tasks create-linear --chat-id 123 --message-id 456`
  - `inline tasks create-notion --chat-id 123 --message-id 456 --space-id 31`
- Typing:
  - `inline typing start --chat-id 123`
  - `inline typing stop --chat-id 123`
- Edit and delete a message:
  - `inline messages edit --chat-id 123 --message-id 456 --text "updated"`
  - `inline messages delete --chat-id 123 --message-id 456`
- Invite and manage members:
  - `inline spaces invite --space-id 31 --email you@example.com`
  - `inline spaces update-member-access --space-id 31 --user-id 42 --admin`

## Agent Tips

### Finding users quickly

```bash
inline users list | grep -i "partial_name"
```

Faster than parsing JSON when you just need user ID.

### DM: review recent messages and download known media

```bash
# Find the DM user id by name/email/username
USER_ID="$(inline users list --filter "sam" --id)"

# Read the last 5 messages
inline messages list --user-id "$USER_ID" --limit 5 --json --compact

# Fetch exact messages once you know their IDs
inline messages get --user-id "$USER_ID" --message-id 91,92,100 --json

# Download several media messages at once
inline messages download --user-id "$USER_ID" --message-id 80-100 --dir ./downloads
```

### Batch message selectors

```bash
inline messages get --chat-id ID --message-id 1
inline messages get --chat-id ID --message-id 1,2,4 --json
inline messages get --chat-id ID --message-id 10-20 --json
inline messages download --chat-id ID --message-id 10-20 --dir ./media --parallel 8
inline messages download --chat-id ID --from-msg-id 600 --limit 50 --dir ./media --parallel 8
```

### Multi-term search for feedback/bugs

```bash
inline messages search --user-id ID --query "bug" --query "issue" --query "loom" --query "broken" --limit 30 --json
```

Each --query is ORed together - useful for finding feedback items.

### Common patterns

- Use --user-id for DMs instead of looking up chat IDs
- For long thread review/summarization, start with `inline transcript --chat-id ID --limit 500 --download-media --output ./transcript-bundle` when media might matter
- Prefer built-in filters, selectors, and export commands before shell pipelines
- Use default (non-JSON) mode for quick human-readable output
- Use jq only for advanced ad hoc JSON analysis, not for basic joins, media loops, or transcript reconstruction

### More quick tips

```bash
# Page back with offset-id
inline messages list --chat-id ID --limit 50 --offset-id 1234

# Get the latest message id from the first table row
inline messages list --chat-id ID --limit 1

# Export a batch for offline review
inline transcript --chat-id ID --limit 500 --download-media --output ./chat-bundle
inline transcript --chat-id ID --from-msg-id 600 --limit 50 --download-media --output ./chat-bundle
inline messages export --chat-id ID --limit 500 --output ./chat.json

# Fetch exact IDs in one request
inline messages get --chat-id ID --message-id 91,92,100 --json --compact
```

### Advanced JSON pipelines

```bash
# Count fetched messages
inline messages list --chat-id ID --limit 500 --json --compact | jq '.messages | length'

# Extract media message IDs for custom workflows
inline messages list --chat-id ID --limit 500 --has-media --json --compact | jq -r '.messages[].id'
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
