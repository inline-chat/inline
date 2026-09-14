# Inline Follow and Mention Resolution

This document is the canonical map for how Inline integrations decide whether an
unmentioned group message may wake an agent. It deliberately separates creating
follow state from consuming follow state; mixing those decisions caused followed
threads to stop waking bots after a message-count threshold.

## Canonical Signal

Use the current bot user's `Dialog.followMode` from `GET_CHAT` as the canonical
server-side participation signal. `DialogFollowMode.FOLLOWING` means the bot has
joined or followed that Inline thread enough for follow-up messages to continue
without another explicit mention.

Do not infer participation from parent chat IDs alone. A chat with only
`parentChatId` is older structural context, not a reply-thread signal for mention
gating. Reply-thread eligibility is based on `parentMessageId`.

## Decision A: Materializing Follow State

The server alone owns the policy for when activity automatically changes a
dialog to `FOLLOWING`:

- reply threads are auto-followed when the bot sends into them
- the reply-thread anchor sender may also be auto-followed when eligible
- parentless normal Inline threads are auto-followed only while they are fresh
- the server currently uses a freshness threshold of 15 messages
- a dialog explicitly set to `UNFOLLOWED` is excluded from automatic following,
  so later activity does not silently turn following back on

Freshness uses the newly assigned per-chat message ID as a cheap proxy for thread
size. The boundary is currently `newMessageId <= 15`. It is evaluated only while
deciding whether to materialize follow state. Changing which threads can become
automatically followed must start with this server policy.

An explicit `/follow` updates the current bot user's dialog directly and does not
depend on thread freshness.

## Decision B: Consuming Follow State

Once `GET_CHAT` reports the current bot user's dialog as
`DialogFollowMode.FOLLOWING`, that state is durable relevance. An unmentioned
message may continue waking the bot regardless of the thread's current message
count or whether it is a reply thread or parentless thread.

The adapter must not reapply a freshness or size check here. Following continues
until the dialog becomes `UNFOLLOWED`. A strict explicit-mention configuration
may intentionally override this default and require a mention on every turn.

The realtime SDK previously exposed
`isInlineFollowModeMentionGateEligible()` with a separate threshold of 50.
Hermes and OpenClaw incorrectly combined that classifier with durable
`FOLLOWING` state on every inbound message. That legacy classifier is retained
temporarily for API compatibility but must not be used for response routing.

## Decision C: Resolving an Inbound Group Message

After access policy and adapter control-command handling, resolve relevance in
this order:

1. Free-response configuration or disabled mention gating allows the message.
2. An explicit bot mention allows the message.
3. If strict explicit-mention mode is enabled, stop: implicit signals are not
   allowed.
4. A reply-to-bot signal may allow the message where that integration enables
   it.
5. Current dialog `FOLLOWING` state allows the message, without a freshness
   check.
6. Integration-specific reply-thread participation fallback may allow the
   message when server follow state is unavailable.
7. Otherwise, retain the message only as observed context and do not respond.

Explicit addressing is a separate precedence layer checked before accepting an
implicit signal. When the first entity begins after whitespace only and is a
concrete mention of another user, follow/reply inference does not wake the bot
unless the bot is also explicitly mentioned. A `/command@botusername` suffix
likewise targets only that bot; a matching bot removes the suffix before command
dispatch, while other bots ignore it. Username-mention entities without a
resolved user ID are not used for the leading-person exclusion.

Explicit mention always wakes the agent when the group/user policy allows it.
Free-response rooms continue to bypass mention gating by configuration.

## Integration Notes

Hermes reads `dialogFollowMode` or `dialog.followMode` from the Inline sidecar
`/chat` response. In its default non-strict mention mode, `FOLLOWING` is an
implicit wake signal.

OpenClaw reads `dialogFollowMode` from the realtime SDK `getChat()` result and
uses `FOLLOWING` as an implicit mention source. Its older local
thread-participation cache remains a fallback for sparse history or older hosts
where server follow mode is unavailable.

## Examples

| State and message | Result |
|---|---|
| Parentless thread, message 6, no follow state, bot sends | Server may materialize `FOLLOWING` because the thread is fresh. |
| Parentless thread, message 80, no follow state | Freshness prevents automatic following; an unmentioned message does not wake solely from follow mode. |
| Parentless thread, message 80, dialog already `FOLLOWING` | The unmentioned message may wake the bot; message count does not expire following. |
| Reply thread, message 500, dialog `FOLLOWING` | The unmentioned message may wake the bot. |
| Any thread, dialog `UNFOLLOWED` | Follow mode does not wake the bot, and automatic following does not turn itself back on. |
| Any followed thread with strict mention mode enabled | A bot mention is still required by explicit configuration. |
| Followed/reply-relevant thread, message starts with a mention of another person, bot not mentioned | The explicit human address wins; do not respond. |
| Mention-gated group, `/status@thisbot` | Treat as explicit bot attention and dispatch `/status`. |
| Any chat, `/status@otherbot` | Ignore it. |
