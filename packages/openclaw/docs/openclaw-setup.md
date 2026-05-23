# OpenClaw Setup Guide

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
openclaw gateway restart
openclaw plugins list
openclaw channels status
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
- Instead of storing `token`, you can set `INLINE_TOKEN` in the gateway environment. `INLINE_BOT_TOKEN` is also accepted.
- `defaultTo` is optional and gives outbound sends a fallback target, for example `chat:<id>` or `user:<id>`, when no explicit target is supplied.
- If you add an explicit `plugins.entries` block, the plugin entry id is `inline`.
- For multi-bubble replies, enable `channels.inline.blockStreaming: true`.
- For reply-driven group flows, set `channels.inline.replyToBotWithoutMention: true`.
- Group mention requirement is off by default; set `channels.inline.requireMention: true` if you want strict mentions.
- Inline uses OpenClaw's group-history default; set `channels.inline.historyLimit` to override it, or use `messages.groupChat.historyLimit` as a global fallback.
- Inline reply threads are off by default. Enable `channels.inline.capabilities.replyThreads: true` if you want OpenClaw `threadId` to map to real Inline reply-thread chats.
- `replyToId` is still a message reply id. Enabling `replyThreads` adds Inline reply-thread behavior; it does not replace ordinary message replies.
- You can override the thread toggle per account with `channels.inline.accounts.<account>.capabilities.replyThreads`.
- Message actions include reply/read/search/edit/reactions/channel and participant management; gate groups via `channels.inline.actions.*`.
- Passive reaction notifications default to `channels.inline.reactionNotifications: "own"` for bot-authored messages. Set it to `"off"` to suppress queued reaction events, `"all"` to queue reactions on any authorized message, or `"allowlist"` with `reactionAllowlist` for selected reaction senders; named accounts can override the same fields.
- Media uploads (image/video/document) are enabled by default for `mediaUrl` sends; set `channels.inline.mediaMaxMb` if you need a lower cap.
- Native exec approvals use `channels.inline.execApprovals`. Set `approvers` to Inline user IDs such as `123` or `user:123`, or rely on numeric `commands.ownerAllowFrom`; `target` defaults to approver DMs.

Access defaults:
- DMs use `dmPolicy: "pairing"` unless configured.
- For private bots, use `dmPolicy: "allowlist"` with your Inline user id in `allowFrom`.
- For public/demo bots, use `dmPolicy: "open"` with `allowFrom: ["*"]`.
- Groups use `groupPolicy: "allowlist"` unless configured.
- For broad group access, use `groups: { "*": { requireMention: true } }` so the bot only answers mentions.
- For selected groups, list numeric chat ids under `groups`.
- Use `groupAllowFrom` for an account-wide group sender allowlist, or `groups.<chat>.allowFrom` for per-group sender allowlists.
- `groupAllowFrom` is optional; use it only when specific senders inside allowed groups should be able to trigger the bot.

Example reply-thread toggle:

```yaml
channels:
  inline:
    capabilities:
      replyThreads: true
```

## 3) Start Gateway

Foreground:

```sh
openclaw gateway run
```

Service:

```sh
openclaw gateway start
```

If another gateway service is already running:

```sh
openclaw gateway stop
openclaw gateway start
```

## 4) Verify Health

```sh
openclaw plugins list
openclaw status --deep
```

Expected:
- Plugin `inline` is loaded.
- Channel `Inline` is configured and running/connected.

## 5) Common Fixes

- `Config validation failed: plugins.entries.inline: plugin not found: inline`
  - Ensure the plugin is installed and discovered (`openclaw plugins list`).
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token`, `INLINE_TOKEN`, or `INLINE_BOT_TOKEN` is set.
  - Update plugin to latest (commands above).
- `doctor --fix` suggests changing the Inline plugin entry
  - Keep the plugin entry id as `inline`, then re-run `openclaw plugins list` and `openclaw channels status`.

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
