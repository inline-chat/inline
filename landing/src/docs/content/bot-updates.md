---
title: "Receive Bot Updates"
description: "Receive, process, and acknowledge Bot API updates with polling or webhooks."
---

A bot update describes an event delivered to your integration, such as a new message or a button action. Use this guide to receive your first update and decide when it is safe to acknowledge it.

Before you begin, [create a bot and verify its token](/docs/creating-a-bot#verify). The HTTP examples use Bot API `0.1`, curl, a POSIX-compatible shell, and `INLINE_BOT_TOKEN` in the environment. Check `ok` on every API response; curl's exit status alone does not establish API success.

## About Update Delivery

Inline keeps a queue for each bot. Polling and webhooks consume the same queue; setting a webhook disables polling. Choose one consumer for each bot:

| Mode | Use it when | Acknowledgement |
| --- | --- | --- |
| [Polling](#polling) | You can keep a process running to request batches. | A subsequent `getUpdates` request supplies an offset above the updates you have handled. |
| [Webhook](#webhook) | You have a publicly reachable HTTPS handler. | Your handler returns an HTTP `2xx` response. |

Initialize delivery before sending a test message. Messages sent before the first poll or webhook setup are not backfilled. The queue retains updates for up to 24 hours and has [size limits](/docs/bot-api#updates), so it is not a permanent event archive.

Delivery is at least once while updates remain available. Receiving an update and recording its result are separate operations: a crash or lost response can cause delivery to repeat. Use `(bot identity, update_id)` as your deduplication key, and make repeated handling safe.

## Polling

### Receive Your First Update

1. Initialize the queue with a nonblocking request:

```bash
curl -sS --max-time 15 "https://api.inline.chat/bot/getUpdates?timeout=0&limit=20" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN:?Set INLINE_BOT_TOKEN}"
```

An empty new queue returns `{"ok":true,"result":[]}`. If the response reports `WEBHOOK_ACTIVE`, use the existing webhook or [switch to polling](#switch-delivery-modes).

2. From your human Inline account, send the bot a new direct message.
3. Request the next batch, allowing the server to wait for an update:

```bash
curl -sS --max-time 35 "https://api.inline.chat/bot/getUpdates?timeout=25&limit=20" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN:?Set INLINE_BOT_TOKEN}"
```

For a message update, inspect `result[].update_id` and `result[].message.text`. An empty array means no eligible update was available before the wait ended. The HTTP deadline must exceed `timeout` to allow for network and server processing time.

These requests omit `offset`, so they do not acknowledge the returned batch. Repeating them can return the same updates.

### Process and Acknowledge a Batch

An offset is the next update ID you want to receive. **Supplying offset `N` acknowledges every earlier update**, including updates your application has not processed. Advance it only after you have durably handled the preceding work.

Use the following algorithm when implementing a consumer with your own durable storage:

1. Load the saved offset for this bot; omit it on the first request.
2. Call `getUpdates` with that offset and wait for the response.
3. Handle updates in increasing `update_id` order. IDs can have gaps.
4. For each update, complete the work or durably enqueue it. Record the deduplication key with the work so a restart cannot apply it twice.
5. Save one above the last successfully handled ID. Stop at the first failure; do not advance past it.
6. Poll again with the saved offset. Leave it unchanged when a batch is empty.

For example, if updates `100` and `102` succeed but `105` fails, save offset `103`. The next request acknowledges `100` and `102` and allows `105` to be delivered again. Do not save `106` until `105` is durably handled.

On a network failure, retry with your saved offset. Stop the polling loop when the process shuts down and resume from durable state on restart. Keep one poll in flight per bot. If handling sends messages or calls another service, also account for a failure after that side effect succeeds: update deduplication alone cannot make an external operation atomic.

### Polling Parameters

| Parameter | Behavior |
| --- | --- |
| `offset` | Omit initially. For normal consumption, send one above the last durably handled update ID. |
| `timeout` | Maximum wait in seconds, from `0` to `50`; default `0`. The server can return sooner when updates are available. |
| `limit` | Maximum updates per response, from `1` to `100`; default `100`. The response size limit can produce a smaller batch. |

For the complete parameter contract, including special offset values, use the [method reference](https://api.inline.chat/bot-api-reference).

## Webhook

### Prepare the Handler

Your HTTPS handler receives a JSON `BotUpdate` body. Before registering it:

1. Configure a secret shared by the registration code and the handler. Reject requests whose `x-inline-bot-api-secret-token` is missing or does not match; compare secrets in constant time.
2. Deduplicate by bot identity and `update_id`. Deliveries can be concurrent and out of order, so enforce uniqueness in durable storage.
3. Finish the work or durably enqueue it before returning `2xx`. If storage or processing fails before that point, return a failure response so Inline can retry.

The webhook request timeout is 10 seconds. For work that takes longer, acknowledge after a durable enqueue and let your own worker handle retries. A `2xx` response tells Inline that it can stop delivering that update.

### Register and Verify the Webhook

Use Bun with the `@inline-chat/bot-client` `0.1.x` client; follow the [client installation instructions](/docs/bot-api#typescript-client). Set `INLINE_WEBHOOK_URL` to your handler's public HTTPS URL and set `INLINE_WEBHOOK_SECRET` to the same nonempty secret configured in the handler. Save this as `webhook.ts`:

```ts
import { InlineBotClient } from "@inline-chat/bot-client"

const token = process.env.INLINE_BOT_TOKEN
const url = process.env.INLINE_WEBHOOK_URL
const secret = process.env.INLINE_WEBHOOK_SECRET
if (!token || !url || !secret) {
  throw new Error("Set INLINE_BOT_TOKEN, INLINE_WEBHOOK_URL, and INLINE_WEBHOOK_SECRET")
}

const bot = new InlineBotClient({ token })
const registered = await bot.setWebhook(
  { url, secret_token: secret, message_trigger: "mentions" },
  { signal: AbortSignal.timeout(15_000) },
)
if (!registered.ok) {
  throw new Error(`${registered.error_code}: ${registered.description}`)
}
console.log("Webhook registered")
```

Run it only after the handler is ready:

```bash
bun run webhook.ts
```

`Webhook registered` confirms that Inline accepted the configuration. It does not verify the handler's response. Send a fresh human DM to the bot, then confirm that the handler durably stored or processed its update.

If registration fails or times out, inspect the configuration before retrying; the request may already have taken effect:

```bash
curl -sS --max-time 15 "https://api.inline.chat/bot/getWebhookInfo" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN:?Set INLINE_BOT_TOKEN}"
```

Check `result.url`, `pending_update_count`, `last_error_message`, and `dropped_update_count`. Fix validation errors before registering again. A growing pending count usually means that the handler cannot be reached or is not acknowledging delivery.

### Webhook Delivery Reference

| Header or response | Meaning |
| --- | --- |
| `x-inline-bot-api-secret-token` | The secret supplied at registration. Verify it before processing the body. |
| `x-inline-update-id` | The update ID, stable across retries. |
| `x-inline-attempt` | Delivery attempt number, starting at `1`. |
| HTTP `2xx` | Acknowledges delivery; Inline stops retrying this update. |
| Failure response or request timeout | Inline retries while the update remains available. Numeric `Retry-After` on `429` or `503` is honored, capped at one hour. |

### Switch Delivery Modes

To switch to polling, call `deleteWebhook` and stop using the webhook consumer before starting the polling loop. To switch to webhooks, prepare the handler, stop your polling loop, and call `setWebhook`. Account for requests already in flight and keep deduplication active during the transition.

Both methods retain pending updates by default. Use `drop_pending_updates: true` only when you intend to discard the backlog; discarded work cannot be recovered from the queue.

## Update Selection

Two settings control selection: `allowed_updates` chooses event kinds, and `message_trigger` controls which messages activate the bot. Configure them through `getUpdates` or `setWebhook`; omitted settings keep the existing configuration.

| Setting | Initial behavior |
| --- | --- |
| `allowed_updates` | Includes `message`, `edited_message`, `message_action`, and `bot_participation`. An empty list restores these defaults. |
| `message_trigger` | Defaults to `mentions`: human DMs, resolved mentions, replies to the bot, and commands addressed to it activate message delivery. Human messages in a thread assigned to that bot as its agent also activate it. |

To receive reactions, explicitly include `message_reaction` in `allowed_updates` along with the other kinds you need. Supplying a list replaces the previous selection. Changing selection does not backfill earlier events.

Message actions are delivered as `message_action` updates. Messages from another bot require a structured, identity-resolved mention, even with `message_trigger: "all"`. Access to the conversation still applies; selection settings do not grant access.

## Checks

| Symptom | Recovery |
| --- | --- |
| `WEBHOOK_ACTIVE` | Keep the webhook, or call `deleteWebhook` before polling. |
| `POLL_CONFLICT` | Check for a second poller or a delivery configuration change. Keep one consumer and one active poll per bot. |
| Empty new queue | Initialize delivery, then send a fresh human DM. |
| Repeated update | Check the saved offset or webhook acknowledgement, and use durable deduplication. Repeats are expected after an uncertain delivery. |
| Missing thread message | Check conversation access, `message_trigger`, `allowed_updates`, and whether a mention resolves to the bot. |
| Growing webhook backlog | Check HTTPS reachability, secret validation, and handler failures; inspect `getWebhookInfo`. |
| Missing updates after downtime | Check `dropped_update_count` and [queue limits](/docs/bot-api#updates). Expired or discarded updates cannot be replayed from this queue. |

## Next Steps

Once you can receive and durably handle an update, use the [Bot API guide](/docs/bot-api#typescript-client) to send a reply. Keep the [method reference](https://api.inline.chat/bot-api-reference) available for exact request and response fields.
