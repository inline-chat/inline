# @inline-openclaw/inline

OpenClaw channel plugin for interacting with an OpenClaw agent via **Inline**.

Status: **beta** (solid foundation; expect iteration).

Quick setup guide: `docs/openclaw-setup.md`.
Create bot/token guide: `docs/create-inline-bot.md`.

Supports:

- Inline DMs (`ChatType=direct`)
- Inline chats as conversations (`ChatType=group`)
- Message replies: OpenClaw `replyToId` is mapped to Inline `replyToMsgId` (message id).
- Inline reply threads: tools can create and reply in real Inline reply-thread chats.
- Inline media upload/send for images, videos, and documents from `mediaUrl` payloads.
- Emoji reactions via message tool actions (`react`, `reactions`).
- Reaction events on bot-authored messages are surfaced back to the agent as inbound context.

Reply-thread behavior:

- Small/new parent-chat conversations stay in the parent chat by default.
- `replyThreadMode: "thread"` opts a parent chat into automatic reply-thread delivery once `replyThreadAutoCreateMinMessages` is reached; each triggering parent-chat message gets its own child reply thread.
- `replyThreadMode: "main"` keeps automatic replies in the parent chat, while explicit `thread-create` and `thread-reply` tools remain available.
- `thread-create` creates a real Inline reply thread. `thread-reply` sends into the child reply-thread chat id returned by `thread-create`.
- Inbound reply-thread messages use the parent chat as the base conversation target and the child reply-thread chat id as `MessageThreadId`.
- Bot-participated reply threads can continue without an explicit bot mention by default, matching Slack-style thread behavior.

## Install

Requires OpenClaw `2026.5.28` or newer.

From npm (once published):

```sh
openclaw plugins install @inline-openclaw/inline
```

If the plugin is already installed, update in place:

```sh
openclaw config set plugins.installs.inline.spec '"@inline-openclaw/inline@latest"'
openclaw plugins update inline
openclaw gateway restart
openclaw plugins list
openclaw channels status
openclaw message send --channel inline --target chat:123 --message "Inline smoke test" --dry-run
```

After updating, verify that `openclaw plugins list` shows `inline`, `openclaw channels status` reports Inline configured/running, and `openclaw plugins inspect inline --json` reports the expected package version.

From a local checkout (dev):

```sh
cd /path/to/inline/packages/openclaw
bun run build
npm pack --ignore-scripts --pack-destination /tmp
openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-<version>.tgz
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

You can also leave `token` unset and provide `INLINE_TOKEN` in the gateway environment.
`INLINE_BOT_TOKEN` is accepted as a compatibility alias.

`baseUrl` defaults to `https://api.inline.chat`.
`dmPolicy` defaults to `pairing` (recommended starting point).
`defaultTo` is optional and gives outbound sends a fallback target when no explicit target is supplied.
`requireMention` defaults to `false` for groups (set `true` to require explicit mentions).

### Who can talk to the bot?

Use these settings together:

| Area | Setting | Meaning |
| --- | --- | --- |
| DMs | `dmPolicy: "pairing"` | Users can request access; allowlisted users are accepted. This is the default. |
| DMs | `dmPolicy: "allowlist"` + `allowFrom` | Only listed Inline user ids can DM the bot. |
| DMs | `dmPolicy: "open"` + `allowFrom: ["*"]` | Any Inline user can DM the bot. Use only for public/demo bots. |
| DMs | `dmPolicy: "disabled"` | DM messages are ignored. |
| Groups | `groupPolicy: "allowlist"` + `groups` | Only listed group chat ids can reach the bot. Setup defaults `groups["*"].requireMention` to `true` for broad mention-only access. |
| Groups | `groupPolicy: "open"` | Any group chat can reach the bot. Pair with `requireMention: true` unless the bot should answer ambient messages. |
| Groups | `groupPolicy: "disabled"` | Group messages are ignored. |
| Group senders | `groupAllowFrom` or `groups.<chat>.allowFrom` | Optional sender allowlist inside allowed groups. Per-group entries override the account-wide list for that group. Leave empty to allow any sender in an allowed group. |

Accepted Inline user ids: `123`, `user:123`, `inline:123`, or `inline:user:123`.
Accepted group ids: `123`, `chat:123`, `inline:123`, or `*`.

Example:

```yaml
channels:
  inline:
    enabled: true
    baseUrl: "https://api.inline.chat"
    token: "<INLINE_BOT_TOKEN>"
    defaultTo: "chat:123" # optional fallback for outbound sends without --target

    # DMs:
    dmPolicy: "pairing" # pairing|allowlist|open|disabled
    allowFrom:
      - "inline:123" # or "user:123" or just "123"

    # Native exec/plugin approvals:
    execApprovals:
      enabled: "auto" # auto|true|false
      approvers:
        - "user:123" # Inline user ids only; chat ids are not approvers
      target: "dm" # dm|channel|both

    # Group threads/chats:
    groupPolicy: "allowlist" # allowlist|open|disabled
    groupAllowFrom:
      - "inline:123" # or "user:123" or just "123"
    requireMention: true # optional: default is false
    replyToBotWithoutMention: true # if true, replies to bot messages can bypass mention requirement
    replyThreadMode: "auto" # auto|thread|main; thread auto-routes long parent-chat replies into per-message reply threads
    replyThreadAutoCreateMinMessages: 50 # optional, default 50; avoids creating reply threads for small/new chats
    replyThreadRequireExplicitMention: false # optional, default false; bot-participated reply threads continue without @mention
    replyThreadParentHistoryLimit: 10 # optional, default 10; set 0 to disable parent-chat context before the anchor

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
        replyThreadRequireExplicitMention: true
        replyThreadParentHistoryLimit: 2
        allowFrom:
          - "42"
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
    accounts:
      work:
        token: "<INLINE_BOT_TOKEN>"
        defaultTo: "user:123"
        replyThreadMode: "main"
```

Reply behavior summary:

- `replyToId` is always an Inline message id.
- Inline reply threads are separate and use OpenClaw `threadId`.
- Use `replyThreadMode: "main"` if you only want automatic parent-chat replies to stay in the parent chat.
- Use `replyThreadMode: "thread"` plus `replyThreadAutoCreateMinMessages` when parent-chat bot turns should move into child reply threads anchored to the triggering parent messages.
- In an Inline group, authorized users can run `/threadreply` to choose the chat's mode with buttons, or `/threadreply thread|main|auto|inherit|status`.
- Bot-participated reply threads continue without `@bot` by default, including from persisted recent participation state. Set `replyThreadRequireExplicitMention: true` if a chat should require `@bot` on every reply-thread message.
- `replyThreadParentHistoryLimit` defaults to `10`, so reply-thread turns include nearby parent-chat context before the anchor. Set it to `0` only when a chat should stay strictly thread-local.

If you set `dmPolicy: "open"`, set `allowFrom: ["*"]`.

## Native Exec Approvals

Inline supports the same native approval flow as bundled chat providers. Configure `channels.inline.execApprovals.approvers` with Inline user ids, or leave it unset and use numeric IDs in `commands.ownerAllowFrom`. Accepted approver ids are `123`, `user:123`, `inline:123`, or `inline:user:123`; `chat:<id>` entries are ignored because group chats are not approvers.

`execApprovals.target` defaults to `dm`. Use `channel` or `both` only for trusted chats because approval messages include command details. Inline approval buttons send `/approve ...` callbacks, and OpenClaw clears the buttons after resolution or expiry.

## Outbound Target Semantics

For `message send`/plugin outbound sends:

- Use `openclaw message send --channel inline --target chat:<id> --message "..."`.
- If `channels.inline.defaultTo` is set, OpenClaw uses it when no explicit target is supplied. Named accounts can override it with `channels.inline.accounts.<account>.defaultTo`.
- Some OpenClaw CLI help text lists only built-in channel ids, but installed plugin channel ids such as `inline` are accepted.
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

Inline reply-thread semantics:

- `thread-reply` expects `threadId` to be the child reply-thread chat id, while `to` stays the parent chat id.
- `thread-create` creates a real reply thread from a parent chat and optional `replyToId` anchor.
- Automatic thread creation falls back to parent-chat delivery if the reply thread cannot be created.
- Existing route state is reused only for the same parent-message anchor. New parent-chat messages get separate reply threads; messages already inside a reply thread stay in that thread and do not create nested threads.
- Inline current-message media is attached like native channels. Reply-thread anchor media is summarized as context and is not promoted to current-message media on every child-thread turn.

You can gate action groups from config:

```yaml
channels:
  inline:
    reactionNotifications: own # off | own | all | allowlist
    reactionAllowlist:
      - "inline:123"
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

Named accounts can override the same `reactionNotifications` mode and `reactionAllowlist`.

## Extra Agent Tools

The plugin also registers dedicated tools outside the `message` action surface.

`inline_parent_context` fetches more parent-chat history for the current Inline reply-thread session when the automatic context window is not enough.

- Defaults to the current reply thread when invoked from one
- Optional inputs: `threadId`, `parentChatId`, `parentMessageId`, `beforeMessageId`, `limit`, `includeAnchor`, `accountId`
- Returned messages are ordered oldest to newest and include media/entity summaries

`inline_members` handles space-member discovery:

- Required input: `spaceId`
- Optional filters: `query`, `userId`, `limit`, `accountId`
- Returned members include explicit DM targets like `user:123`

The plugin also registers `inline_bot_commands` for Inline bot command management (v1):

- `action: "get"` -> calls `getMyCommands`
- `action: "set"` -> calls `setMyCommands` with Inline Bot API `commands[]`
- `action: "delete"` -> calls `deleteMyCommands`
- Limits follow Inline Bot API: max `100` commands, `command` max `32`, `description` max `256`, charset `^[a-z0-9_]+$`

Bot command sync:

- On `gateway_start`, the plugin registers default bot commands for each enabled/configured Inline account.
- Default commands include the same user-facing command set as bundled chat providers (for example: `/status`, `/model`, `/exec`, `/usage`, etc.).
- Inline also registers `/threadreply` to manage this group's reply-thread mode from chat.
- The plugin uses OpenClaw's command, skill command, and plugin command registries when available.
- Disable startup sync globally with `commands.native: false`, or per-channel with `channels.inline.commands.native: false`. Disabled startup sync clears existing Inline bot commands for the affected account.
- Disable skill command inclusion with `commands.nativeSkills: false`, or per-channel with `channels.inline.commands.nativeSkills: false`.

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
  - Keep the plugin entry id as `inline`, then re-run `openclaw plugins list` and `openclaw channels status`.
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token`, `INLINE_TOKEN`, or `INLINE_BOT_TOKEN` is set and plugin is updated (`openclaw plugins update inline`).
  - If using `dmPolicy: "open"`, ensure `allowFrom: ["*"]`.
