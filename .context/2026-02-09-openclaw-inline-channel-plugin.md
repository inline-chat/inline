# OpenClaw Inline Channel Plugin (Inline-owned) (2026-02-09)

## Goal

Ship an **OpenClaw channel plugin** (installable as an OpenClaw plugin) that uses the
Inline **Node SDK** to let OpenClaw users interact with the bot through:

- Inline DMs
- Inline threads/chats (treated as “group”-like conversations in OpenClaw)

This lives in the Inline monorepo under `packages/`, and uses OpenClaw’s `openclaw/plugin-sdk`
contract (as documented on docs.openclaw.ai and exemplified by OpenClaw’s `extensions/msteams`).

## References (What We Copied)

- OpenClaw plugin docs: `docs/tools/plugin.md` + `docs/plugins/manifest.md` in `~/dev/openclaw`
- OpenClaw official plugin patterns:
  - `~/dev/openclaw/extensions/msteams` (plugin entry + registerChannel)
  - `~/dev/openclaw/extensions/mattermost` (monitor -> build ctx -> `dispatchReplyFromConfig`)
- Inline SDK primitives:
  - `packages/sdk/src/sdk/inline-sdk-client.ts`
  - `packages/sdk/src/sdk/types.ts` (normalized `InlineInboundEvent` stream)

## Key Design Decisions

### 1) Where config lives

Per OpenClaw channel plugin conventions, all channel config lives under:

- `channels.inline`

The plugin’s own config under `plugins.entries.inline.config` is empty for now; we still ship
`openclaw.plugin.json` to declare the plugin id + channel id (strict OpenClaw validation requires it).

### 2) Identity + routing mapping (OpenClaw sessions)

- OpenClaw routing uses `resolveAgentRoute({ channel: "inline", peer: { kind, id }, parentPeer? })`.
- DM session peer:
  - `kind = "direct"` (OpenClaw `ChatType`)
  - `id = <senderUserId>`
- Thread/chat session peer:
  - `kind = "group"`
  - `id = <chatId>`

Threading support (current):

- Inline threads are top-level chats (chatId).
- We do **not** expose OpenClaw subthread semantics yet:
  - `capabilities.threads = false`
  - no `MessageThreadId` is set on inbound context
- Message replies are supported:
  - `ReplyToId = <replyToMsgId>` (when present)

### 3) Safety defaults

Default behavior is conservative:

- DMs: `dmPolicy = "pairing"` (unknown senders get a pairing prompt and are not processed)
- Threads/chats: `groupPolicy = "allowlist"` + `requireMention = true`
- Pairing approval: `pairing.notifyApproval` attempts a best-effort DM to the approved id (works if DM chatId == userId).

### 4) Inbound reliability

We rely on `@inline-chat/sdk`’s realtime client + optional state store cursoring.
We added the minimal SDK method(s) needed by the plugin (`getChat`) for chat classification + labels,
and the monitor uses `client.getChat()` rather than direct protocol `invoke()`.

## Planned Work

1. SDK readiness:
   - Add `InlineSdkClient.getChat({ chatId })` + tests.

2. New package:
   - `packages/openclaw-inline/` (name TBD, but it is an OpenClaw plugin pack)
   - Includes `openclaw.plugin.json` manifest
   - Exposes an OpenClaw plugin entry that registers the `inline` channel.

3. Channel implementation:
   - Long-lived listener in `gateway.startAccount` using `InlineSdkClient.events()`
   - For each inbound message:
     - loop prevention (ignore `message.out` / self id)
     - DM/group policy enforcement + pairing prompt handling
     - mention gating for non-DMs
     - build `FinalizedMsgContext` via `core.channel.reply.finalizeInboundContext`
     - send into OpenClaw via `core.channel.reply.dispatchReplyWithBufferedBlockDispatcher`

4. Tests:
   - Pure unit tests for:
     - allowlist/pairing policy decisions
     - target normalization/parsing
     - outbound delivery chunking behavior
   - No live network tests in repo (those would be opt-in separately).
