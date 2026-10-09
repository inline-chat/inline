# Delivery facts

Apply the host's existing durability, retry, and ordering practices for its other channels. These are the Inline behaviors those practices need to account for.

## Updates

- Each bot has one queue. Polling and webhooks both read it; setting a webhook disables polling, and one long poll per bot is allowed.
- Delivery is at least once. Deduplicate on bot ID plus `update_id`.
- Updates are kept up to 24 hours within a size cap. Size any dedupe window to cover that. Nothing from before delivery was first initialized is replayed.
- A webhook `2xx` acknowledges the update; the timeout is 10 seconds. A poll with `offset: N` acknowledges everything below `N`.
- Polling returns updates in increasing `update_id` order, with gaps. Webhook deliveries can be concurrent and out of order: an earlier message can arrive after a later one has started a turn. If the host depends on message order within a chat, prefer polling or apply its existing reordering policy. Message `date` has one-second resolution.
- `edited_message` is a separate update kind.
- `getWebhookInfo` reports `pending_update_count`, `last_error_message`, and `dropped_update_count`.

## Sends

The Bot API has no idempotency key and `@inline-chat/bot-client` does not retry. Distinguish three results:

| Result | Meaning |
| --- | --- |
| `ok: false` with a rate-limit or server error | Nothing was sent. Retry per host policy, honoring `parameters.retry_after` or a `Retry-After` header when present. |
| `ok: false` for authentication, access, or destination | Permanent for this destination. Do not redirect the message to another chat. |
| Timeout or dropped connection | Unknown. The message may exist or may still appear. Reading `getChatHistory` can confirm arrival; not finding it does not prove failure. |

Edits replace content, so repeating one is safe. Read-only methods can be retried; `getUpdates` with an `offset` is not read-only.

## Chat SDK

- `bot.webhooks.inline(request, { waitUntil })` returns `200` before handlers finish.
- The SDK writes its dedupe marker before routing to handlers. If a worker dies between the marker and the handler creating the host's job, replaying the same request returns `200` and runs nothing. A `200` from the SDK is not a receipt that the host accepted the work.

For work that must not be lost, create the host's job at the webhook route directly from the verified `BotUpdate`, keyed by bot ID and `update_id`, and use the SDK or `inline.client` for output. If the host keeps SDK handlers for intake, recover missed updates from its own inbox without replaying through the SDK.
