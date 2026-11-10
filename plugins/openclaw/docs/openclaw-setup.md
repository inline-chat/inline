# OpenClaw Setup Guide

This guide is the fastest way to get the Inline channel working in OpenClaw.

Need a bot token first? See `docs/create-inline-bot.md`.

## 1) Install Plugin

Choose the Inline plugin version that matches the installed OpenClaw line:

- OpenClaw `2026.11.1` and newer: Inline plugin `1.0.0-alpha.1` — `openclaw plugins install npm:@inline-openclaw/inline@1.0.0-alpha.1 --force --accept-capabilities`
- OpenClaw `2026.8.2` through `2026.10.x`: Inline plugin `0.0.72` — `openclaw plugins install npm:@inline-openclaw/inline@0.0.72 --force --accept-capabilities`
- OpenClaw `2026.7.x` (`>=2026.7.1`): Inline plugin `0.0.63` — `openclaw plugins install @inline-openclaw/inline@0.0.63 --force`
- OpenClaw `2026.6.x` (`>=2026.6.11`, including extended-stable `2026.6.34`): Inline plugin `0.0.63` — `openclaw plugins install @inline-openclaw/inline@0.0.63 --force`

On 2026.8.2 and newer, `--accept-capabilities` noninteractively approves the capabilities
declared by the trusted first-party Inline package. Older supported hosts do not
recognize that flag.

The current plugin has no upper host version cap. For OpenClaw 2026.9.3 and
newer, use Node 24.16+ on 24.x or Node 26.1+ (Node 26 recommended).

To opt into the 1.0 alpha:

```sh
openclaw plugins install npm:@inline-openclaw/inline@1.0.0-alpha.1 --force --accept-capabilities
```

If already installed on a supported host, update in place:

```sh
openclaw gateway stop
openclaw plugins update inline --accept-capabilities
openclaw gateway start
openclaw plugins list
openclaw plugins inspect inline --json
openclaw channels status --channel inline --probe --json
```

On OpenClaw 2026.11.1 and newer, an exact install keeps its version pin.
Use `openclaw plugins update inline --dry-run` to inspect the selection. To
switch to stable updates, use `openclaw plugins update @inline-openclaw/inline@latest --accept-capabilities`
for the update step. Keep older hosts on their compatible pin. Run each command
with the same `--profile <name>` if using a named profile. For a foreground
gateway, stop and relaunch that process.

An OpenClaw owner can also try `/inline_update` in Inline. When the host
requires exclusive access, finish active turns and use the offline steps above.

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
- Replies to the bot wake it by default; set `channels.inline.replyToBotWithoutMention: false` to require a mention.
- Groups use `groupPolicy: "open"` and `requireMention: true` by default, so any group can reach the channel but only an explicit mention wakes the bot unless configured otherwise.
- Inline uses OpenClaw's group-history default; set `channels.inline.historyLimit` to override it, or use `messages.groupChat.historyLimit` as a global fallback.
- Inline reply-thread handling is available by default, so OpenClaw `threadId` can map to real Inline reply-thread chats.
- `replyToId` is still a message reply id. Inline reply-thread behavior does not replace ordinary message replies.
- Legacy `capabilities.replyThreads` settings are ignored; use `/threads` or `groups.<chatId>.replyThreadMode` to control it per chat.
- In an Inline chat or DM, authorized users can run `/threads` to choose Auto or On with buttons. Auto answers in the chat and starts a thread when someone asks; On answers each top-level message in a reply thread. A bot-wide value is ignored.
- Threads the bot follows continue without an explicit mention. A thread's first message decides who follows. Set `replyThreadRequireExplicitMention: true` globally, per account, or per group if a chat should require `@bot` on every thread message.
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
        replyThreadMode: "on"
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

The Inline plugin's error reporter is disabled unless the gateway operator sets
`INLINE_OPENCLAW_SENTRY_DSN` to an explicit collector. When enabled, reports
include the raw exception type and message, stack paths,
line/function locations, plugin release, operation name, runtime, OS, and
architecture so maintainers can diagnose failures in subsequent releases.

Reports do not attach Inline or OpenClaw message events, request bodies,
user/chat/account identifiers, breadcrumbs, source context, or stack locals.
Known token, password, authorization, and secret-shaped values are redacted
before upload. Inline's Sentry project also enables default server-side data
scrubbing and IP-address scrubbing. Because dependency exception messages are
preserved for diagnosis, they can still contain values the dependency itself
chose to place in an error.

Remove `INLINE_OPENCLAW_SENTRY_DSN`, set `INLINE_PLUGIN_TELEMETRY=off`, or set
`DO_NOT_TRACK=1` to disable reporting. Reporting is best-effort, has a two-second
network deadline, and never changes plugin success or failure behavior.

## 5) Common Fixes

- `Config validation failed: plugins.entries.inline: plugin not found: inline`
  - Ensure the plugin is installed and discovered (`openclaw plugins list`).
- `Inline: SETUP / no token`
  - Ensure `channels.inline.token`, `INLINE_TOKEN`, or `INLINE_BOT_TOKEN` is set.
  - Update plugin to latest (commands above).
- `doctor --fix` suggests changing the Inline plugin entry
  - Keep the plugin entry id as `inline`, then re-run `openclaw plugins list` and `openclaw channels status`.
- A restart notice says a request may already have finished
  - Check the original request and its results before retrying, especially for approvals or tools with side effects. Input saved before host dispatch resumes automatically. A turn or action that may already have entered the host is never automatically repeated.
  - Some supported hosts keep steers and follow-ups only in memory and cannot confirm their completion per request. The gateway retains those recovery records; a confirmed notice hands recovery to you and clears their saved payloads. Notices link back to the original Inline message.
  - The private local inbox is scoped to the account, API endpoint and authenticated bot. It is bounded to 1,000 unresolved inputs, 1 MiB per pending input and 8 MiB overall. If uncertain records fill it, the gateway sends a bounded recovery notice before admitting more input; it does not discard pending requests. This is safe recovery with an explicit uncertain outcome, not an exactly-once host execution guarantee.

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
