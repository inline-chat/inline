# @inline-openclaw/inline

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

Channel config lives under `channels.inline` (the plugin config schema is intentionally empty).

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

- `plugin not found: inline` / `plugins.entries.inline: plugin not found: inline`
  - Ensure the plugin is installed and discovered (`openclaw plugins list`).
- `doctor --fix` suggests Inline changes even though channel is healthy
  - Plugin entry id should be `inline`.
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token` is set and plugin is updated (`openclaw plugins update inline`).
  - If using `dmPolicy: "open"`, ensure `allowFrom: ["*"]`.
