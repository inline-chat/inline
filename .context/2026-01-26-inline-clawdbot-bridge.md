# Clawdbot ↔ Inline Bridge: Comprehensive Requirements + Design (2026-01-26)

## Executive summary
Inline can integrate with Clawdbot in two viable ways:

- **Option A (WebChat-style client):** Inline acts as a Gateway WebSocket client and uses `chat.*` methods. This is the fastest path and requires **no Clawdbot plugin**, but it behaves like a single “operator UI” and does not use channel allowlists/pairing rules.
- **Option B (Inline channel plugin):** Build a Clawdbot channel plugin (extension) that connects to Inline as a messaging surface. This yields a **first‑class channel** with allowlists, pairing, routing, and outbound delivery, and is the best fit for multi-user use inside Inline.
- **Option C (Hybrid):** Inline server runs the Gateway client from Option A and exposes it to Inline clients; reduces direct network exposure but still behaves like WebChat.

**Recommendation:** If Inline needs multi-user or per-space isolation, implement **Option B**. If Inline is a personal UI for a single user running Clawdbot locally, **Option A** is sufficient.

---

## Primary sources (local)

Use these files as the canonical references:

- Protocol + auth: `docs/gateway/protocol.md`, `src/gateway/protocol/schema/*.ts`, `src/gateway/client.ts`, `src/infra/device-identity.ts`, `src/gateway/device-auth.ts`
- WebChat behavior: `docs/web/webchat.md`, `src/gateway/server-methods/chat.ts`
- Sessions + routing: `docs/concepts/session.md`, `docs/concepts/messages.md`, `src/channels/session.ts`, `src/routing/resolve-route.ts`
- Channel plugin SDK: `docs/plugin.md`, `src/plugin-sdk/index.ts`, `src/channels/plugins/types.*.ts`, `extensions/matrix/*` (plugin example)
- Gateway server method list: `src/gateway/server-methods-list.ts`
- Security posture: `docs/gateway/security.md`, `docs/gateway/configuration.md`

---

## 1) Gateway WS protocol essentials (what Inline must implement)

### Transport + framing
- **WebSocket text frames** with JSON payloads.
- **First frame must be `connect`**.
- Frame types:
  - Request: `{ type: "req", id, method, params }`
  - Response: `{ type: "res", id, ok, payload|error }`
  - Event: `{ type: "event", event, payload, seq?, stateVersion? }`

Ref: `docs/gateway/protocol.md`, `src/gateway/protocol/schema/frames.ts`

### Handshake flow
1) Gateway sends `connect.challenge`:
```json
{ "type": "event", "event": "connect.challenge", "payload": { "nonce": "…", "ts": 1737264000000 } }
```

2) Client sends `connect`:
```json
{
  "type": "req",
  "id": "…",
  "method": "connect",
  "params": {
    "minProtocol": 3,
    "maxProtocol": 3,
    "client": {
      "id": "inline-client",
      "version": "1.0.0",
      "platform": "server",
      "mode": "operator"
    },
    "role": "operator",
    "scopes": ["operator.read", "operator.write"],
    "auth": { "token": "…" },
    "device": {
      "id": "device_fingerprint",
      "publicKey": "…",
      "signature": "…",
      "signedAt": 1737264000000,
      "nonce": "…"
    }
  }
}
```

3) Gateway replies `hello-ok`:
```json
{ "type": "res", "id": "…", "ok": true, "payload": { "type": "hello-ok", "protocol": 3, "policy": { "tickIntervalMs": 15000 } } }
```

If device tokens are issued, `hello-ok.auth.deviceToken` is returned and should be persisted.

Ref: `docs/gateway/protocol.md`, `src/gateway/client.ts`

### Roles + scopes (Inline should be operator)
- **operator** role for UI/server clients
- Common scopes: `operator.read`, `operator.write` (add `operator.admin`, `operator.approvals`, `operator.pairing` only if needed)

Ref: `docs/gateway/protocol.md`

### Device identity + signatures
- Device identity is **ed25519 keypair**.
- `device.id` is `sha256(publicKeyRaw)`.
- `device.signature` signs `buildDeviceAuthPayload` string.

Ref: `src/infra/device-identity.ts`, `src/gateway/device-auth.ts`

### Events to handle
From `src/gateway/server-methods-list.ts`:
- `chat` — WebChat-style responses
- `agent` — low-level agent event stream
- `presence`, `tick`, `shutdown`, `health`, `heartbeat`

Inline should at minimum handle `chat`, `tick`, `shutdown`, and optionally `agent` (for streaming).

---

## 2) Which Gateway methods Inline will use

### WebChat-style (Option A/C)
Use `chat.*` methods for a simple chat UI.

- `chat.history` — fetch transcript for `sessionKey`
- `chat.send` — send user message to agent (no streaming; see below)
- `chat.abort` — stop current run
- `chat.inject` — append assistant note to transcript

Refs: `docs/web/webchat.md`, `src/gateway/server-methods/chat.ts`, `src/gateway/protocol/schema/logs-chat.ts`

**Important:** `chat.send` sets `disableBlockStreaming: true` in `src/gateway/server-methods/chat.ts`. You should expect **final-only** responses (`state: "final"`) rather than incremental deltas.

### Agent-style (if streaming is required)
Use `agent` and listen for `agent` events.

- `agent` — start a run; returns an “accepted” response and later a final response
- `agent.wait` — wait for completion
- `agent.identity.get` — resolve display identity

Refs: `src/gateway/server-methods/agent.ts`, `src/gateway/protocol/schema/agent.ts`

### Sessions
- `sessions.list` — list recent sessions for UI
- `sessions.preview` — short previews
- `sessions.patch` — label, model override, send policy, etc.

Ref: `src/gateway/protocol/schema/sessions.ts`

---

## 3) Session mapping (critical for Inline UX)

Clawdbot session keys are the **source of truth**. For multi-user Inline, avoid `main` DM scope.

### Recommended mapping
Set gateway config:
```json5
{ session: { dmScope: "per-channel-peer" } }
```

Then map Inline identities to session keys:
- DM: `agent:<agentId>:inline:dm:<inlineUserId>`
- Group: `agent:<agentId>:inline:group:<inlineRoomId>`
- Channel/space: `agent:<agentId>:inline:channel:<inlineChannelId>`

Use `session.identityLinks` if the same human appears across multiple Inline identities.

Ref: `docs/concepts/session.md`

### Why this matters
- Prevents cross-user context leaks.
- Preserves per-conversation history and routing metadata.

---

## 4) Message mapping (Inline ↔ Clawdbot)

### Inbound (Inline → Clawdbot)

#### Option A/C (chat.send)
- `sessionKey`: derived from Inline conversation mapping
- `message`: raw user text
- `idempotencyKey`: **Inline message id** (use a stable unique id)
- `attachments`: base64 content (size limit ~5MB in `chat.send`)

Ref: `src/gateway/server-methods/chat.ts` (normalizes attachments, maxBytes 5_000_000)

#### Option B (channel plugin)
Construct a full inbound context using plugin runtime helpers (see `extensions/matrix/src/matrix/monitor/handler.ts` for a concrete pattern):

Required fields to set in `finalizeInboundContext`:
- `Body`, `RawBody`, `CommandBody`
- `From`, `To`, `ChatType`, `SessionKey`
- `Provider`, `Surface`, `OriginatingChannel`
- `SenderName`, `SenderId`, `SenderUsername`
- `GroupSubject`, `GroupChannel`, `GroupSpace` for group contexts

Then call `recordInboundSession` and `dispatchInboundMessage`.

Ref: `extensions/matrix/src/matrix/monitor/handler.ts`

### Outbound (Clawdbot → Inline)

#### Option A/C
Listen for `event: "chat"` and map payload to Inline message.

`ChatEvent` shape (`src/gateway/protocol/schema/logs-chat.ts`):
- `state: "final" | "error" | "aborted"`
- `message`: transcript-style object (role, content array)

Inline should:
- render `message.content[].text` into the chat
- if `state=error`, surface `errorMessage`

#### Option B
Implement `ChannelOutboundAdapter` (see `extensions/matrix/src/outbound.ts`) and call Inline APIs to send text/media. Include:
- `replyToId`, `threadId`
- file attachments or inline media

---

## 5) Authentication + network posture (must-haves)

### Gateway auth (required by default)
- Use `gateway.auth.mode` = `token` or `password`
- Use `gateway.auth.token` or `gateway.auth.password`
- **Non-loopback binds require auth**

Ref: `docs/gateway/configuration.md`

### Remote access
- Prefer loopback + SSH/Tailscale
- Inline clients can connect to `ws://127.0.0.1:18789` over a tunnel

Ref: `docs/gateway/remote.md`

### Device tokens
- Persist `hello-ok.auth.deviceToken` per device+role
- Reuse on reconnects

Ref: `docs/gateway/protocol.md`, `src/gateway/client.ts`

---

## 6) Option A/C implementation blueprint (Inline as Gateway WS client)

### Core components
1) **GatewayConnection** (WS lifecycle)
   - Handles reconnect
   - Sends `connect` after `connect.challenge`
   - Stores device identity + device token

2) **SessionMapper**
   - Maps Inline conversation ids to Clawdbot session keys
   - Caches `sessions.list` and optionally uses `sessions.patch` for labels

3) **ChatBridge**
   - Uses `chat.history` for transcript
   - Uses `chat.send` for new messages (idempotencyKey = Inline message id)
   - Listens for `chat` events and routes to the appropriate Inline conversation

### Reference code
- Client logic: `src/gateway/client.ts`
- Chat behavior: `src/gateway/server-methods/chat.ts`

### Pros
- Minimal Clawdbot changes
- Fast to implement

### Cons
- Not a true “channel”; skips DM policy / allowlists
- No block streaming (unless you use `agent` events instead)

---

## 7) Option B implementation blueprint (Inline channel plugin)

### Plugin skeleton
Directory (example): `extensions/inline/`
- `clawdbot.plugin.json`
- `index.ts`
- `src/channel.ts`
- `src/runtime.ts`
- `src/outbound.ts`

Use `extensions/matrix` as a template.

### Required ChannelPlugin fields
- `meta` (id, label, docsPath, blurb, etc.)
- `capabilities`
- `config` (listAccountIds, resolveAccount, allowFrom)
- `security` (dmPolicy, allowFrom)
- `gateway.startAccount` (start Inline connection)
- `outbound` (send text/media to Inline)
- `pairing` (pairing approval message to Inline user)
- optional `directory` and `resolver`

Ref: `src/channels/plugins/types.plugin.ts`, `extensions/matrix/src/channel.ts`

### Inbound flow (pseudo)
1) Inline message arrives via webhook or WS.
2) `resolveAgentRoute` → { agentId, sessionKey, accountId }
3) Build envelope and `finalizeInboundContext`.
4) `recordInboundSession` to update session metadata.
5) `dispatchInboundMessage` to run the agent.

Ref: `extensions/matrix/src/matrix/monitor/handler.ts`

### Outbound flow
`ChannelOutboundAdapter.sendText/sendMedia` calls Inline API.

Ref: `extensions/matrix/src/outbound.ts`

### Config + install
- Add plugin manifest (`clawdbot.plugin.json`) and enable via `plugins.entries.inline.enabled: true`.
- Provide config in `plugins.entries.inline.config` (Inline base URL, auth tokens, workspace mapping).

Ref: `docs/plugin.md`

### Pros
- First-class channel with allowlists, pairing, routing
- Clean multi-user support

### Cons
- More work (plugin + Inline API surface)

---

## 8) Security + multi-user safety

If Inline exposes Clawdbot to multiple users:
- Use `session.dmScope = "per-channel-peer"`.
- Keep `tools` restricted (consider sandbox + allowlists).
- Prefer `dmPolicy = "pairing"` or `allowlist` for Inline channel.

Ref: `docs/gateway/security.md`, `docs/concepts/session.md`

---

## 9) Implementation checklist

### Inline backend
- Add `clawdbot_integrations` table (gateway url, auth token, TLS fingerprint, device id/token, agent id).
- Add `clawdbot_sessions` table (Inline conversation ↔ Clawdbot session key mapping).
- Create `ClawdbotGatewayClient` (WS, reconnect, request/response correlation).
- Add `ClawdbotBridge` service to send/receive messages.

### Inline clients
- UI for gateway setup (URL + token/password).
- Show status and last heartbeat.
- Optional: session list + pinning to Inline threads.

### Clawdbot (Option B)
- Create plugin package (see `extensions/matrix`).
- Implement channel adapter and outbound adapter.
- Provide onboarding docs + config schema.

---

## 10) Open decisions (please confirm)

1) **Integration style:** WebChat client (Option A) or channel plugin (Option B)?
2) **Who owns the gateway?** Per-user local gateway, or a shared hosted gateway?
3) **Streaming requirement:** Do we need partial streaming? If yes, use `agent` events.
4) **Mapping granularity:** Per Inline user, per space, or per channel?
5) **Security posture:** Do we enforce pairing/allowlists for Inline users?

---

## Appendix: Minimal WS client behavior (Option A)

1) Open WS to `ws://127.0.0.1:18789` (or remote).
2) Wait for `connect.challenge`.
3) Send `connect` with token + device identity.
4) On `hello-ok`, store `deviceToken`.
5) Use `chat.history` / `chat.send` / `chat.abort`.
6) Listen for `event: "chat"` and route by `sessionKey`.

Ref: `docs/gateway/protocol.md`, `src/gateway/client.ts`, `docs/web/webchat.md`
