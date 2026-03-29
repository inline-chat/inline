# Inline OpenClaw Native Reply Threads Design

**Date:** 2026-03-29
**Status:** Approved in terminal review, written for planning
**Scope:** `packages/openclaw-inline` only

## Goal

Expose Inline reply threads to OpenClaw natively, in the same general model as Slack-style threaded channels, while keeping the feature off by default so existing installs preserve today's reply-to-message behavior until users opt in.

## Non-goals

- redesigning the broader Inline/OpenClaw tool surface beyond reply threads
- changing existing `replyToMsgId` message-reply support
- requiring a new OpenClaw host version
- publishing new shared SDK packages unless the implementation proves it is necessary

## Product Decisions

- The new feature flag is `channels.inline.capabilities.replyThreads`.
- The same flag is allowed under `channels.inline.accounts.<account>.capabilities.replyThreads`.
- Default is `false`.
- When disabled, the plugin keeps today's behavior:
  - no bot-facing native reply-thread affordance
  - current message-reply behavior continues unchanged
  - current thread aliases remain compatibility-only
- When enabled, the plugin exposes Inline reply threads as real OpenClaw threads:
  - inbound reply-thread turns carry a parent chat target plus a thread id
  - outbound sends can target a parent chat + reply-thread id
  - the bot can create and reply into reply threads natively

## Current Gap

Inline now supports real reply threads in the product itself:

- `CreateSubthreadInput` / `CreateSubthreadResult`
- `Chat.parentChatId`
- `Chat.parentMessageId`

But `packages/openclaw-inline` still behaves as if:

- `capabilities.threads = false`
- Inline "threads" are only chat aliases
- outbound `threadId` is ignored for real reply-thread routing
- inbound reply-thread chats are treated as ordinary group chats
- `thread-create` does not create a real subthread

That mismatch is why the bot cannot reason about Inline reply threads natively today.

## Recommended Approach

Use native OpenClaw threading semantics, but gate actual exposure and behavior behind an Inline config toggle.

This means:

- advertise platform thread support in the channel plugin
- add a real `threading` adapter
- map OpenClaw `threadId` to the Inline child reply-thread chat id
- treat the parent chat as the OpenClaw conversation target
- keep bot-facing thread actions, hints, and routing disabled unless `capabilities.replyThreads=true`

This is the closest fit to the way OpenClaw models threaded channels like Slack, while still preserving backward compatibility for existing Inline users.

## Config Surface

Add a new optional capabilities object to the Inline channel config:

```yaml
channels:
  inline:
    capabilities:
      replyThreads: true
```

Per-account override:

```yaml
channels:
  inline:
    accounts:
      work:
        capabilities:
          replyThreads: true
```

Rules:

- account-level value overrides the base channel value
- unset means `false`
- older configs continue to validate unchanged
- docs should explain that this enables native reply-thread exposure to the bot, not ordinary message replies

## Native Thread Model

When reply threads are enabled, OpenClaw should see an Inline reply thread as:

- `To`: the parent chat id
- `MessageThreadId`: the child reply-thread chat id
- `ThreadLabel`: the child chat title when available
- `ReplyToId`: only when the current message is also replying to a specific message inside the child thread

This is the critical modeling decision.

The child reply-thread chat id becomes the OpenClaw `threadId`, but the parent chat remains the base conversation target. That gives OpenClaw the same kind of parent-conversation-plus-thread addressing it already uses in native threaded channels.

## Channel Contract Changes

### Capabilities

Change the Inline channel plugin to:

- set `capabilities.threads = true`
- add a `threading` adapter

Why make `threads=true` even though the feature is off by default:

- `capabilities` describe platform support, not account defaults
- Inline does support real reply threads now
- the actual bot-facing behavior is still gated by `capabilities.replyThreads`

Mitigation for accidental exposure while disabled:

- current action discovery should stay compatible with today's plugin behavior
- agent prompt hints should avoid advertising native reply-thread behavior until the toggle is on
- inbound/outbound thread routing should stay on the old path when the toggle is off

### Threading Adapter

When enabled, add an Inline `threading` adapter with:

- `resolveReplyToMode`: `off`
  - Inline reply threads are separate child chats, not "reply to first message in same room" transport
- `buildToolContext`
  - include the current parent chat id
  - include the current child reply-thread id as `currentThreadTs`
- `resolveReplyTransport`
  - preserve `threadId`
  - only preserve `replyToId` when explicitly targeting a message inside the child thread

The intent is to make OpenClaw route to the child thread without inventing Slack-style reply transport that Inline does not have.

## Inbound Monitor Behavior

When reply threads are disabled:

- keep current monitor behavior unchanged

When reply threads are enabled:

1. Detect whether the inbound chat is a reply-thread chat.
2. Resolve and cache the child chat metadata:
   - child chat id
   - parent chat id
   - parent message id
   - child chat title
3. For reply-thread messages, build OpenClaw context using:
   - `To = parentChatId`
   - `MessageThreadId = childChatId`
   - `ThreadLabel = child thread title`
4. Keep the session thread-scoped so follow-up turns stay inside the same reply thread.

### Parent Anchor Context

The bot also needs to understand what the reply thread is about.

When a message arrives in a reply thread, the plugin should fetch the anchor parent message from the parent chat and prepend it as synthetic oldest context in the thread history payload.

That anchor should be included in:

- legacy `Body` context text
- structured `InboundHistory`

This keeps the model aware of the original parent message without requiring the full parent chat transcript on every turn.

### History Scope

For enabled reply threads:

- recent thread history comes from the child reply-thread chat
- the parent anchor message is prepended as synthetic context
- ordinary parent-chat history should not be merged into thread history by default

That keeps context focused and avoids cross-thread bleed.

## Outbound Behavior

When reply threads are disabled:

- keep current behavior
- ignore native `threadId`
- continue using `replyToId -> replyToMsgId`

When reply threads are enabled:

- `sendText` / `sendMedia`
  - if `threadId` is present, send to the child reply-thread chat id
  - base `to` still identifies the parent conversation for routing/session purposes
- `replyToId`
  - when present alongside `threadId`, treat it as a reply within the child thread
  - when no `threadId` is present, keep existing message-reply behavior in the current chat

This gives three supported send modes:

1. normal message in parent chat
2. reply-to-message in current chat
3. message or explicit reply inside a child reply thread

## Message Tool Surface

### Discovery

When reply threads are disabled:

- keep the current action surface and compatibility semantics
- do not advertise native reply-thread behavior in `messageToolHints`

When enabled:

- keep the same action names
- add explicit hints that:
  - `thread-reply` targets a real Inline reply thread
  - `thread-create` can create a reply thread from a parent chat and optional anchor message

### Action Semantics

#### `thread-reply`

When enabled:

- `threadId` is the child reply-thread chat id
- `to` / `chatId` / `channelId` refer to the parent chat when present
- `replyToId` is optional and means reply to a specific message inside the child thread
- if `threadId` is missing, reject with a clear error

When disabled:

- preserve the current compatibility behavior

#### `thread-create`

When enabled:

- use Inline `createSubthread`, not `createChat`
- require a parent chat target
- accept optional `replyToId` / `parentMessageId`
  - if present, create an anchored reply thread
  - if absent, create a general child subthread
- return:
  - parent chat id
  - created child thread id
  - anchor message metadata when available

`channel-create` should remain the top-level chat creation path.

## Compatibility Strategy

This change must not break:

- existing Inline installs
- older OpenClaw hosts
- existing message-reply flows

Compatibility rules:

- feature defaults off
- no new required root `plugin-sdk` imports
- reuse the existing compat/runtime-loading approach
- if host behavior around threads differs, disabled mode must still preserve the current non-threaded route

For implementation, prefer local plugin logic or `invokeRaw` / `invokeUncheckedRaw` over forcing a shared SDK release just to access `createSubthread`.

## Error Handling

- Invalid or inaccessible `threadId`: reject clearly instead of falling back silently to the parent chat.
- `thread-create` without a valid parent chat target: reject clearly.
- Missing anchor message for anchored thread creation: surface the upstream error.
- If thread metadata lookup fails for inbound reply-thread messages, fall back to current non-threaded handling rather than dropping the turn.
- If anchor-message fetch fails, continue with child-thread history and mark the anchor context as unavailable rather than blocking reply generation.

## Testing

Add regression coverage for:

- config schema accepts `capabilities.replyThreads`
- disabled default preserves current action discovery and current behavior
- enabled mode advertises thread support and updated hints
- inbound reply-thread message sets:
  - `To = parentChatId`
  - `MessageThreadId = childThreadChatId`
  - anchor context is included
- outbound `sendText` / `sendMedia` route to child thread when `threadId` is present
- `thread-reply` requires `threadId` in enabled mode and sends into the child thread
- `thread-create` uses `createSubthread` and returns thread metadata
- disabled mode still uses current compatibility path for `thread-reply`
- empty or failed anchor lookup degrades cleanly
- explicit `replyToId` inside child thread is preserved

## Documentation

Update:

- `packages/openclaw-inline/README.md`
- `packages/openclaw-inline/docs/openclaw-setup.md`

Docs should explain:

- difference between message replies and reply threads
- default-off behavior
- how to enable native reply-thread support
- what changes for the bot when enabled

## Follow-up Work Explicitly Out Of Scope

- extra convenience tools inspired by Slack/ClawHub research
- interactive button/select reply UX for Inline
- broader thread-directory or thread-read tooling beyond what is needed for native reply-thread messaging
- any Apple/Web/Desktop reply-thread UX changes
