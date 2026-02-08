# OpenClaw Channel Gateways (Telegram/Slack/Discord) + How To Build This For Inline (2026-02-08)

This doc has two goals:

1. Summarize how OpenClaw handles **Telegram**, **Slack**, and **Discord** inbound updates (polling/gateways/webhooks), with code pointers.
2. Turn that into a practical blueprint for building an **external-channel gateway** for **Inline**.

If you’re implementing a message bridge (external channel <-> Inline thread), focus on the “Inline Design” sections.

---

## Part 1: OpenClaw Findings (What To Copy)

### Telegram (grammY) in OpenClaw

**Where to read**

- Channel plugin glue: `~/dev/openclaw/extensions/telegram/src/channel.ts`
- Polling loop: `~/dev/openclaw/src/telegram/monitor.ts`
- Webhook server + setWebhook: `~/dev/openclaw/src/telegram/webhook.ts`
- Bot wiring (dedupe + sequentialize): `~/dev/openclaw/src/telegram/bot.ts`
- Update key + dedupe: `~/dev/openclaw/src/telegram/bot-updates.ts`
- Persisted polling offset: `~/dev/openclaw/src/telegram/update-offset-store.ts`
- Docs: `~/dev/openclaw/docs/channels/telegram.md`, `~/dev/openclaw/docs/channels/grammy.md`

**Core architecture**

- One long-running “provider monitor” entrypoint: `monitorTelegramProvider()` in `src/telegram/monitor.ts`.
- Supports two inbound modes:
  - **Long-polling (getUpdates)** using `@grammyjs/runner` + concurrency controls.
  - **Webhook** via `webhookCallback()` hosted by a small Node HTTP server, plus `setWebhook`.
- The gateway decides the mode based on config:
  - `extensions/telegram/src/channel.ts` sets `useWebhook: Boolean(account.config.webhookUrl)` and passes `webhookUrl/webhookSecret/webhookPath` into `monitorTelegramProvider(...)`.

**Update processing + ordering**

- Uses `@grammyjs/runner` with concurrency capped by agent settings:
  - `createTelegramRunnerOptions()` sets `sink.concurrency = resolveAgentMaxConcurrent(cfg)`.
- Enforces **per-chat/per-topic sequential processing**:
  - `bot.use(sequentialize(getTelegramSequentialKey))` in `src/telegram/bot.ts`.
  - `getTelegramSequentialKey()` keys by chat id, and also isolates “control commands” to a separate key.

**Idempotency / dedupe**

- Two layers:
  1. **Persisted monotonic offset** (`update_id`) for long-polling restarts:
     - Read on boot: `readTelegramUpdateOffset()`
     - Persist as updates complete: `writeTelegramUpdateOffset()`
  2. **In-memory dedupe** for “same update delivered twice” within a process:
     - `createTelegramUpdateDedupe()` uses a TTL cache (5 minutes / max 2000 keys).
     - Keyed by `update_id`, callback query id, or fallback `(chat_id, message_id)`.

**Webhook specifics**

- `startTelegramWebhook()`:
  - spins up a dedicated HTTP server (default `0.0.0.0:8787`)
  - serves `POST /telegram-webhook` and `GET /healthz`
  - calls `bot.api.setWebhook(publicUrl, { secret_token, allowed_updates })`
  - uses `webhookCallback(bot, "http", { secretToken: opts.secret })`
- Diagnostic hooks exist for timing + error logging.

**Error handling**

- Restarts polling runner on:
  - `409 getUpdates conflict` (another poller/webhook active)
  - recoverable network errors
- Uses exponential backoff with jitter (`TELEGRAM_POLL_RESTART_POLICY`).

**Takeaways to apply to Inline**

- Treat Telegram inbound as a **stream of updates** requiring:
  - a per-conversation ordering guarantee
  - an idempotency key store (persisted across restarts)
  - a second short-lived dedupe cache
- Webhook mode is operationally different (public URL, secret header validation, port restrictions via reverse proxy).

---

### Slack (Bolt) in OpenClaw

**Where to read**

- Channel plugin glue: `~/dev/openclaw/extensions/slack/src/channel.ts`
- Provider monitor: `~/dev/openclaw/src/slack/monitor/provider.ts`
- Gateway HTTP request mux: `~/dev/openclaw/src/gateway/server-http.ts`
- Slack HTTP route registry: `~/dev/openclaw/src/slack/http/registry.ts`
- Docs: `~/dev/openclaw/docs/channels/slack.md`

**Core architecture**

- Single monitor entrypoint: `monitorSlackProvider()` in `src/slack/monitor/provider.ts`.
- Supports two inbound transport modes:
  - **Socket Mode** (default): Slack -> WebSocket -> your app (outgoing connection).
  - **HTTP mode** (Events API): Slack -> HTTPS webhook -> your server.
- Mode selection:
  - `slackMode = opts.mode ?? account.config.mode ?? "socket"`

**How HTTP mode is wired**

- OpenClaw’s main gateway HTTP server (`src/gateway/server-http.ts`) dispatches requests in this order:
  - hooks -> tools invoke -> **Slack HTTP handler** -> plugins -> other endpoints
- The Slack provider registers a handler with a global map:
  - `registerSlackHttpHandler({ path, handler })` in `src/slack/http/registry.ts`
- In HTTP mode, Bolt’s `HTTPReceiver` handles:
  - signature verification (via signing secret)
  - URL verification
  - events, interactivity, slash commands, etc

**Update processing & retries**

- Bolt abstracts the low-level event ack and retry headers.
- Slack itself retries deliveries if you don’t 2xx quickly. This is why a real gateway implementation should:
  - respond quickly
  - push the “real work” async to a queue/worker
  - dedupe on Slack’s event identifiers

**Access control patterns**

- OpenClaw treats DMs as untrusted by default:
  - `dmPolicy="pairing"` + allowlists
- For group contexts it uses:
  - `groupPolicy`
  - channel allowlists (`channels.slack.channels`)
  - optional mention gating

**Takeaways to apply to Inline**

- Slack has a clean separation:
  - inbound transport (socket vs http)
  - event normalization and routing
- You should design Inline to support both:
  - Socket Mode for “no public URL needed” deployments
  - HTTP Events API for “public server” deployments

---

### Discord (Gateway) in OpenClaw

**Where to read**

- Channel plugin glue: `~/dev/openclaw/extensions/discord/src/channel.ts`
- Provider monitor: `~/dev/openclaw/src/discord/monitor/provider.ts`
- Gateway stop-wait helper: `~/dev/openclaw/src/discord/monitor.gateway.ts`
- Docs: `~/dev/openclaw/docs/channels/discord.md`

**Core architecture**

- One monitor entrypoint: `monitorDiscordProvider()` in `src/discord/monitor/provider.ts`.
- Always uses the **Discord Gateway** (WebSocket) for inbound events.
- Uses a library (`@buape/carbon` + gateway plugin) to manage:
  - identify/resume/reconnect
  - intents
  - interactions (slash commands) + listeners

**Operational hardening**

- Adds a “HELLO timeout” guard:
  - If the WebSocket opens but Discord never sends HELLO, force reconnect.
- Turns off reconnect on abort by setting `gateway.options.reconnect = { maxAttempts: 0 }` then disconnecting.
- Centralizes stop waiting with `waitForDiscordGatewayStop(...)`.

**Intents**

- Picks a baseline set of intents, optionally adds presence/member intents based on config.
- Docs call out privileged intents, especially Message Content and Guild Members.

**Takeaways to apply to Inline**

- Treat Discord as a long-lived WebSocket client.
- If you run multiple gateway shards/processes, only one should own a given bot token unless you intentionally shard.
- Assume you will occasionally see:
  - zombie sockets
  - invalid sessions
  - transient close codes
  and your gateway must auto-recover.

---

## Part 2: Platform Reality Check (Design Constraints)

### Telegram

- Two ways to ingest updates:
  - **Long polling** (simple; no public URL; must persist update offset).
  - **Webhook** (needs public HTTPS URL; Telegram sends a secret header if you set `secret_token`; Telegram restricts webhook ports so you usually reverse-proxy).
- When a webhook is set, Telegram will not deliver via getUpdates.
- Telegram update ordering is per-bot; you still want per-chat serialization for your internal processing so you don’t race on “edit after create” etc.

### Slack

- Two ingestion modes:
  - **Events API** (HTTP). Must 2xx within ~3s or Slack retries. Requires verifying request signatures.
  - **Socket Mode** (WebSocket). No public URL; still uses the same event subscriptions, but delivered over socket.
- Slack can redeliver events; you need idempotency using Slack event ids + retry headers.

### Discord

- Inbound messages are gateway events, not webhooks.
- Privileged intents (Message Content, Guild Members, Presence) are a policy/ops concern.
- Slash command interactions can be received via:
  - Gateway event (common for bots), plus REST APIs to respond/follow up.
  - Or an HTTP interactions endpoint (less relevant if you already run the gateway).

---

## Part 3: How To Build “Telegram/Slack/Discord Channels” For Inline

### What “a gateway” should mean for Inline

You want a single logical subsystem that:

- owns provider credentials (tokens/secrets)
- ingests provider events (webhooks and/or websockets/polling)
- normalizes events into a canonical event model
- routes events into Inline (create message, edit, delete, reaction, etc)
- performs outbound delivery from Inline back to the provider when configured
- guarantees ordering, idempotency, and safe retries

This can be implemented in one of two ways:

1. **In-process gateway** (inside `server/`).
2. **Sidecar gateway service** (separate Node service) that talks to Inline via internal API.

Both are valid; pick based on ops + library/runtime compatibility.

---

### Inline-Specific Wiring (Where events become messages)

Inline already has “write a message and broadcast updates” pathways; your gateway should reuse them.

Useful entry points (current repo):

- Send message: `server/src/functions/messages.sendMessage.ts`
- Edit message: `server/src/functions/messages.editMessage.ts`
- Delete message(s): `server/src/functions/messages.deleteMessage.ts`
- Add reaction: `server/src/functions/messages.addReaction.ts`
- Delete reaction: `server/src/functions/messages.deleteReaction.ts`
- Realtime fanout helpers: `server/src/realtime/message.ts`

Important constraint: `messages.fromId` is a required foreign key (`server/src/db/schema/messages.ts`), so an external sender must be represented somehow.

You have three realistic choices:

1. **“Bridge bot” sender (simplest)**
   - Create a dedicated Inline user per provider or per integration route (eg `slack-bridge-bot`).
   - All imported messages are authored by that bot user.
   - Preserve the true external author in:
     - message text prefix (eg `[Slack] Alice: ...`), and/or
     - a structured attachment/metadata row (recommended if you’ll later support edits/replies cleanly).

2. **Shadow users (most faithful)**
   - Create (or map to existing) Inline users for each external user id.
   - Pros: mentions/replies/attribution feel native.
   - Cons: membership, provisioning, display names, abuse/impersonation, and account lifecycle get complicated.

3. **Schema change for “external author”**
   - Add explicit columns or a side table for external author identity and allow messages authored by a system user.
   - This is the cleanest long-term but is a bigger product/DB migration decision.

If you’re just getting to “it works”, start with (1), but design the DB so you can upgrade to (2)/(3) later.

---

### Recommended: Sidecar “Integration Gateway” service

Reasoning:

- Slack/Discord/Telegram SDKs tend to assume Node semantics; Inline backend runs on Bun.
- The integration gateway is stateful (websocket connections, offsets); you don’t want that state coupled to your main API autoscaling behavior.
- You may want separate deploy + secrets scope.

**High-level flow**

```
Telegram (webhook/poll) ┐
Slack (socket/http)     ├──> integration-gateway  ──(internal auth)──> inline server
Discord (gateway)       ┘                                │
                                                         └──> Inline realtime to clients
```

**Minimal internal API between gateway and Inline**

- `POST /integrations/events` (ingest normalized events)
- `POST /integrations/outbound` (Inline asks gateway to deliver to provider) OR a queue/DB table for outbound jobs
- `GET /integrations/routes` (optional: gateway pulls mapping config)

Use service-to-service auth (mTLS or a shared token), and run gateway on a private network.

---

### Alternative: In-process gateway inside Inline server

This is fine if:

- you are okay with Node-compat risk on Bun libs, or you implement protocols yourself
- you can ensure the process lifecycle is stable (no frequent restarts)

If you do this, treat it like OpenClaw:

- each provider has a `monitorXProvider({ abortSignal })`
- your main server owns an HTTP mux to dispatch webhooks to registered handlers
- provider monitors run in background tasks on boot and restart with backoff

---

## Part 4: Inline Data Model (What You Need To Persist)

You need persistence for:

- routing config (which external conversation maps to which Inline thread)
- idempotency (avoid duplicates)
- state (polling offsets / cursors)
- outbound delivery mapping (Inline message id <-> provider message id)

### Tables (suggested)

1. `integration_accounts`
   - id, provider (`telegram|slack|discord`), displayName
   - credentialsRef (not raw token) OR encrypted token blob
   - config JSON (mode, allowlists, etc)
   - enabled bool

2. `integration_routes`
   - id, accountId
   - providerConversationKey (eg `telegram:-100123/topic:77`, `slack:C123`, `discord:guild:G/channel:C`)
   - inlineSpaceId, inlineThreadId
   - direction (`inbound_only|outbound_only|bidirectional`)
   - filters (mention gating, bot-only, etc)

3. `integration_message_map`
   - id, routeId
   - providerMessageId (string)
   - inlineMessageId (Int64)
   - providerThreadKey (optional)
   - createdAt

4. `integration_idempotency`
   - provider, accountId, routeId (optional), eventId (string), firstSeenAt
   - unique(provider, accountId, eventId)
   - TTL cleanup job

5. `integration_state`
   - accountId, key (eg `telegram:last_update_id`), value (json), updatedAt

You can compress this, but don’t skip idempotency + message mapping.

---

## Part 5: Inline Normalized Event Model

Define a small internal schema, e.g.:

- `message.created`
- `message.edited`
- `message.deleted`
- `reaction.added`
- `reaction.removed`
- `member.joined` / `member.left` (optional)

Each event needs:

- `provider` + `accountId`
- `conversationKey` (provider-specific stable key)
- `eventId` (provider-specific idempotency key)
- `occurredAt` (provider timestamp if available)
- payload:
  - sender identity (provider user id + display)
  - message body + attachments (URLs, mime, etc)
  - threading context (reply-to, thread id, topic id)

The integration gateway should:

- map provider payload -> this normalized event
- validate auth/signatures before mapping
- dedupe by `(provider, accountId, eventId)`

---

## Part 6: Provider-Specific Implementation Notes (Inline)

### Telegram implementation notes

- Prefer **webhook mode** for production if Inline has a stable public endpoint.
  - Validate the `X-Telegram-Bot-Api-Secret-Token` header (set by `secret_token` in `setWebhook`).
  - Run a reverse proxy so Telegram can hit allowed ports.
- If you use **long polling**:
  - persist `lastUpdateId` (like OpenClaw) and skip any `update_id <= lastUpdateId`
  - run a per-chat queue so you don’t process edits/replies out of order
  - add a small TTL dedupe cache anyway

### Slack implementation notes

- If you need “works behind NAT”, implement **Socket Mode** first.
- If you need “no persistent websocket worker”, implement **HTTP Events API**.
- In HTTP mode:
  - verify request signature (signing secret)
  - respond quickly, enqueue processing async
  - use Slack’s event id as idempotency key
  - use retry headers to detect redelivery

### Discord implementation notes

- Use a mature gateway library (discord.js or similar) unless you want to implement heartbeats/resume yourself.
- Implement:
  - reconnect/backoff
  - HELLO timeout guard (OpenClaw’s approach is a good template)
- Treat message content privileged intent as an ops requirement; support a “mention-only” mode so you can operate without it.

---

## Part 7: A Practical Build Plan For Inline (Phased)

### Phase 0: Decide the product behavior

Pick one:

1. **Inbound-only mirror**: external -> Inline only (most secure).
2. **Outbound-only relay**: Inline -> external only (simpler, fewer auth issues).
3. **Two-way bridge**: bidirectional (hardest; needs loop prevention + message mapping).

If you do bidirectional, you must implement loop prevention:

- tag outbound messages (metadata store) and ignore the echoed inbound event
- or maintain a message_map and treat “same provider message id” as already synced

### Phase 1: Telegram inbound (webhook)

- Add `integration_accounts` + `integration_routes` + `integration_idempotency`.
- Add endpoint:
  - `/integrations/telegram/:accountId/webhook` (or by route)
- Validate secret header.
- Normalize `update` -> `message.created` etc.
- Create Inline message in the target thread.
- Store message_map (provider msg id <-> Inline msg id).

### Phase 2: Slack inbound (Socket Mode)

- Implement worker that connects via socket mode, subscribes to events.
- Normalize event payloads to the same model.
- Dedupe by Slack event id.

### Phase 3: Discord inbound (Gateway)

- Implement gateway worker.
- Start with:
  - DMs and a single channel allowlist.
- Normalize message create/update/delete and reactions.

### Phase 4: Outbound delivery (one provider at a time)

- Use `integration_message_map` so edits and replies can be mapped back to provider message ids.
- Implement provider formatting rules:
  - max message length, markdown subset, attachments
- Add outbound job retries with backoff.

### Phase 5: Admin + observability

- Admin UI for:
  - connecting accounts
  - creating routes (pick Inline thread, pick provider channel/chat)
  - allowlists + mention gating
- Observability:
  - per-provider ingest counters
  - per-route error counts
  - last inbound/outbound timestamps
  - dead-letter queue for failures

---

## Appendix: “Copy These Patterns From OpenClaw”

- `AbortSignal`-driven shutdown for long-running monitors:
  - Telegram: `src/telegram/monitor.ts`
  - Slack: `src/slack/monitor/provider.ts`
  - Discord: `src/discord/monitor/provider.ts`
- Telegram dedupe:
  - persisted offset + TTL cache: `src/telegram/update-offset-store.ts`, `src/telegram/bot-updates.ts`
- Slack HTTP mux / route registry (nice for multi-account webhook paths):
  - `src/slack/http/registry.ts`, `src/gateway/server-http.ts`
- Discord “HELLO timeout” stall detection:
  - `src/discord/monitor/provider.ts`
