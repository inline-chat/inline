# OpenClaw Setup Guide

This guide is the fastest way to get the Inline channel working in OpenClaw.

Need a bot token first? See `docs/create-inline-bot.md`.

## 1) Install Plugin

Choose the Inline plugin version that matches the installed OpenClaw line:

- OpenClaw `2026.8.x` (`>=2026.8.2`): Inline plugin `0.0.64` — `openclaw plugins install --force @inline-openclaw/inline@0.0.64`
- OpenClaw `2026.7.x`: Inline plugin `0.0.63` — `openclaw plugins install --force @inline-openclaw/inline@0.0.63`
- OpenClaw `2026.6.x` (`>=2026.6.11`, including extended-stable `2026.6.34`): Inline plugin `0.0.63` — `openclaw plugins install --force @inline-openclaw/inline@0.0.63`

The unversioned install follows the newest supported OpenClaw line:

```sh
openclaw plugins install @inline-openclaw/inline
```

If already installed, update to latest:

```sh
openclaw plugins install --force @inline-openclaw/inline@latest
openclaw gateway restart
openclaw plugins list
openclaw channels status
```

After the first install, an OpenClaw owner can run `/inline_update` in Inline
and then `/restart`; routine plugin updates do not require host shell access.

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
- Groups use `groupPolicy: "open"` and `requireMention: true` by default, so any group can reach the channel but only an explicit mention wakes the bot unless configured otherwise.
- Inline uses OpenClaw's group-history default; set `channels.inline.historyLimit` to override it, or use `messages.groupChat.historyLimit` as a global fallback.
- Inline reply-thread handling is available by default, so OpenClaw `threadId` can map to real Inline reply-thread chats.
- `replyToId` is still a message reply id. Inline reply-thread behavior does not replace ordinary message replies.
- Legacy `capabilities.replyThreads` settings are ignored; use `replyThreadMode` to control automatic routing.
- In an Inline group, authorized users can run `/threadreply` to choose this chat's automatic reply-thread mode with buttons.
- Bot-participated reply threads and Inline dialogs already marked `FOLLOWING` continue without an explicit mention by default, matching Slack. Reply threads also persist recent participation so sparse follow-ups still route. Set `replyThreadRequireExplicitMention: true` globally, per account, or per group if a chat should require `@bot` on every thread message.
- Reply-thread context defaults to nearby parent-chat messages, the anchor message, and child-thread history. Set `replyThreadParentHistoryLimit: 0` only when a chat should stay strictly thread-local.
- Use `inline_parent_context` from a reply-thread session when the agent needs more complete parent-chat history than the automatic context window.
- Inline current-message media is attached like native channels. Reply-thread anchor media is summarized as context and is not promoted to current-message media on every child-thread turn.
- Message actions include reply/read/search/edit/reactions/channel and participant management; gate groups via `channels.inline.actions.*`.
- Passive reaction notifications default to `channels.inline.reactionNotifications: "own"` for bot-authored messages. Set it to `"off"` to suppress queued reaction events, `"all"` to queue reactions on any authorized message, or `"allowlist"` with `reactionAllowlist` for selected reaction senders; named accounts can override the same fields.
- Media uploads (image/video/document) are enabled by default for `mediaUrl` sends; set `channels.inline.mediaMaxMb` if you need a lower cap.
- Native exec approvals use `channels.inline.execApprovals`. Set `approvers` to Inline user IDs such as `123` or `user:123`, or rely on numeric `commands.ownerAllowFrom`; `target` defaults to approver DMs.

Access defaults:
- DMs use `dmPolicy: "pairing"` unless configured.
- For private bots, use `dmPolicy: "allowlist"` with your Inline user id in `allowFrom`.
- For public/demo bots, use `dmPolicy: "open"` with `allowFrom: ["*"]`.
- Groups use `groupPolicy: "open"` unless configured.
- Group messages require a bot mention by default (`requireMention: true`). Use `groups` to override mention behavior for selected chats.
- For selected groups, list numeric chat ids under `groups`.
- Use `groupAllowFrom` for an account-wide group sender allowlist, or `groups.<chat>.allowFrom` for per-group sender allowlists.
- `groupAllowFrom` is optional; use it only when specific senders inside allowed groups should be able to trigger the bot.

Example reply-thread toggle:

```yaml
channels:
  inline:
    replyThreadRequireExplicitMention: false
    replyThreadParentHistoryLimit: 10
    groups:
      "123":
        replyThreadMode: "thread"
        replyThreadRequireExplicitMention: true
        replyThreadParentHistoryLimit: 2
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

## Error Reporting And Privacy

The Inline plugin reports unexpected plugin failures to Inline's Sentry project
by default. Reports include the raw exception type and message, stack paths,
line/function locations, plugin release, operation name, runtime, OS, and
architecture so maintainers can diagnose failures in subsequent releases.

Reports do not attach Inline or OpenClaw message events, request bodies,
user/chat/account identifiers, breadcrumbs, source context, or stack locals.
Known token, password, authorization, and secret-shaped values are redacted
before upload. Inline's Sentry project also enables default server-side data
scrubbing and IP-address scrubbing. Because dependency exception messages are
preserved for diagnosis, they can still contain values the dependency itself
chose to place in an error.

Set `INLINE_PLUGIN_TELEMETRY=off` or `DO_NOT_TRACK=1` in the gateway environment
to disable all Inline plugin error reporting. Reporting is best-effort, has a
two-second network deadline, and never changes plugin success or failure
behavior.

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
