---
title: "Receive Bot Updates"
description: "Bot API polling and webhooks."
---

Use one consumer per bot:

- `getUpdates`: one active long poll; persist the offset.
- Webhook: HTTPS handler; verify the secret; return `2xx` after durable handling.

Polling and webhooks share one queue. Setting a webhook disables polling. Messages sent before the first poll or webhook setup are not backfilled.

## Polling

Read a batch:

```bash
curl -sS "https://api.inline.chat/bot/getUpdates?timeout=0&limit=20" \
  -H "Authorization: Bearer ${INLINE_BOT_TOKEN}"
```

Processing loop:

1. Load the saved offset.
2. Long-poll with that offset.
3. Process by increasing `update_id`; tolerate gaps.
4. Stop at the first failure.
5. Persist completed work.
6. Save one above the last successfully handled ID.
7. Poll again.

Fetching does not acknowledge durable processing. Delivery is at least once; deduplicate by `(bot identity, update_id)`.

## Webhook

Register after the handler is ready:

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

Handler rules:

- Verify `x-inline-bot-api-secret-token` with a constant-time comparison.
- Deduplicate by bot identity and `update_id`.
- `x-inline-update-id` is stable across retries.
- `x-inline-attempt` starts at 1.
- Deliveries may be concurrent and out of order.
- Durably enqueue or finish before returning `2xx`.
- Current timeout: 10 seconds.
- Numeric `Retry-After` on `429` and `503` is capped at one hour.

Inspect `getWebhookInfo` for pending count, last error, and dropped updates.

## Update Selection

Default update kinds:

- `message`
- `edited_message`
- `message_action`
- `bot_participation`

Reactions require `allowed_updates`. The default `mentions` trigger includes DMs and human mentions, replies, commands, and message actions. Bots require a structured mention.

## Checks

- `WEBHOOK_ACTIVE`: keep the webhook or call `deleteWebhook` before polling.
- `POLL_CONFLICT`: stop the duplicate long poll.
- Empty new queue: initialize delivery, then send a fresh human DM.
- Repeated update: fix acknowledgement and deduplication.
- Missing thread message: check access, `message_trigger`, `allowed_updates`, and mentions.
- Growing webhook backlog: check reachability, secret validation, and handler failures.
- Missing updates after downtime: retention is 24 hours and the queue is bounded.

[Queue limits](/docs/bot-api#updates) · [Method reference](https://api.inline.chat/bot-api-reference)
