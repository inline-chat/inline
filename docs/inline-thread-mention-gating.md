# Inline Thread Mention Gating

This document defines how Inline integrations decide whether an unmentioned group
message may wake an agent.

## Canonical Signal

Use the current bot user's `Dialog.followMode` from `GET_CHAT` as the canonical
server-side participation signal. `DialogFollowMode.FOLLOWING` means the bot has
joined or followed that Inline thread enough for follow-up messages to continue
without another explicit mention.

Do not infer participation from parent chat IDs alone. A chat with only
`parentChatId` is older structural context, not a reply-thread signal for mention
gating. Reply-thread eligibility is based on `parentMessageId`.

## Auto-Follow Policy

The server owns the policy for when a chat becomes followed:

- reply threads are auto-followed when the bot sends into them
- normal Inline threads are auto-followed only while they are fresh
- the freshness threshold currently lives in
  `server/src/modules/threadAutoFollow.ts` as
  `FRESH_THREAD_LAST_MESSAGE_ID_LIMIT`

Changing which threads can materialize follow mode should start by changing that
server policy.

## Follow-Mode Mention Eligibility

Follow mode alone is not enough to bypass mention gating. The adapter must also
classify the current chat as follow-mode mention eligible:

- reply thread: `parentMessageId` is a positive id
- fresh thread: `lastMsgId` is a positive id below
  `INLINE_FOLLOW_MODE_MENTION_FRESH_LAST_MESSAGE_ID_LIMIT`

The current threshold is 50, so `lastMsgId < 50` is fresh.

This classifier is exposed by the realtime SDK as
`isInlineFollowModeMentionGateEligible()`. Hermes computes it in the sidecar and
returns `followModeMentionEligible` from `/chat`; OpenClaw uses the SDK helper
directly.

This extra check protects older parent-style or large threads where follow mode
may exist but should not override explicit mention gating.

## Mention Gate

For group/thread chats, an unmentioned inbound message may wake the agent when:

- `GET_CHAT` for the current chat returns the current bot user's dialog with
  `followMode = FOLLOWING`
- the current chat is follow-mode mention eligible

Explicit mention always wakes the agent when the group/user policy allows it.
Free-response rooms continue to bypass mention gating by configuration.

Strict explicit-mention modes, where every group/thread turn must mention the
bot even if the dialog is following, are intentionally separate from this
default policy. They may exist as opt-in compatibility/config overrides, but the
default behavior is follow-mode based continuation for eligible reply/fresh
threads.

## Integration Notes

Hermes reads `dialogFollowMode` or `dialog.followMode`, plus
`followModeMentionEligible`, from the Inline sidecar `/chat` response.

OpenClaw reads `dialogFollowMode` from the realtime SDK `getChat()` result and
uses it as an implicit mention source only when
`isInlineFollowModeMentionGateEligible(chatInfo)` is true. Its older local
thread-participation cache is only a fallback for sparse history or older hosts
where server follow mode is not available.
