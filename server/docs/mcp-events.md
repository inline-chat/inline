# Inline MCP Events

The API owns durable event subscriptions and delivers changes from Inline's existing update journals. The MCP service authenticates each request and proxies `events/list`, `events/subscribe`, and `events/unsubscribe`; it stores no subscription state or retained OAuth bearer. Clients using MCP `2026-07-28` can discover and call these methods without creating an HTTP session. Existing Streamable HTTP clients retain their tools, resources, and session behavior.

## Contract

The catalog advertises webhook delivery. Chat selectors require an authorized `chatId`; space selectors require an authorized `spaceId`. IDs are decimal strings. `message.created` and `message.updated` accept `excludeSelf: true`. `dialog.updated` covers the connected user's personal state for one selected chat. No selector grants account-wide history or access outside the current OAuth grant.

```json
{
  "method": "events/subscribe",
  "params": {
    "name": "message.created",
    "arguments": { "chatId": "123", "excludeSelf": true },
    "delivery": {
      "mode": "webhook",
      "url": "https://host.example.com/inline-callback",
      "secret": "whsec_<base64-signing-key>"
    },
    "cursor": "<opaque-replay-cursor>",
    "ttlMs": 300000
  }
}
```

Modern requests additionally carry the protocol's per-request `_meta` and mirrored HTTP headers. The MCP proxy consumes that metadata before invoking the strict internal API. Subscription responses contain `id`, `cursor`, `truncated`, and a finite ISO `refreshBefore`. Renew the same event/arguments/callback identity before that deadline. Without a cursor, an existing identity retains its acknowledged position; a new identity starts at the current tail. Explicit cursors are bound to the grant, selector and journal bucket. A default lease is five minutes; `ttlMs: null` or a larger requested value receives at most one day. Each grant permits 64 active and 1,024 retained subscription identities. Expired records have a 24-hour recovery grace, then bounded cleanup removes them.

Use the identical event name, arguments and callback URL to unsubscribe, with `delivery: { "mode": "webhook", "url": "..." }`. No signing secret is needed for unsubscribe. Unsubscribe, expiry, token/session revocation and loss of resource access fence further claims and delivery.

Unsubscribe is idempotent: an already absent or expired-and-purged identity succeeds with `{}`. It never affects another grant's matching selector/callback.

The 18 advertised events are:

- Messages: `message.created`, `message.updated`, `message.deleted`, `message.attachments.updated`, `message.history.cleared`, `message.acknowledgement.updated`.
- Chats: `chat.created`, `chat.updated`, `chat.visibility.updated`, `chat.moved`, `chat.participants.updated`, `chat.pins.updated`.
- Personal state: `dialog.updated`.
- Spaces: `space.members.updated`, `space.profile.updated`, `space.settings.updated`, `space.history.cleared`.
- `inline.update`: the journaled message/chat or space changes above for one selected resource.

Typing, presence and reactions currently have no durable journal replay and are excluded. Resource deletion or lost access stops delivery; it does not emit a terminal callback. Polling, push streams and webhook control messages are not advertised.

The legacy `chat.created` name follows the journal's `newChat` marker, which also refreshes surviving chats after orphaning or detachment. It is not proof of a newly created chat. `chat.updated` includes these metadata snapshots as well as title, emoji and agent-context changes; no subscription names were removed.

## Receipt, recovery and authority

The verification challenge and occurrences use Standard Webhooks headers (`webhook-id`, `webhook-timestamp`, `webhook-signature`) plus `x-mcp-subscription-id`. Verification requires a signed challenge echo. Every connection validates public HTTPS DNS targets, pins the validated address while preserving TLS hostname verification, refuses redirects and has a deadline. Verification response bodies are bounded; ordinary occurrence receipts are decided at HTTP response headers.

Occurrences contain a stable `eventId`, `name`, `timestamp`, opaque `cursor` and reference-only `data`, for example:

```json
{
  "eventId": "<stable-event-id>",
  "name": "message.created",
  "timestamp": "2026-10-02T12:00:00.000Z",
  "cursor": "<opaque-replay-cursor>",
  "data": { "kind": "newMessage", "chatId": "123", "messageId": "456" }
}
```

Read the current message with `messages.context`; callbacks never reconstruct historical text or contain credentials. Consumers deduplicate `eventId`, tolerate redelivery and retain their last processed cursor. A callback's 2xx receipt atomically advances the stored watermark after another authorization check. A 410 or 413 settles that occurrence only. Other failures retry the same encrypted pending occurrence, with bounded backoff, `Retry-After` for 429/503, and a 12-attempt budget. Renewal reactivates an exhausted identity without losing its pending occurrence. Signing-key rotation overlaps the prior key for one minute.

Workers claim with `SKIP LOCKED`, finite leases and generation fences, so multiple API processes can deliver without sharing memory. A process restart preserves the pending occurrence and replay position. A retention gap pauses the subscription; renewal returns `truncated: true` and a fresh cursor. Read current thread state before waiting again. Never infer complete replay across that boundary.

Ordinary renewal preserves a pending delivery's backoff and `Retry-After` deadline. Renewing the lease does not ask the callback to accept an earlier retry.

The internal authenticated `POST /oauth/mcp-events` uses the existing MCP shared secret and derives authority from the supplied OAuth access token. Only the MCP service invokes internal `events/cursor` (capture the pre-question watermark) and `events/status` (confirmed active monitoring for a selected thread). Grants, sessions, current context, scopes and resource access are rechecked before callback connection and acknowledgement.

## Consultation and optional UI

`conversations.ask` creates a private thread with the connected user and resolved participants, captures a `message.created` cursor **before** sending one question, and returns the exact subscription arguments/cursor. The host subscribes, waits, reads the current reply and resumes its originating task. A confirmed chat survives later failure; `questionStatus` distinguishes `sent`, `not_sent` and `unknown`. Neither the host nor the thread composer should automatically retry an uncertain write.

`conversations.open` serves one React thread view with history, direct participants, a text composer, known media links and bounded selected excerpts for ChatGPT. Its small picker remembers only threads explicitly opened in that app experience. It has no workspace catalog, global unread sync, full sidebar or separate web login. Monitoring is displayed only after the API reports an active unexpired subscription; UI refresh is not background task continuation.

Monitoring status covers the connected OAuth grant and Inline thread. It does not identify the originating ChatGPT task: another task using the same connection can own that subscription. Only the host's own subscription acknowledgement establishes that this task is waiting.

OpenAI's current [MCP Events documentation](https://developers.openai.com/plugins/build/mcp-events) describes continuation for Work web, desktop Work with Cloud selected, and dots. Qualify ordinary ChatGPT Chat support separately. Real host refresh/consent, event receipts and resumed task behavior require signed-in host acceptance in addition to local persistence tests.

## Validation and release order

Build `packages/protocol`, `packages/oauth-core`, `packages/sdk`, then `packages/mcp` before running the paired backend HTTP tests. The MCP build includes `plugins/chatgpt/ui`; the independent server CI job builds this graph explicitly. Run the normal isolated PostgreSQL test runner for `src/modules/mcpEvents`, plus the server Effect/route/OpenAPI checks and MCP/UI suites.

Deploy the API migration and worker first through the qualified server release workflow. Then deploy the matching compiled MCP image, verify legacy and modern authenticated paths, and qualify the host. Exact HTTPS asset origins for signed media belong in `MCP_UI_RESOURCE_DOMAINS`; the default photo origin is `https://api.inline.chat`. Do not grant wildcard network access or expose storage credentials to the widget.
