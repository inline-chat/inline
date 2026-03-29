# @inline-openclaw/inline

OpenClaw channel plugin for interacting with an OpenClaw agent via **Inline**.

Status: **beta** (solid foundation; expect iteration).

Quick setup guide: `docs/openclaw-setup.md`.
Create bot/token guide: `docs/create-inline-bot.md`.

Supports:

- Inline DMs (`ChatType=direct`)
- Inline chats as conversations (`ChatType=group`)
- Message replies: OpenClaw `replyToId` is mapped to Inline `replyToMsgId` (message id).
- Optional native reply threads: enable `channels.inline.capabilities.replyThreads: true` to expose Inline reply-thread chats as OpenClaw threads.
- Native media upload/send for images, videos, and documents from `mediaUrl` payloads.
- Emoji reactions via message tool actions (`react`, `reactions`).
- Reaction events on bot-authored messages are surfaced back to the agent as inbound context.

By default, native reply threads stay off to preserve the old compatibility behavior. When disabled:

- `replyToId` remains an Inline message reply only.
- `thread-reply` keeps the legacy compatibility path.
- `thread-create` keeps the legacy chat-creation alias behavior.

When enabled:

- inbound reply-thread messages use the parent chat as the base conversation target and the child reply-thread chat id as `MessageThreadId`
- outbound `thread-reply` sends into the child reply-thread chat
- `thread-create` creates a real Inline reply thread instead of a plain chat alias

## Install

Requires OpenClaw `2026.2.9` or newer.

From npm (once published):

```sh
openclaw plugins install @inline-openclaw/inline
```

If the plugin is already installed, update in place:

```sh
openclaw config set plugins.installs.inline.spec '"@inline-openclaw/inline@latest"'
openclaw plugins update inline
```

From a local checkout (dev):

```sh
cd /path/to/inline/packages/openclaw-inline
bun run build
openclaw plugins install --link /path/to/inline/packages/openclaw-inline
```

## Configure

Channel config lives under `channels.inline` (supports account settings, block streaming/chunking, and group tool policy).

Plugin id is `inline` (for `plugins.entries.*`).
If you enable explicitly, use:

```yaml
plugins:
  entries:
    inline:
      enabled: true
```

Minimal setup (token field only):

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

`baseUrl` defaults to `https://api.inline.chat`.
`dmPolicy` defaults to `pairing` (recommended starting point).
`requireMention` defaults to `false` for groups (set `true` to require explicit mentions).

Example:

```yaml
channels:
  inline:
    enabled: true
    baseUrl: "https://api.inline.chat"
    token: "<INLINE_BOT_TOKEN>"

    # DMs:
    dmPolicy: "pairing" # pairing|open|disabled
    allowFrom:
      - "inline:123" # or "user:123" or just "123"

    # Group threads/chats:
    groupPolicy: "allowlist" # allowlist|open|disabled
    groupAllowFrom:
      - "inline:123" # or "user:123" or just "123"
    capabilities:
      replyThreads: false # optional, default false; enable native Inline reply-thread support
    requireMention: true # optional: default is false
    replyToBotWithoutMention: true # if true, replies to bot messages can bypass mention requirement

    # Inbound context history (used to build richer thread context for the agent):
    historyLimit: 50      # group chats
    dmHistoryLimit: 6     # direct messages

    # Streaming + chunking:
    mediaMaxMb: 20
    blockStreaming: true
    streamViaEditMessage: true # optional: paragraph-level text streaming via send+edit fallback; off by default
    chunkMode: "newline" # length|newline
    blockStreamingCoalesce:
      minChars: 600
      idleMs: 700
      maxChars: 2200

    # Group-level tool policy (for agent tool access in group sessions):
    groups:
      "88":
        requireMention: false
        tools:
          allow: ["message", "web.search"]
        toolsBySender:
          "42":
            allow: ["message"]
```

Per-account override:

```yaml
channels:
  inline:
    capabilities:
      replyThreads: false
    accounts:
      work:
        token: "<INLINE_BOT_TOKEN>"
        capabilities:
          replyThreads: true
```

Reply behavior summary:

- `replyToId` is always an Inline message id.
- Native reply threads are separate and use OpenClaw `threadId`.
- Keep `replyThreads` off if you only want classic message replies.

If you set `dmPolicy: "open"`, set `allowFrom: ["*"]`.

## Outbound Target Semantics

For `message send`/plugin outbound sends:

- `chat:<id>` targets a chat id.
- `user:<id>` targets a user id (DM peer).
- `inline:user:<id>` and `inline:chat:<id>` are accepted and normalized.
- User directory IDs and `channels resolve --kind user` outputs are returned as `user:<id>` to keep DM targets explicit.
- Bare numeric ids are disambiguated against Inline directory data:
  - matches chat only -> sent as chat id
  - matches user only -> sent as user id
  - matches both -> rejected (use explicit `chat:` or `user:`)
  - matches neither -> treated as chat id (legacy behavior)

## Message Tool RPC Actions

The plugin exposes Inline RPC-backed actions through OpenClaw's `message` tool.
Most Inline RPC-backed actions use a numeric chat id via `to`, `chatId`, or `channelId`.
Direct DM sends can also target `user:<id>`.

- Sending: `send`, `sendAttachment`
- Replying: `reply`, `thread-reply`
- Reactions: `react`, `reactions`
- Reading/searching: `read`, `search`
- Editing: `edit`
- Channels/threads: `channel-info`, `channel-edit`, `renameGroup`, `channel-list`, `channel-create`, `channel-delete`, `channel-move`, `thread-list`, `thread-create`
- Participants: `addParticipant`, `removeParticipant`, `kick`, `leaveGroup`, `member-info`
- Message lifecycle: `delete`, `unsend`
- Pins: `pin`, `unpin`, `list-pins`
- Space permissions: `permissions`

Native thread semantics are behind `channels.inline.capabilities.replyThreads`:

- disabled: `thread-reply` behaves like the old compatibility reply path
- enabled: `thread-reply` expects `threadId` to be the child reply-thread chat id, while `to` stays the parent chat id
- enabled: `thread-create` creates a real reply thread from a parent chat and optional `replyToId` anchor

You can gate action groups from config:

```yaml
channels:
  inline:
    actions:
      send: true
      reply: true
      reactions: true
      read: true
      search: true
      edit: true
      channels: true
      participants: true
      delete: true
      pins: true
      permissions: true
```

## Extra Agent Tools

The plugin also registers a dedicated `inline_members` tool for space-member discovery outside the `message` action surface.

- Required input: `spaceId`
- Optional filters: `query`, `userId`, `limit`, `accountId`
- Returned members include explicit DM targets like `user:123`

The plugin also registers `inline_bot_commands` for bot slash command management (v1):

- `action: "get"` -> calls `getMyCommands`
- `action: "set"` -> calls `setMyCommands` with Telegram-style `commands[]`
- `action: "delete"` -> calls `deleteMyCommands`
- Limits follow Inline Bot API: max `100` commands, `command` max `32`, `description` max `256`, charset `^[a-z0-9_]+$`

Native command sync (Telegram-style startup behavior):

- On `gateway_start`, the plugin clears + re-registers default native commands for each enabled/configured Inline account.
- Default commands now mirror OpenClaw native defaults (for example: `/status`, `/model`, `/exec`, `/usage`, etc.).
- When available in `openclaw/plugin-sdk`, the plugin uses the same command + skill sources as native providers (Telegram/Slack/Discord), including plugin command specs.
- Disable startup sync globally with `commands.native: false`, or per-channel with `channels.inline.commands.native: false`.
- Disable native skill command inclusion with `commands.nativeSkills: false`, or per-channel with `channels.inline.commands.nativeSkills: false`.

Multi-account:

```yaml
channels:
  inline:
    accounts:
      default:
        baseUrl: "https://api.inline.chat"
        token: "<BOT_TOKEN_A>"
      work:
        baseUrl: "https://api.inline.chat"
        token: "<BOT_TOKEN_B>"
```

## Quick Troubleshooting

- `plugin not found: inline` / `plugins.entries.inline: plugin not found: inline`
  - Ensure the plugin is installed and discovered (`openclaw plugins list`).
- `doctor --fix` suggests Inline changes even though channel is healthy
  - Plugin entry id should be `inline`.
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token` is set and plugin is updated (`openclaw plugins update inline`).
  - If using `dmPolicy: "open"`, ensure `allowFrom: ["*"]`.
