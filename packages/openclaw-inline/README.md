# @inline-chat/openclaw-inline

OpenClaw channel plugin for interacting with an OpenClaw agent via **Inline**.

Status: **beta** (solid foundation; expect iteration).

Quick setup guide: `docs/openclaw-setup.md`.
Create bot/token guide: `docs/create-inline-bot.md`.

Supports:

- Inline DMs (`ChatType=direct`)
- Inline chats (including top-level thread-style chats) as conversations (`ChatType=group`)
- Message replies: OpenClaw `replyToId` is mapped to Inline `replyToMsgId` (message id).

Non-goals (for now):

- Subthreads: Inline “replyTo” is a message reply, not a thread identifier. We do not expose OpenClaw subthread mode yet (`capabilities.threads=false`).

## Install

Requires OpenClaw `2026.2.9` or newer.

From npm (once published):

```sh
openclaw plugins install @inline-chat/openclaw-inline
```

If the plugin is already installed, update in place:

```sh
openclaw config set plugins.installs.openclaw-inline.spec '"@inline-chat/openclaw-inline@latest"'
openclaw plugins update openclaw-inline
```

From a local checkout (dev):

```sh
cd /path/to/inline/packages/openclaw-inline
bun run build
openclaw plugins install --link /path/to/inline/packages/openclaw-inline
```

## Configure

Channel config lives under `channels.inline` (the plugin config schema is intentionally empty).

Plugin id is `openclaw-inline` (for `plugins.entries.*`), while channel id stays `inline`.
If you enable explicitly, use:

```yaml
plugins:
  entries:
    openclaw-inline:
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
    requireMention: true
```

If you set `dmPolicy: "open"`, set `allowFrom: ["*"]`.

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

- `plugin not found: inline`
  - Use `plugins.entries.openclaw-inline`, not `plugins.entries.inline`.
- `doctor --fix` suggests Inline changes even though channel is healthy
  - Keep plugin entry id as `openclaw-inline`.
  - If `doctor --fix` writes `plugins.entries.inline`, change it back to `plugins.entries.openclaw-inline`.
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token` is set and plugin is updated (`openclaw plugins update openclaw-inline`).
  - If using `dmPolicy: "open"`, ensure `allowFrom: ["*"]`.
