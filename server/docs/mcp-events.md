# Inline MCP Events

The API owns durable event subscriptions and delivers changes from Inline's existing update journals and an independent encrypted reaction log. The MCP service authenticates each request and proxies `events/list`, `events/subscribe`, and `events/unsubscribe`; it stores no subscription state or retained OAuth bearer. Clients using MCP `2026-07-28` can discover and call these methods without creating an HTTP session. Existing Streamable HTTP clients retain their core tools and session behavior. HTML app views are currently disabled, with source preserved; authenticated JSON conversation snapshot resources remain available.

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

The base catalog advertises 18 events. Once reaction capture is deployed to every writer and `MCP_REACTION_EVENTS_ENABLED=true`, it advertises 20:

- Messages: `message.created`, `message.updated`, `message.deleted`, `message.attachments.updated`, `message.history.cleared`, `message.acknowledgement.updated`.
- Chats: `chat.created`, `chat.updated`, `chat.visibility.updated`, `chat.moved`, `chat.participants.updated`, `chat.pins.updated`.
- Reactions (when enabled): `reaction.added`, `reaction.removed`.
- Personal state: `dialog.updated`.
- Spaces: `space.members.updated`, `space.profile.updated`, `space.settings.updated`, `space.history.cleared`.
- `inline.update`: the journaled message/chat or space changes above for one selected resource.

Typing and presence are excluded. `inline.update` continues to cover the native journal only; it does not combine the independently ordered reaction source. Resource deletion or lost access stops delivery; it does not emit a terminal callback. Polling, push streams and webhook control messages are not advertised.

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

## Reaction events

Subscribe to `reaction.added` or `reaction.removed` with `{ chatId, messageId?, emoji?, excludeSelf? }`. Optional `messageId` narrows to one message; omitted `messageId` watches the whole chat. Optional `emoji` matches one exact stored emoji, including variation selectors and skin tone. `excludeSelf: true` excludes the connected reacting user, regardless of who authored the message. All filters narrow the existing `messages:read` grant and current chat access. The persisted emoji filter is encrypted; resource IDs remain queryable subscription metadata.

```json
{
  "eventId": "<stable-event-id>",
  "name": "reaction.added",
  "timestamp": "2026-10-07T12:00:00.000Z",
  "cursor": "<opaque-reaction-cursor>",
  "data": { "kind": "reaction", "chatId": "123", "messageId": "456", "userId": "789", "emoji": "✅" }
}
```

Removal uses `reaction.removed` and `kind: "reactionDeleted"`, with the same required identifiers and emoji. Timestamps describe the transition, including removal time. Facts contain no message text, profiles or aggregate counts. Reaction filters and the independent source are bound to the cursor and subscription identity; message cursors cannot resume reactions. Existing non-reaction identity and cursor bytes retain their meaning.

The shared persistence model locks the chat before checking current access and changing state. A real insertion/removal increments `chats.mcp_reaction_seq` and appends an encrypted occurrence in the same transaction. Duplicate additions and absent removals do not advance it; failure rolls back the mutation and counter together. Capture also covers the legacy HTTP addition path and runs even with no subscriptions or with the catalog switch off. Native reaction fanout remains unsequenced and does not consume `chats.update_seq`.

The source reads counter and rows in one snapshot and checks gaps before applying filters. Nonmatches advance the scan position without callbacks. Replay follows committed order within one chat; delivery is at least once. There is no ordering contract across subscriptions or between message and reaction sources. Read tools return current `reactions: [{ userId, emoji }]`; a fully hydrated empty set is `[]`. Read current state before taking a present-state action: an old addition can already have been removed or its message deleted.

Retention targets 24 hours. Each existing worker deletes at most 1,000 expired rows per minute using `SKIP LOCKED`; a cleanup backlog can extend retention, so this is not a hard storage ceiling. The owner counter survives expiry of the final row, allowing complete-expiry and interior gaps to pause delivery. Refresh then returns `truncated: true` and the current head. Pending encrypted deliveries retain the existing subscription recovery lifetime independently of source expiry. Status omits gapped subscriptions; there is no immediate gap callback. Current state cannot reconstruct missed transitions.

Message/history clearing and account deletion do not synthesize one removal per cascaded reaction. Explicit retained occurrences can refer to an absent message or actor. Chat deletion cascades its reaction log, and current access checks fence delivery.

### Capture rollout

Apply the single forward migration, deploy transactional capture to **every** reaction writer with exposure off, and drain old API processes before enabling `MCP_REACTION_EVENTS_ENABLED=true` on the Events API/worker fleet. New subscriptions start at the current head, with no historical backfill promise before activation. Disabling the switch hides reaction definitions, blocks registration/checkpoints, skips reaction claims and fences an in-flight callback at its next authority check. Unsubscribe remains available; pending state is preserved for existing recovery rules.

The gate does not detect omissions by older writers. Before restoring old code, disable reaction exposure everywhere. A rollback to older writers invalidates replay completeness across that interval: retire affected reaction subscriptions and restart from fresh checkpoints after all capture-capable writers return. Do not silently reuse old checkpoints or claim complete replay across a mixed-writer interval. Keep the release off until this ordering is verified operationally, then rescan the host catalog and qualify actual ChatGPT continuation.

## Consultation and core thread reads

`conversations.ask` creates a private thread with the connected user and resolved participants, captures a `message.created` cursor **before** sending one question, and returns the exact subscription arguments/cursor. The host subscribes, waits, reads the current reply and resumes its originating task. A confirmed chat survives later failure; `questionStatus` distinguishes `sent`, `not_sent` and `unknown`. The host must not automatically retry an uncertain write.

The host may expose registration through an Automations event trigger. `events/subscribe` is the MCP protocol method the host invokes, not a required Inline tool name; callback configuration can remain internal to the host. Pass the returned cursor unchanged when the host accepts one. When it has no cursor field, register the exact event/arguments first, obtain acknowledgement, then make one `messages.context` read anchored at the confirmed question `messageId` with `before: 0`, `after: 50`, `includeAnchor: false`, and `content: all`. This checks pre-registration replies while the acknowledged subscription covers later changes. Deduplicate overlapping replies by chat/message ID and deliveries by event ID. This is a bounded current-state check, not full journal replay: disclose a failed read, missing anchor or full window, and do not poll. Without a confirmed question receipt, inspect the existing thread once after registration; do not invent an anchor or automatically repeat the question. Stop only this task's registration through the host mechanism once a one-shot consultation is fulfilled.

`conversations.open` remains a core read tool returning recent history, direct participants and subscription status as structured data. It does not open an app view; `{}` returns an empty thread payload. The current service exposes no HTML app resources, message cards, desktop conversation mentions or UI entrypoints. The authenticated `inline://chat/{chatId}` JSON snapshot resource remains enabled. The deferred app source remains preserved and unused. A thread read is not background task continuation.

Monitoring status covers the connected OAuth grant and Inline thread. It does not identify the originating ChatGPT task: another task using the same connection can own that subscription. Only the host's own subscription acknowledgement establishes that this task is waiting.

OpenAI's current [MCP Events documentation](https://developers.openai.com/plugins/build/mcp-events) describes continuation for Work web, desktop Work with Cloud selected, and dots. Qualify ordinary ChatGPT Chat support separately. Real host refresh/consent, event receipts and resumed task behavior require signed-in host acceptance in addition to local persistence tests.

## Validation and release order

Build `packages/protocol`, `packages/oauth-core`, `packages/sdk`, then `packages/mcp` before running the paired backend HTTP tests. The MCP build still compiles the retained, disabled `plugins/chatgpt/ui` dependency; the independent server CI job builds this graph explicitly. Run the normal isolated PostgreSQL test runner for `src/modules/mcpEvents`, plus the server Effect/route/OpenAPI checks and core MCP suite. The compiled contract verifies that no HTML app resources or UI metadata are advertised.

Deploy the API migration and worker first through the qualified server release workflow. Then deploy the matching compiled MCP image, verify legacy and modern authenticated paths, and qualify the host. No app view is enabled by this release. `MCP_UI_RESOURCE_DOMAINS` remains configuration for deferred UI work, not a core Events requirement.
