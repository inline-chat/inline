---
title: "Receive Bot Updates"
description: "Choose polling or webhooks, acknowledge updates safely, and diagnose missing or repeated deliveries."
---

Start with a working [bot token and first message](/docs/bot-api#first-message). Use a dedicated bot for development so a test consumer does not take updates from a running integration.

## Choose One Delivery Method

| Method | Use when | Requirement |
| --- | --- | --- |
| `getUpdates` | Running a local process or worker | One active long poll per bot; persist the processing offset. |
| Webhook | Running an HTTP service | A reachable HTTPS handler that verifies the secret and accepts delivery. |

Polling and webhooks share the pending queue. Setting a webhook disables polling. Call `deleteWebhook` before switching back; do not set `drop_pending_updates: true` unless you intend to discard pending work.

Initialize delivery before sending test messages. A new bot's queue is created by its first polling call or webhook setup; messages sent before initialization are not backfilled.

## Polling and Acknowledgement

Read a batch without waiting:

```bash
curl -sS "https://api.inline.chat/bot/getUpdates?timeout=0&limit=20" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

For a continuous worker:

1. Load the offset saved by this bot's consumer.
2. Call `getUpdates` with that offset and a long-poll timeout. Keep the HTTP client's timeout longer than the poll timeout.
3. Process the batch in `update_id` order, using a durable deduplication key of `(bot identity, update_id)`. Stop at the first failure. IDs may have gaps; do not wait for every integer to appear.
4. Persist successful handling before advancing the offset to one above the last successfully handled update before any failure. If 101 fails and 102 succeeds, do not acknowledge 103: that also discards 101.
5. Call again with the saved offset. An empty result is normal.

The next offset acknowledges earlier queue entries; fetching alone is not your durable processing checkpoint. If the process crashes between a side effect and saving its checkpoint, delivery can repeat. Make downstream side effects idempotent where possible. This is an at-least-once delivery contract, not exactly-once execution.

## Webhook Setup

Prepare the handler before registering its URL. Using the TypeScript client from the [Bot API guide](/docs/bot-api#first-message):

```ts
const secret = process.env.INLINE_WEBHOOK_SECRET
if (!secret) throw new Error("Set INLINE_WEBHOOK_SECRET")

const registered = await bot.setWebhook({
  url: "https://your-service.example/inline-updates",
  secret_token: secret,
  message_trigger: "mentions",
})
if (!registered.ok) throw new Error(registered.description)
```

Replace the example URL with your deployed endpoint. In the handler:

- Verify `x-inline-bot-api-secret-token` before processing. Use a constant-time comparison and reject requests with a missing or wrong secret.
- Deduplicate by bot identity and `update_id`. `x-inline-update-id` stays the same across retries; `x-inline-attempt` starts at 1. Deliveries may be concurrent and out of order.
- Durably enqueue or complete the work before returning a `2xx` response, which acknowledges the update. The current delivery timeout is 10 seconds; do not wait for a long agent task inside the request.
- Treat retries as normal. Receiving the same update must not start the same job twice.

A timeout, network error, or non-`2xx` response leaves the update pending for retry. The current worker honors a numeric `Retry-After` header on `429` and `503` responses, capped at one hour; other retries use backoff with jitter. Keep handlers independent of exact retry timing.

Inspect `getWebhookInfo` for pending count, last error, and cumulative dropped updates. A successful registration only proves the configuration was accepted: send a test DM and confirm your handler receives it and the bot replies in Inline.

## Which Messages Arrive?

The default `mentions` trigger includes direct messages and human activations through mentions, replies, commands, and message actions. Bots do not receive their own messages; bot-to-bot activation requires an explicit resolved mention. A plain string that looks like a mention is not a substitute for its structured entity.

Use `allowed_updates` to select event kinds. Message reactions require opting in; the default keys are `message`, `edited_message`, `message_action`, and `bot_participation`. See the [generated reference](https://api.inline.chat/bot-api-reference) for each payload.

## Troubleshooting

| Symptom | Check and recovery |
| --- | --- |
| `409` / `WEBHOOK_ACTIVE` | A webhook is configured. Keep that consumer, or deliberately remove it before polling. |
| `409` / `POLL_CONFLICT` | Another long poll is active. Stop the duplicate consumer. |
| A new bot's queue is empty | Initialize polling or register the webhook, then send a fresh human DM. Older messages are not backfilled. |
| The same update repeats | Persist handling and pass the next offset; for webhooks, check acknowledgement and deduplication. |
| No thread messages arrive | Check bot access, `message_trigger`, `allowed_updates`, and structured mentions. Try a human DM first. |
| Webhook backlog grows | Check reachability, secret validation, handler failures, and `getWebhookInfo`. |
| Updates are missing after downtime | Retention is up to 24 hours and queues are bounded. Inspect `dropped_update_count`; queue delivery is not a full-history archive. |

[Queue limits and access rules](/docs/bot-api#receiving-updates) · [Bot API method reference](https://api.inline.chat/bot-api-reference)
