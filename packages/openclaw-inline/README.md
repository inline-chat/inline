# @inline-chat/openclaw-inline

OpenClaw channel plugin for interacting with an OpenClaw agent via **Inline**.

Status: **beta** (solid foundation; expect iteration).

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
