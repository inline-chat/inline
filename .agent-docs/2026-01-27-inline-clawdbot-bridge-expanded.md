# Inline ↔ Clawdbot Bridge (Expanded Research Addendum) — 2026-01-27

This is an expanded research addendum to `.agent-docs/2026-01-26-inline-clawdbot-bridge.md`.
It deepens the analysis for hosted multi‑user, per‑space mapping, no streaming.

---

## 1) Architecture options (expanded)

### Option A: Inline-hosted Gateway WS client (WebChat-style)
**What it is:** Inline server connects to Clawdbot’s Gateway WS and uses `chat.*` to run the agent.

**Characteristics**
- **Tenancy:** Inline must isolate per space; Gateway sees one operator client and one or more sessions.
- **Routing:** Inline is responsible for mapping `spaceId → sessionKey` (per-space or per-thread).
- **Security:** Clawdbot DM policies, allowlists, and pairing are bypassed; Inline must enforce all access controls.
- **UX:** No streaming. Use `chat.send` and show an “answering” state until a `chat` event arrives with `state=final|error|aborted`.

**Risks**
- Cross-space context leaks if session mapping is wrong or if sessionKey collisions occur.
- Fewer safety rails from Clawdbot (no channel-level security gates).

**Best for**
- Fast MVP
- A single hosted gateway per region with Inline-managed routing

### Option B: Inline channel plugin (first-class channel)
**What it is:** A Clawdbot plugin that treats Inline as a channel (like Telegram/Slack), using standard channel adapters and outbound send.

**Characteristics**
- **Tenancy:** Clawdbot manages per-agent/per-session rules; Inline can pass space metadata.
- **Routing:** Uses standard inbound routing and session management; Clawdbot records session meta.
- **Security:** DM policies and allowlists are enforced by Clawdbot.
- **UX:** Same “answering” state (no streaming) but a “real channel” in Clawdbot.

**Risks**
- More moving parts; plugin lifecycle and distribution.
- Hosted model keys and data boundaries must be very clear.

**Best for**
- Correctness and long-term compatibility
- Multi-user environments that need guardrails

### Option C: Hybrid (Inline WS client + thin plugin later)
- Use Option A for MVP.
- Introduce Option B for long‑term correctness and security.

---

## 2) Tenancy isolation matrix

| Dimension | Single shared gateway | Per-space gateway | Notes |
| --- | --- | --- | --- |
| Cost | Low | High | Gateway per space increases infra cost. |
| Isolation | Medium | High | Per-space Gateway gives hard isolation. |
| Complexity | Medium | High | Managing many gateways is heavy. |
| Risk of cross-tenant leakage | Medium | Low | Shared gateway requires rigorous session mapping. |
| Rollout speed | Fast | Slow | Per-space gateways need provisioning + ops. |

**Recommendation:** Start with a shared gateway + strict session mapping; add per-space gateways only for enterprise or regulated spaces.

---

## 3) Session mapping strategy (per space)

### Baseline mapping (per space)
- `sessionKey = agent:<agentId>:inline:space:<spaceId>`

**Pros**
- Simplicity and consistent space context

**Cons**
- All threads share one context; unrelated threads may bleed into each other

### Upgrade path (per thread)
- `sessionKey = agent:<agentId>:inline:thread:<threadId>`

**Pros**
- Better isolation, less confusion in large spaces

**Cons**
- Loses cross-thread continuity

### Upgrade path (per thread + user)
- `sessionKey = agent:<agentId>:inline:thread:<threadId>:user:<userId>`

**Pros**
- Strong privacy boundaries

**Cons**
- No shared memory even within the same thread

**Recommendation:** Start per-space; add per-thread mode behind a config flag and migrate as needed.

---

## 4) Access model inside a space

You said: *“admin could install in a space and give access to all threads and users.”*

### Recommended enforcement at Inline layer (Option A)
- Installation grants access to all members of the space.
- Enforce mention gating by default:
  - Respond only if `@clawd` mention OR `/clawd` command OR slash entry.
- Maintain space-level allowlist (implicit: space membership).

### Recommended enforcement at Clawdbot layer (Option B)
- Use DM policy for direct conversations (if you support DMs from Inline).
- Use group/space allowlists (derived from space membership).
- Optionally require mention to trigger responses.

---

## 5) “Thinking/Answering” state (no streaming)

### Behavior (Option A)
- After `chat.send` responds with `status: started` → show “answering” state
- Clear on `chat` event with `state=final|error|aborted`

### Behavior (Option B)
- Plugin can emit typing indicators through Inline if supported
- Otherwise same “answering” state in Inline UI

---

## 6) Reliability + failure modes

### Gateway unreachable
- UI should show “offline” and queue/resume once WS reconnects.
- Retry policy: exponential backoff (as in `src/gateway/client.ts`).

### Duplicate messages
- Use Inline message id as `idempotencyKey` in `chat.send` to prevent duplicate runs.

### Aborts
- Use `chat.abort` to cancel long runs (e.g., user presses stop).

---

## 7) Security model (expanded)

### Gateway auth (non-optional)
- Always configure `gateway.auth.token` or `gateway.auth.password`.
- Avoid non-loopback binds unless behind Tailscale/SSH.

### Device tokens
- Persist device token from `hello-ok.auth.deviceToken`.

### Role/scopes
- Keep operator scopes minimal:
  - `operator.read`, `operator.write`
  - Avoid `operator.admin` unless needed

### Data handling
- Session transcripts live on Gateway host disk.
- If hosted, ensure encrypted disk and correct file permissions.

**Refs:** `docs/gateway/security.md`, `docs/gateway/protocol.md`

---

## 8) Hosting modes (multi-user)

### Shared hosted gateway
- Inline server is the only operator client.
- All spaces map to distinct `sessionKey`s.
- Model credentials can be per-tenant or shared.

### Per-space hosted gateway
- Provision on install.
- Assign unique gateway token and URL.
- Inline stores gateway connection details per space.

**Recommendation:** Shared gateway first; per-space gateway for premium tiers.

---

## 9) Cost + scaling considerations

### Scaling vectors
- **Concurrent WS connections** (operator clients)
- **Agent runs per minute** (LLM costs)
- **Session storage growth** (JSONL transcripts)

### Cost controls
- Session pruning/compaction (Clawdbot built‑in)
- Per-space rate limiting
- Max context caps or daily usage limits

---

## 10) Ops + observability

- Poll `health` or `status` via Gateway WS.
- Track last heartbeat event.
- Store per‑space metrics: last run time, last error, message counts, token usage (if surfaced).

---

## 11) Compliance + data boundaries (hosted)

- Define whether Inline or customer supplies model credentials.
- Clarify where transcripts live and who has access.
- Provide a deletion API: purge `sessionKey` from the gateway store.

---

## 12) Concrete “research‑only” deliverables checklist

- ✅ Protocol reference (Gateway WS)
- ✅ Method mapping (chat vs agent)
- ✅ Tenancy isolation matrix
- ✅ Session mapping strategies
- ✅ Access model recommendations
- ✅ Reliability + failure cases
- ✅ Security guardrails
- ✅ Hosting modes
- ✅ Cost + scaling concerns
- ✅ Ops + observability
- ✅ Compliance + data boundaries

---

## 13) Open choices to finalize (for later implementation)

1) Shared gateway or per‑space gateway?
2) Default mention gating on or off?
3) Session mapping stays per-space or moves to per-thread?
4) Model credentials provided by Inline or customer?

---

## Appendix: Source pointers

- Protocol: `docs/gateway/protocol.md`, `src/gateway/protocol/schema/frames.ts`
- Auth + device identity: `src/infra/device-identity.ts`, `src/gateway/device-auth.ts`
- Chat methods: `src/gateway/server-methods/chat.ts`, `docs/web/webchat.md`
- Plugin architecture: `docs/plugin.md`, `extensions/matrix/*`, `src/channels/plugins/types.*.ts`
- Security: `docs/gateway/security.md`, `docs/gateway/configuration.md`
