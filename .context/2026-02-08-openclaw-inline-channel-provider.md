# Inline as an OpenClaw Channel Provider (Two-Way Messaging) (2026-02-08)

This is the corrected direction:

- Goal: make **Inline** a first-class **channel** in **OpenClaw** (like Telegram/Slack/Discord), so OpenClaw can **receive** messages from Inline and **reply back** into Inline.
- Non-goal: building Telegram/Slack/Discord gateways inside Inline.

---

## 0) How OpenClaw Channels Work (Pattern to Copy)

OpenClaw’s “real” channel implementations live in core (`~/dev/openclaw/src/<provider>/...`) and:

1. run a long-lived monitor (`monitorXProvider({ abortSignal, ... })`)
2. turn provider updates into a **finalized inbound context** via `finalizeInboundContext(...)`
3. call `dispatchInboundMessage(...)` with a dispatcher whose `deliver()` sends replies back to the provider

Examples worth copying:

- Telegram: `~/dev/openclaw/src/telegram/monitor.ts`, `~/dev/openclaw/src/telegram/bot.ts`
- Slack: `~/dev/openclaw/src/slack/monitor/provider.ts`, `~/dev/openclaw/src/slack/monitor/message-handler/*`
- Discord: `~/dev/openclaw/src/discord/monitor/provider.ts`

Bundled extensions in `~/dev/openclaw/extensions/<provider>/...` mostly:

- declare the `ChannelPlugin` shape (config/pairing/directory/capabilities)
- implement `gateway.startAccount` by calling the core `monitorXProvider`

Example wiring:

- Telegram extension: `~/dev/openclaw/extensions/telegram/src/channel.ts`

To implement Inline as a channel “like Slack/Telegram”, follow that model:

- core implementation in `src/inline/*`
- extension plugin in `extensions/inline/*` that calls `monitorInlineProvider(...)`

---

## 1) Inline Primitives You’ll Use (API + Updates)

Inline has a binary protobuf WebSocket at:

- `wss://<inline-api-host>/realtime`

Server-side reference:

- WS handler: `server/src/realtime/index.ts`
- Auth handshake: `server/src/realtime/handlers/_connectionInit.ts`
- RPC method mux: `server/src/realtime/handlers/_rpc.ts`
- Update types: `proto/core.proto` (search `message Update`)

### Inline auth token

Inline bot/user tokens are bearer-style strings like `"<userId>:IN<random>"`:

- token generation: `server/src/utils/auth.ts`
- bot creation: `server/src/functions/createBot.ts` (returns `{ bot, token }`)

### Inline realtime handshake

1. Open WS to `/realtime`
2. Send a `ClientMessage { connection_init: { token, layer?, client_version? } }`
3. Receive `ServerProtocolMessage { connection_open: {} }`
4. (Recommended) Call `GET_ME` to learn the bot’s `user_id` and ignore your own outgoing messages.

### Inline inbound updates model (reliable path)

Inline has an explicit “updates” subsystem:

- Clients receive “has new updates” signals:
  - `UpdateChatHasNewUpdates { chat_id, peer_id, update_seq }`
  - `UpdateSpaceHasNewUpdates { space_id, update_seq }`
- Clients then pull the actual update slice via RPC:
  - `GET_UPDATES(bucket, start_seq, total_limit, seq_end?)`

Proto refs:

- `proto/core.proto`: `GetUpdatesInput`, `GetUpdatesResult`, `UpdateChatHasNewUpdates`, `UpdateNewMessage`, `UpdateEditMessage`, `UpdateDeleteMessages`, `UpdateReaction`, etc.

Server refs:

- `server/src/functions/updates.getUpdatesState.ts` (pushes `chatHasNewUpdates`/`spaceHasNewUpdates` on reconnect)
- `server/src/modules/updates/sync.ts` (inflates DB updates into `Update{ new_message/edit_message/... }`)

Why this matters: a provider implementation should persist cursors (`last seq`) so it can reconnect and catch up without missing messages.

---

## 2) What the Inline<->OpenClaw Mapping Should Be

### Conversation keying (OpenClaw sessions)

Pick a stable sessionKey strategy that:

- isolates conversations (no cross-thread bleed)
- is deterministic across restarts
- supports DMs vs group chats vs threads

Recommended (simple, safe):

- Inline DM (private chat): `agent:<agentId>:inline:dm:<otherUserId>`
- Inline chat/thread: `agent:<agentId>:inline:chat:<chatId>`

If you need to include space context explicitly:

- `agent:<agentId>:inline:space:<spaceId>:chat:<chatId>`

In the core handler, compute route via OpenClaw routing:

- `resolveAgentRoute({ cfg, channel: "inline", accountId, peer: { kind, id }, parentPeer? })`

### “To” / “From” identifiers (OpenClaw channel context)

Define a provider-local addressing scheme that is human-debuggable and maps to Inline inputs:

- DM target: `user:<id>`
- chat/thread target: `chat:<chatId>`

You’ll use those strings in:

- inbound context: `From`, `To`, `OriginatingTo`, `MessageSid`, `ReplyToId`, etc
- outbound delivery: your `sendMessageInline(to, ...)` should accept these targets

---

## 3) Implementation Approach (Recommended)

### A) OpenClaw core: `src/inline/*`

You need:

1. A small Inline realtime client (connect/reconnect + rpc calls)
2. A persistent cursor store (per chat, last processed `seq`)
3. A monitor loop that:
   - subscribes to `chatHasNewUpdates`
   - pulls `GET_UPDATES` slices
   - turns updates into OpenClaw inbound dispatch calls

Suggested files:

- `~/dev/openclaw/src/inline/client.ts`
  - connect WS
  - send `connectionInit`
  - parse `ServerProtocolMessage`
  - `rpcCall(method, input) -> result`
- `~/dev/openclaw/src/inline/state.ts`
  - `readInlineCursors(accountId)` / `writeInlineCursors(accountId, ...)`
  - store `chatId -> lastSeq` and `dateCursor` if you use `GET_UPDATES_STATE`
- `~/dev/openclaw/src/inline/monitor.ts`
  - `monitorInlineProvider({ token, baseUrl, accountId, cfg, runtime, abortSignal })`
  - main loop: connect -> sync -> listen -> reconnect w/ backoff
- `~/dev/openclaw/src/inline/send.ts`
  - `sendMessageInline(target, text, { replyToMessageId?, silent? })`
  - uses Inline `SEND_MESSAGE` RPC

### B) OpenClaw runtime surface: expose Inline hooks to extensions

Bundled extensions call runtime methods (see `src/plugins/runtime/types.ts`).

To match Telegram/Slack:

- extend `PluginRuntime.channel` to include `inline: { monitorInlineProvider, sendMessageInline, ... }`
- wire it in `~/dev/openclaw/src/plugins/runtime/index.ts` (where other providers are wired)

Then the extension can be tiny and stable.

### C) OpenClaw extension: `extensions/inline/*`

Mirror `extensions/telegram`:

- `extensions/inline/openclaw.plugin.json` (declare channel id for config validation)
- `extensions/inline/index.ts` registers the channel plugin
- `extensions/inline/src/channel.ts`:
  - config adapter: accounts + enabled + baseUrl + token source
  - security adapter: dmPolicy + allowFrom (optional)
  - gateway adapter: `startAccount` calls `runtime.channel.inline.monitorInlineProvider(...)`
  - outbound adapter: `sendText` calls `runtime.channel.inline.sendMessageInline(...)`

---

## 4) Inbound Processing (Inline -> OpenClaw)

### Event ingestion rule

Process only *human* inbound messages:

- drop any message authored by the bot itself
  - easiest: `message.out == true` or `message.from_id == botUserId`
- decide whether to accept group/chat messages:
  - mention gating: use `message.mentioned == true` (Inline encodes “mentioned for current user”)
  - or require explicit prefix/command

### The reliable loop (cursor-based)

Per chat:

1. Keep `lastSeq[chatId]` persisted.
2. On `UpdateChatHasNewUpdates(chatId, updateSeq)`:
   - if `updateSeq <= lastSeq[chatId]`: ignore
   - else call `GET_UPDATES(bucket=chat(chatId), start_seq=lastSeq, total_limit=N)`
3. For each returned `Update`:
   - handle `new_message`, `edit_message`, `delete_messages`, `update_reaction`, etc
   - advance `lastSeq = update.seq` as you successfully process
4. Persist `lastSeq` periodically (and on shutdown) to survive restarts.

### Turning a Inline message into an OpenClaw inbound dispatch

For `UpdateNewMessage.message`:

- Build your `FinalizedMsgContext` via `finalizeInboundContext({...})`:
  - `Body`: message text (plus placeholders for media if present)
  - `From`: `user:<from_id>`
  - `To`: `chat:<chat_id>` or `user:<peer_user_id>` depending on peer type
  - `Provider` / `Surface`: `"inline"`
  - `MessageSid`: Inline message id (stringify `message.id`)
  - `ReplyToId`: Inline `reply_to_msg_id` (if set)
  - `Timestamp`: Inline `date` (seconds?) convert to ms as needed
  - `WasMentioned`: `message.mentioned`
  - `ChatType`: `direct` vs `channel/thread` based on the chat type you resolved
- Call `recordInboundSession(...)` so OpenClaw stores routing metadata and “last route” for DMs.
- Create a reply dispatcher via `createReplyDispatcherWithTyping({ deliver: ... })`:
  - `deliver(payload)` should call your Inline `SEND_MESSAGE` (reply to same chat)
  - implement optional typing via Inline `SEND_COMPOSE_ACTION`
- Call `dispatchInboundMessage({ ctx, cfg, dispatcher, replyOptions })`

Copy patterns from Slack:

- `~/dev/openclaw/src/slack/monitor/message-handler/prepare.ts`
- `~/dev/openclaw/src/slack/monitor/message-handler/dispatch.ts`

---

## 5) Outbound Delivery (OpenClaw -> Inline)

Minimum:

- implement `sendMessageInline(chatId, text, replyToMessageId?)` using Inline RPC:
  - `Method.SEND_MESSAGE`
  - `SendMessageInput { peer_id: InputPeerChat{chat_id} | InputPeerUser{user_id}, message, reply_to_message_id? }`

If you want “typing…” parity:

- on reply start: call `Method.SEND_COMPOSE_ACTION` with `TYPING`
- on idle: call again with `action` unset to stop

Chunking:

- define a conservative max message length (until you enforce Inline limits)
- use OpenClaw’s chunkers: `chunkMarkdownText` or `chunkTextWithMode`

---

## 6) What To Persist (OpenClaw side)

At minimum:

- `dateCursor` for `GET_UPDATES_STATE` (so reconnect doesn’t rescan from 0)
- per-chat `lastSeq` cursors (so `GET_UPDATES` is idempotent)

Store location:

- use OpenClaw state dir resolution (see Telegram offset store patterns):
  - `~/dev/openclaw/src/telegram/update-offset-store.ts`

File format suggestion:

```json
{
  "version": 1,
  "dateCursor": 1739318400000,
  "chats": {
    "123": { "lastSeq": 4812 },
    "456": { "lastSeq": 992 }
  }
}
```

---

## 7) Configuration Sketch (OpenClaw)

You’ll want something like:

```json5
{
  channels: {
    inline: {
      enabled: true,
      baseUrl: "https://api.inline.chat",
      accounts: {
        default: {
          token: "BOT_TOKEN",
          // allowlists (optional):
          dmPolicy: "pairing", // or "open"/"allowlist"/"disabled"
          allowFrom: ["123", "456"],
          chats: {
            "123": { requireMention: true },
            "*": { requireMention: true }
          }
        }
      }
    }
  }
}
```

Notes:

- Inline already has an authenticated membership model, so you may choose to default DM policy to `"open"` in practice. If you want OpenClaw’s “untrusted DM” posture, keep `"pairing"`.

---

## 8) MVP Milestones

1. Connect to Inline `/realtime` with bot token; call `GET_ME`.
2. Implement cursor store + `chatHasNewUpdates -> GET_UPDATES` loop.
3. Handle `UpdateNewMessage` by dispatching to OpenClaw agent and replying back into Inline.
4. Add “ignore own messages” + basic mention gating.
5. Add reconnect/backoff + catch-up on reconnect (`GET_UPDATES_STATE` + `GET_UPDATES`).
6. Add reactions/edit/delete support (optional).

---

## 9) What You Can Ignore Initially

- Inline media download/attachments: start text-only, then add attachment URL resolution later.
- Rich entities/markdown fidelity: ship plain text first; add entity conversion after.
- Directory listing: you can start without it; later use `GET_CHATS` for live directory.

