# OpenClaw Setup Guide (Minimal)

This guide is the fastest way to get the Inline channel working in OpenClaw.

Need a bot token first? See `docs/create-inline-bot.md`.

## 1) Install Plugin

```sh
openclaw plugins install @inline-chat/openclaw-inline
```

If already installed, update to latest:

```sh
openclaw config set plugins.installs.openclaw-inline.spec '"@inline-chat/openclaw-inline@latest"'
openclaw plugins update openclaw-inline
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
- Plugin id is `openclaw-inline` (not `inline`).

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
- Plugin `openclaw-inline` is loaded.
- Channel `Inline` is `ON / OK`.

## 5) Common Fixes

- `Config validation failed: plugins.entries.inline: plugin not found: inline`
  - Use `plugins.entries.openclaw-inline`, not `plugins.entries.inline`.
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token` is set.
  - Update plugin to latest (commands above).
- `doctor --fix` rewrites inline plugin entry
  - Keep plugin entry id as `openclaw-inline`.

## Recommended Hardening (After Basic Setup)

```sh
openclaw config set session.dmScope '"per-channel-peer"'
```

Add plugin allowlist to reduce extension loading risk:

```yaml
plugins:
  allow:
    - openclaw-inline
    # add other plugin ids you trust
```
