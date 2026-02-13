# OpenClaw Setup Guide (Minimal)

This guide is the fastest way to get the Inline channel working in OpenClaw.

Need a bot token first? See `docs/create-inline-bot.md`.

## 1) Install Plugin

```sh
openclaw plugins install @inline-openclaw/inline
```

If already installed, update to latest:

```sh
openclaw config set plugins.installs.inline.spec '"@inline-openclaw/inline@latest"'
openclaw plugins update inline
```

## 2) Configure Inline Channel

Minimal config (token-only):

```yaml
channels:
  inline:
    enabled: true
    token: "<INLINE_BOT_TOKEN>"
```

Notes:
- `baseUrl` defaults to `https://api.inline.chat`.
- Plugin id is `inline`.
- For multi-bubble replies, enable `channels.inline.blockStreaming: true`.
- For reply-driven group flows, set `channels.inline.replyToBotWithoutMention: true`.
- Group mention requirement is off by default; set `channels.inline.requireMention: true` if you want strict mentions.
- To include recent thread context for the agent, set `channels.inline.historyLimit`.
- Message actions include reply/read/search/edit/reactions/channel and participant management; gate groups via `channels.inline.actions.*`.
- Media uploads (image/video/document) are enabled by default for `mediaUrl` sends; set `channels.inline.mediaMaxMb` if you need a lower cap.

## 3) Start Gateway

```sh
openclaw gateway
```

If another gateway is already running:

```sh
openclaw gateway stop
openclaw gateway
```

## 4) Verify Health

```sh
openclaw plugins list
openclaw status --deep
```

Expected:
- Plugin `inline` is loaded.
- Channel `Inline` is `ON / OK`.

## 5) Common Fixes

- `Config validation failed: plugins.entries.inline: plugin not found: inline`
  - Ensure the plugin is installed and discovered (`openclaw plugins list`).
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token` is set.
  - Update plugin to latest (commands above).
- `doctor --fix` rewrites inline plugin entry
  - Plugin entry id should be `inline`.

## Recommended Hardening (After Basic Setup)

```sh
openclaw config set session.dmScope '"per-channel-peer"'
```

Add plugin allowlist to reduce extension loading risk:

```yaml
plugins:
  allow:
    - inline
    # add other plugin ids you trust
```
