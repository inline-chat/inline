# @inline-openclaw/inline

OpenClaw channel plugin for interacting with an OpenClaw agent via **Inline**.

Status: **beta** (solid foundation; expect iteration).

Quick setup guide: `docs/openclaw-setup.md`.
Create bot/token guide: `docs/create-inline-bot.md`.

Supports:

- Inline DMs (`ChatType=direct`)
- Inline chats (including top-level thread-style chats) as conversations (`ChatType=group`)
- Message replies: OpenClaw `replyToId` is mapped to Inline `replyToMsgId` (message id).
- Native media upload/send for images, videos, and documents from `mediaUrl` payloads.
- Emoji reactions via message tool actions (`react`, `reactions`).
- Reaction events on bot-authored messages are surfaced back to the agent as inbound context.

Non-goals (for now):

- Subthreads: Inline “replyTo” is a message reply, not a thread identifier. We do not expose OpenClaw subthread mode yet (`capabilities.threads=false`).

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
    requireMention: true # optional: default is false
    replyToBotWithoutMention: true # if true, replies to bot messages can bypass mention requirement

    # Inbound context history (used to build richer thread context for the agent):
    historyLimit: 12      # group chats
    dmHistoryLimit: 6     # direct messages

    # Streaming + chunking:
    mediaMaxMb: 20
    blockStreaming: true
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

If you set `dmPolicy: "open"`, set `allowFrom: ["*"]`.

## Message Tool RPC Actions

The plugin exposes Inline RPC-backed actions through OpenClaw's `message` tool.
All actions use a numeric Inline chat id via `to`, `chatId`, or `channelId`.

- Replying: `reply`, `thread-reply`
- Reactions: `react`, `reactions`
- Reading/searching: `read`, `search`
- Editing: `edit`
- Channels/threads: `channel-info`, `channel-edit`, `channel-list`, `channel-create`, `channel-delete`, `channel-move`, `thread-list`, `thread-create`
- Participants: `addParticipant`, `removeParticipant`, `leaveGroup`, `member-info`
- Message lifecycle: `delete`, `unsend`
- Pins: `pin`, `unpin`, `list-pins`
- Space permissions: `permissions`

You can gate action groups from config:

```yaml
channels:
  inline:
    actions:
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
