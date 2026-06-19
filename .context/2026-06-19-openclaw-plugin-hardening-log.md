# OpenClaw Inline plugin hardening log

Date: 2026-06-19

Goal: harden the Inline OpenClaw plugin by iterating one reliability/tooling gap at a time, checking native OpenClaw channel patterns, applying focused fixes, and recording verification.

Important scope note:
- Treat Inline OpenClaw as a bot surface, not as a full user-client control surface. Avoid spending hardening time on actions that provide little agent value, such as follow/unfollow, pin/unpin, or notification setting controls, unless a concrete bot workflow needs them.
- Use native OpenClaw Telegram/Slack-style plugins for useful hints around tool/API surface, prompting guidance, reliability hardening, workflows, and failure handling, then apply only the parts that make sense for bots operating in Inline.
- Before changing behavior heuristics, explicitly inspect the matching native plugin path where possible and record the source-of-truth behavior. Telegram is the primary reference for bot command ingress, debounce, stop/abort, and group authorization semantics.

## Native reference notes

- OpenClaw's native channel plugins expose provider behavior through the shared `message` tool action adapter.
- Telegram and Slack bias agents toward `message({ action: ... })` rather than provider-specific tool names for broad channel actions.
- Inline already has a shared action adapter, so missing or underpowered actions should generally be fixed there first and only duplicated as direct tools when there is a strong model-use reason.

## Iteration 1: thread creation tool

Status: complete.

Problem:
- Inline advertises `message` action `thread-create`, but the implementation currently only creates reply subthreads anchored to an existing parent chat/message.
- Creating a normal Inline thread with participants, `spaceId`, or public visibility is available through `channel-create`, not through `thread-create`, so agents using the native thread action cannot create the kind of thread users naturally ask for.

Plan:
- Keep reply-subthread behavior when a parent chat target or parent message anchor is provided.
- Let `thread-create` create a top-level Inline thread via `createChat` when it is not anchored to a parent chat/message.
- Preserve participant resolution, `spaceId`, `isPublic`, description, and emoji handling.
- Add focused tests and update docs.

Implementation notes:
- Added `thread-create` schema fields for `spaceId`, `isPublic`, and participant aliases to the shared OpenClaw `message` tool discovery.
- Added Inline `messageActionTargetAliases` for `thread-create` so OpenClaw core can accept no-`to` creation when `spaceId`, `participant`, or anchor fields are present.
- Split explicit reply-thread anchors from context fallback:
  - `to`/`chatId`/`channelId` still creates a child reply thread.
  - explicit `replyToId`/`messageId` can use the current channel context to create a child reply thread.
  - current channel/message context alone no longer silently turns a top-level `thread-create` into a child reply thread.
- Top-level `thread-create` now uses `createChat`.
- Space-only top-level `thread-create` defaults to public, since a private top-level thread with no participants is not useful and fails server-side.

Compatibility caveat:
- OpenClaw core target-alias validation currently treats scalar strings/numbers as target aliases. `participant: "123,456"` works for no-`to` private thread creation; `participants: ["123", "456"]` is supported by the Inline plugin handler, but older core validation may reject an array-only no-`to` call before dispatch.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (41 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Blocked: `cd packages/openclaw && bun run typecheck` fails before this change is typechecked because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.d.ts`; this also causes existing implicit-any cascades.
- Blocked: `cd packages/openclaw && bun run test` runs 362/365 passing tests, but package entry/artifact tests fail because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.js`.

Status: implementation complete pending the repo's SDK dist/typecheck environment being restored.

## Iteration 2: reply-thread reliability

Status: complete.

Problem:
- `thread-reply` currently requires a `threadId`, but agents may have a parent chat/message anchor or an existing remembered reply-thread route instead.
- Common failure paths need review: missing `threadId`, stale route lookup, parent-vs-child target confusion, and hidden fallback errors when creating or sending to reply threads.

Plan:
- Inspect Inline reply-thread route storage, automatic reply-thread creation, and native OpenClaw thread action patterns.
- Identify the highest-signal reliability fix with narrow blast radius.
- Add focused tests for the failure path and expected recovery behavior.
- Record verification and any remaining reliability risks.

Implementation notes:
- Added `thread-reply` schema fields for `threadId`, `parentMessageId`, and `anchorMessageId`.
- Added `thread-reply` target aliases so OpenClaw core can accept useful Inline calls that have `threadId` or route-recovery fields without requiring `to`.
- Added a shared `thread-reply` target resolver:
  - explicit `threadId` still wins;
  - current reply-thread context (`currentThreadTs`) is used when the tool is called from an existing reply-thread turn;
  - otherwise the resolver looks up a remembered `thread-create` route by parent chat and optional `parentMessageId`.
- Kept `parentMessageId` separate from child-thread `messageId`/`replyToId`, so route recovery does not accidentally send a child-thread reply to a parent-chat message id.
- Updated Inline agent prompt hints and README docs to describe route recovery.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (43 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails before useful package-wide validation because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.d.ts`; this also causes existing implicit-any cascades.

Remaining caveat:
- Route lookup without `agentId` uses the route store's general parent/message keys because OpenClaw execution-time `toolContext` does not carry `agentId`. This is still better than hard failure and matches the route keys `thread-create` already writes, but multiple agents sharing the same parent/message route can still collide.

## Iteration 3: bot-added fresh thread behavior

Status: complete.

Problem:
- When the Inline bot is added to a fresh thread, the plugin sends a hard-coded ready/greeting message immediately.
- When the bot is added to an existing thread, it should introduce itself through the normal agent/system-event path and inspect the previous 10 messages for prior mentions that happened before it joined.
- Fresh-vs-existing detection should be reusable instead of embedded as one-off monitor logic.

Plan:
- Add a small reusable resolver that classifies loaded history as `fresh`, `existing`, or `unknown`.
- Treat user-authored pre-join visible messages as existing history; ignore bot-authored and post-join messages.
- Detect prior bot mentions by native `mentioned`, username text, and mention entities.
- Wire participant-add handling so fresh and unknown history stays quiet, while existing history enqueues a system event with recent pre-join context and prior-mention guidance.

Implementation notes:
- Added `resolveInlineThreadFreshness` in `src/inline/thread-freshness.ts`.
- The resolver is structural and SDK-independent, so future flows can reuse it without importing the realtime client types.
- Participant-add now always fetches up to the last 10 messages for this decision, independent of normal conversation history limits.
- Removed the direct hard-coded participant-add ready message. Existing chats now use `enqueueSystemEvent`, matching native channel style better and letting the agent decide whether to intro only or answer prior mentions.
- If history loading fails, the resolver returns `unknown` and the plugin stays quiet. This favors avoiding an unwanted greeting in a fresh thread over risking a false intro.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/thread-freshness.test.ts src/inline/monitor.test.ts` (136 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails before useful package-wide validation because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.d.ts`; after fixing the local narrowing issue from this iteration, remaining errors are the existing module-resolution and implicit-any cascades.

Tradeoff:
- A history-fetch failure now suppresses the intro for existing chats too. That is intentional for this iteration because the harmful production behavior was unsolicited greetings in fresh threads; we can add a more nuanced retry/status path later if needed.

## Iteration 4: voice message auto-transcript handling

Status: complete.

Problem:
- Inline voice messages arrive first as audio, then the server adds the auto-transcript by editing the message text.
- The plugin currently treats `message.new` voice notes as immediate `<media:audio>` inbound turns and treats `message.edit` only as a lifecycle system event. That can make OpenClaw transcribe audio itself before Inline's native transcript arrives, and it ignores the later transcript for the actual user turn.
- Native Telegram/WhatsApp paths use audio preflight when the channel lacks a usable transcript. Inline should prefer its own server transcript first, then fall back to OpenClaw's configured audio transcription pipeline only if the transcript edit never arrives.

Plan:
- Hold textless Inline voice `message.new` events briefly instead of dispatching them immediately.
- If a matching `message.edit` arrives with text, dispatch that text as the inbound turn and omit the audio media from context so media understanding does not transcribe it again.
- If no transcript edit arrives before the wait expires, release the original audio message unchanged so existing/custom audio transcription config still applies.
- Make the wait configurable for deployments and tests.

Implementation notes:
- Added `voiceTranscriptWaitMs` account config, defaulting to 8000 ms and clamped to 60000 ms; `0` disables the wait.
- Added a pending voice-message map keyed by `chatId:messageId`, with timers cleared on transcript edit or provider shutdown.
- Matching transcript edits are consumed by the pending voice flow and no longer enqueue a generic "message edited" system event.
- Raw-audio fallback still goes through the normal inbound debouncer, routing, mention gating, media download, and reply pipeline.
- Added an Inline prompt hint: text on a voice turn is the preferred Inline transcript; configured audio transcription is for raw audio without transcript text.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts src/inline/channel.test.ts` (189 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/config-schema.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails before useful package-wide validation because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.d.ts`; remaining errors are the same module-resolution and implicit-any cascades.

Tradeoff:
- A transcript edit that arrives after `voiceTranscriptWaitMs` becomes a normal edit lifecycle event because the raw-audio fallback has already been released. The default 8 second wait should cover normal server transcription latency without making every voice DM feel stuck indefinitely.

## Iteration 5: immediate stop handling

Status: complete.

Problem:
- Sending `/stop` to Inline did not interrupt promptly because the SDK event loop awaited normal inbound dispatch inline. If a previous message was running the agent, the monitor could not even read the later stop message until that run finished.
- OpenClaw native dispatch already has a fast-abort path, but Inline needed to get stop-like messages to that dispatcher immediately.

Plan:
- Reuse OpenClaw's native `isAbortRequestText` helper instead of maintaining Inline-specific stop-word logic.
- Stop awaiting normal inbound dispatch inside `client.events()` so the monitor can keep reading incoming events.
- Keep ordinary inbound work serialized per Inline chat to preserve existing pending-history and route side effects.
- Let abort messages bypass the per-chat serial queue and the inbound debouncer so `/stop` can enter the native fast-abort path while another turn is active.

Implementation notes:
- Added a scheduled inbound task runner with tracked errors and provider shutdown draining.
- Normal messages and button callbacks are scheduled through the per-chat serial chain; debounced text still flows through OpenClaw's inbound debouncer.
- Abort-like text, including `/stop` and `/stop@bot`, is detected before voice waiting and normal debounce logic, then dispatched directly with priority.
- Voice transcript edits that resolve to a stop request also take the priority path.
- Added regression coverage that blocks the first inbound dispatch and verifies the later `/stop` dispatch starts before the blocked run is released.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (133 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails before useful package-wide validation because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.d.ts`; remaining errors are the existing module-resolution and implicit-any cascades.

Tradeoff:
- Non-stop inbound turns remain serialized per chat, so a second normal user message still waits behind an active run. This intentionally preserves ordering and pending-history behavior while giving stop requests the emergency bypass.

## Iteration 6: configurable inbound burst debounce

Status: complete.

Problem:
- Inline already used OpenClaw's shared inbound debouncer when global `messages.inbound.debounceMs` or `messages.inbound.byChannel.inline` was configured, but the Inline channel itself had no obvious account-level knob.
- Native OpenClaw channels use the shared debouncer, and WhatsApp also supports a channel/account `debounceMs` override. Inline should expose the same practical surface so short bursts can be coalesced without forcing users to edit global message policy.

Plan:
- Reuse OpenClaw's shared inbound debounce implementation and control-command exclusions.
- Add `channels.inline.debounceMs` and named-account `channels.inline.accounts.<id>.debounceMs` through the existing Inline account schema.
- Pass the resolved account setting to `createChannelInboundDebouncer` as `debounceMsOverride`, so account-specific config wins while global `messages.inbound` remains the fallback.
- Document the Inline-local setting and keep the plugin manifest schema/UI hints aligned.

Implementation notes:
- Added `debounceMs` to Inline's Zod account/config schemas and runtime schema.
- Added `resolveInlineInboundDebounceMsOverride` in the monitor and wired it to OpenClaw's `debounceMsOverride`.
- Added monitor coverage showing account-level `debounceMs` batches rapid same-sender Inline text messages.
- Added schema coverage for top-level and named-account debounce config.
- Updated `openclaw.plugin.json` and manifest tests for `debounceMs`; also added the missing manifest metadata for the earlier `voiceTranscriptWaitMs` setting while editing the same checked-in schema block.
- README now shows `debounceMs: 1200` and points to the global alternative `messages.inbound.byChannel.inline`.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts src/inline/monitor.test.ts` (156 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/README.md packages/openclaw/openclaw.plugin.json packages/openclaw/src/manifest.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails before useful package-wide validation because the workspace-linked `@inline-chat/realtime-sdk` package has no `dist/index.d.ts`; after fixing the new strict-optional issue from this iteration, remaining errors are the existing module-resolution and implicit-any cascades.

Tradeoff:
- The Inline-local setting is a direct millisecond override, not a new policy language. That matches WhatsApp's precedent and keeps all batching semantics in OpenClaw's shared debouncer.

## Iteration 7: message translation action coverage

Status: complete.

Problem:
- Inline exposes `TRANSLATE_MESSAGES` in the RealtimeV2 protocol, but the OpenClaw Inline message-tool action surface did not advertise or dispatch translation.
- This made the plugin less capable than the native app/API surface for a common chat workflow: translating one or more existing messages in place.

Plan:
- Add a dedicated `translate` action gate, default-enabled like read/search, with `translateMessages` as an RPC-name alias.
- Dispatch `Method.TRANSLATE_MESSAGES` using the same chat-target parsing and message-id list parsing as the read/search/delete actions.
- Return OpenClaw-friendly translation details with bigint ids stringified and dates converted to milliseconds.
- Keep configuration simple: `actions.translate` controls both `translate` and `translateMessages`.

Implementation notes:
- Added `translate` and `translateMessages` to the Inline action groups.
- Added message-tool schema contributions and target aliases for language and message-id parameters.
- Added config-schema and manifest support for `actions.translate`.
- Documented the new action in the README action matrix.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts src/inline/config-schema.test.ts src/manifest.test.ts` (65 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/openclaw.plugin.json packages/openclaw/README.md packages/openclaw/src/manifest.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because the workspace-linked `@inline-chat/realtime-sdk` package has no resolvable type declarations; remaining errors are the existing module-resolution and implicit-any cascades. The new `translate` action union/cast errors were fixed before this final run.

Tradeoff:
- OpenClaw's current public `ChannelMessageActionName` union does not yet include translation. Inline now uses an internal `InlineMessageActionName` and casts at the adapter boundary for discovery/aliases, keeping the agent-facing runtime feature available without widening unrelated SDK types in this plugin.
- The OpenClaw standalone CLI message command still validates action names against OpenClaw's built-in list, so `openclaw message translate ...` will not work until OpenClaw upstream adds the name. The agent-facing `message` tool schema is discovery-driven and will include the Inline action.

## Iteration 8: read-state actions

Status: complete.

Problem:
- Inline exposes RealtimeV2 RPCs for marking a dialog read (`READ_MESSAGES`) and unread (`MARK_AS_UNREAD`), but the OpenClaw Inline message-tool surface only used `read` for fetching history.
- Native OpenClaw Slack/Discord plugins use custom action names for platform-specific message operations when the shared action enum is not precise enough, so Inline should expose clear custom action names rather than overloading `read`.

Plan:
- Add `mark-read` and `mark-unread` under the existing `actions.read` gate.
- Keep `read` as history fetch to match current behavior.
- Use `messageId`/`maxId`/`maxMessageId` for optional read-through position; omit it to mark through latest.
- Guard `READ_MESSAGES` by numeric fallback because the current SDK method map is missing this RPC even though the protocol enum has it.

Implementation notes:
- Added `mark-read` and `mark-unread` to Inline action discovery, target aliases, README, and the expanded RPC dispatch test.
- `mark-read` dispatches `readMessages` with `peerId` and optional `maxId`.
- `mark-unread` dispatches `markAsUnread` with `peerId`.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (43 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because the workspace-linked `@inline-chat/realtime-sdk` package has no resolvable type declarations; remaining errors are the existing module-resolution and implicit-any cascades.

Tradeoff:
- `mark-read`/`mark-unread` are agent-facing message-tool actions, not standalone `openclaw message ...` CLI actions, for the same reason as `translate`: the current OpenClaw CLI parser uses a fixed action list. The runtime agent tool schema is discovery-driven and includes them.

## Iteration 9: channel-edit visibility and emoji

Status: complete.

Problem:
- Inline `channel-edit` only renamed a thread even though the protocol exposes `UpdateChatInfo.emoji` and `UPDATE_CHAT_VISIBILITY`.
- That left agents unable to change a space thread between public/private or update the thread emoji through the standard channel management action.

Plan:
- Keep `channel-edit`/`renameGroup` as the existing management action.
- Make title, emoji, and visibility independent optional updates, failing early if none are supplied.
- Require explicit participants when making a thread private, matching server validation.
- Reject participants for public visibility changes before sending the RPC.

Implementation notes:
- Added channel-edit schema contribution and target aliases for `emoji`, `isPublic`, `visibility`, and participants.
- `channel-edit` now calls `UPDATE_CHAT_INFO` only when title or emoji is supplied.
- `channel-edit` now calls `UPDATE_CHAT_VISIBILITY` when `isPublic`, `public`, `visibility`, or `privacy` is supplied.
- `visibility: "public"|"private"` is accepted as a readable alias for `isPublic`.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (43 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because the workspace-linked `@inline-chat/realtime-sdk` package has no resolvable type declarations; remaining errors are the existing module-resolution and implicit-any cascades.

Tradeoff:
- Private visibility changes require explicit participants instead of trying to infer current membership. That matches server validation and avoids silently making the wrong users participants.

## Iteration 10: space invite action

Status: complete.

Problem:
- Inline exposes `INVITE_TO_SPACE`, but the OpenClaw plugin only had chat participant actions (`addParticipant`/`removeParticipant`) and space permission updates.
- Agents could create or manage chats inside a space, but could not invite someone into the space itself by user id, email, or phone number.
- The protocol moved invite roles from deprecated `Member.Role` to `SpaceMemberRole`, so adding this tool needed to use the oneof role shape instead of old enum values.

Plan:
- Add `invite-to-space` under the existing `participants` action gate, with `inviteToSpace` as the RPC-name alias.
- Accept one invite target per call: existing Inline user (`userId`/`user`/`participant`), `email`, or `phoneNumber`.
- Default role to member and support `role: "admin"` plus `canAccessPublicChats` for member invites.
- Keep failures explicit: no target, multiple target modes, multiple user refs, or invalid role should fail before dispatching an RPC.

Implementation notes:
- Added message-tool discovery schema and target aliases for `invite-to-space`/`inviteToSpace`.
- Added a reusable local resolver for invite role and target oneofs.
- Dispatch now calls `INVITE_TO_SPACE` with `{ spaceId, role: SpaceMemberRole, via }` and returns string-safe invite/member details.
- Native OpenClaw Slack/Telegram patterns reviewed again: action dispatch stays schema-driven, validates required fields at the provider boundary, and keeps platform-specific aliases available to agents.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (44 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- The server RPC invites one user per call, so the tool intentionally rejects comma-separated or array user lists. Bulk invites should be repeated calls rather than an invented client-side batch contract.

## Iteration 11: show hidden chats in chat list

Status: complete.

Problem:
- Inline exposes `SHOW_IN_CHAT_LIST`, but the OpenClaw plugin had no way for agents to surface a hidden chat or linked reply thread in the current user's chat list.
- This matters for reply-thread workflows because linked subthreads can exist without being active in the main chat list.

Plan:
- Add `show-in-chat-list` under the existing `channels` action gate, with `showInChatList` as the RPC-name alias.
- Keep the action narrow: it only surfaces a chat by `to`/`chatId`/`channelId`.
- Do not add a hide/archive pair in this iteration because `SHOW_IN_CHAT_LIST` has no hide boolean; hiding/archive behavior is a separate protocol path.

Implementation notes:
- Added method fallback for `SHOW_IN_CHAT_LIST = 46`.
- Added message-tool schema contribution and target aliases for `show-in-chat-list`/`showInChatList`.
- Dispatch now sends `{ oneofKind: "showInChatList", showInChatList: { peerId: chatPeer } }` and returns string-safe chat/dialog details.
- Native OpenClaw Slack/Discord patterns reviewed: their channel resolvers expose archived/hidden state so agents can reason about channel visibility; Inline now exposes the corresponding action to promote hidden chats back into view.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (44 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- This only shows/promotes chats. A future archive/hide action should use the dialog-order/open/archive protocol behavior deliberately instead of overloading this show-only RPC.

## Iteration 12: delete message attachment action

Status: complete.

Problem:
- Inline exposes `DELETE_MESSAGE_ATTACHMENT`, but the OpenClaw plugin could delete whole messages only; agents could not remove a generated URL-preview attachment from one of their own messages.
- The existing read/search attachment summary reported the inner `UrlPreview.id` as `attachments[].id`, but the delete RPC requires the stable `MessageAttachment.id`.

Plan:
- Add `delete-attachment` under the existing `delete` action gate, with `deleteMessageAttachment` as the RPC-name alias.
- Require `to`/`chatId`, `messageId`, and `attachmentId`, failing before dispatch when `attachmentId` is missing.
- Fix attachment summaries so `attachments[].id` is the stable message attachment id and preserve the inner preview/task id separately.
- Keep docs explicit that the server only deletes supported attachments from messages authored by the current bot/user.

Implementation notes:
- Added method fallback for `DELETE_MESSAGE_ATTACHMENT = 55`.
- Added message-tool schema contribution and target aliases for `delete-attachment`/`deleteMessageAttachment`.
- Dispatch now sends `{ oneofKind: "deleteMessageAttachment", deleteMessageAttachment: { peerId, messageId, attachmentId } }`.
- `message-content.ts` now maps `MessageAttachment.id` to `attachments[].id`, with `urlPreviewId` and `externalTaskId` for inner ids.
- Native Slack file-action patterns reviewed: Slack distinguishes message timestamps from file ids and throws clear validation errors, so Inline now similarly asks for `attachmentId` from read/search output.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (45 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/message-content.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- The action is intentionally precise and does not attempt to delete media files or external tasks. Server-side support currently validates URL-preview attachments and author ownership.

## Iteration 13: forward messages action

Status: complete.

Problem:
- The plugin had a standalone `inline_forward` tool and the Inline server exposes `FORWARD_MESSAGES`, but the common channel `message` action adapter did not advertise or dispatch `forward`/`forwardMessages`.
- Agents using native channel action discovery could send, reply, delete, translate, and manage chats, but could not forward Inline messages through the shared Telegram/Slack-style message action path.

Plan:
- Add `forward` and `forwardMessages` under the existing `send` gate because forwarding creates outbound messages.
- Reuse the standalone forward tool semantics: destination is required, source can be explicit, and source defaults to the current Inline chat when available.
- Accept chat and user peers for both source and destination, support one or more message ids, and expose `shareForwardHeader`.
- Add discovery schema, aliases, tests, docs, and verification.

Implementation notes:
- Added `forward` and `forwardMessages` to the `send` action gate and message-tool discovery.
- Added forward schema properties and target aliases for source, destination, message ids, and forward-header behavior.
- Added peer resolution for chat/user sources and destinations, with current chat fallback only for the source.
- Added message-id resolution that defaults to the current inbound message when available.
- Dispatch now calls `FORWARD_MESSAGES` and returns forwarded source ids plus any new message ids found in update payloads.
- Native OpenClaw/Inline patterns reviewed: the standalone `inline_forward` tool already used this source/default/destination model, so the message action now matches that existing dedicated tool instead of inventing different behavior.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- Forwarding is grouped under `send` rather than a separate action gate, matching the fact that it creates outbound messages. If users need finer policy later, `forward` can be split into a dedicated gate without changing the runtime action contract.

## Iteration 14: native upload-file action alias

Status: complete.

Problem:
- Native OpenClaw Slack and Discord plugins advertise `upload-file`, but Inline only advertised `sendAttachment`.
- Inline already supports local paths and media URLs through the same upload/send path, so agents trained on native channel action names can miss Inline's equivalent capability.

Plan:
- Add `upload-file` under the existing `send` gate as an alias for media-backed sends.
- Keep the existing media source aliases (`filePath`, `path`, `media`, `mediaUrl`, `file`, etc.) and require at least one media input.
- Add discovery schema/aliases, tests, docs, and verification.

Implementation notes:
- Added `upload-file` to the `send` action gate alongside `sendAttachment`.
- Routed `upload-file` through the existing media upload/send branch, so it supports the same local path and media URL handling.
- Added schema contribution and aliases for native file-action inputs such as `filePath`, `path`, `media`, `mediaUrl`, and `url`.
- Kept no-media validation explicit and action-specific before any upload/send is attempted.
- Native Slack/Discord patterns reviewed: both expose `upload-file` as the common channel action name, so Inline now advertises the same name while preserving the existing `sendAttachment` alias.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- `upload-file` does not add filename/title overrides yet because the current Inline upload helper derives a safe filename from the loaded media. That keeps this iteration as an action-surface compatibility fix without changing media upload semantics.

## Iteration 15: archive and unarchive dialog actions

Status: complete.

Problem:
- Inline exposes `UPDATE_DIALOG_OPEN`, and the Apple clients use it to archive/unarchive chats, but the OpenClaw message action surface could only surface hidden chats via `show-in-chat-list`.
- Agents had no reversible way to archive a chat from the common channel action path.

Plan:
- Add `archive` and `unarchive` under the existing `channels` gate.
- Map `archive` to `UPDATE_DIALOG_OPEN` with `open: false`, and `unarchive` to `open: true`.
- Reuse the existing chat target parsing and return string-safe chat/dialog details.
- Avoid `clearChatHistory` in this iteration because it is destructive and requires separate confirmation/guard design.

Implementation notes:
- Added `archive` and `unarchive` to the channel-management action group.
- Added method fallback for `UPDATE_DIALOG_OPEN = 51`.
- Added discovery schema and target aliases using the same `to`/`chatId`/`channelId` shape as other chat-list controls.
- Dispatch now sends `{ oneofKind: "updateDialogOpen", updateDialogOpen: { peerId, open } }` and returns updated chat/dialog/user details.
- Native/client semantics reviewed in server and Apple code: `open: false` archives/removes from the active sidebar inbox, while `open: true` restores it.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- I deliberately did not add `clearChatHistory` here. That action deletes user-visible history and reply-thread state, so it should get its own confirmation/guard design instead of being bundled with reversible archive controls.

## Iteration 16: mute and unmute dialog notifications

Status: complete.

Problem:
- Inline exposes `UPDATE_DIALOG_NOTIFICATION_SETTINGS`, but the OpenClaw message action surface did not let agents mute a noisy Inline chat or clear a chat-specific mute.
- The protocol names the mute mode `NONE`, which is easy for agents to miss if we expose the raw enum instead of a native chat action.

Plan:
- Add `mute` and `unmute` under the existing `channels` gate because they change per-dialog chat state for the current bot/user.
- Map `mute` to `{ notificationSettings: { mode: NONE } }` and `unmute` to an omitted `notificationSettings`, which clears the override back to inherited/global notification settings.
- Reuse the existing chat target parsing and return explicit state so agents can tell whether the dialog is muted or inheriting global settings.

Implementation notes:
- Added method fallback for `UPDATE_DIALOG_NOTIFICATION_SETTINGS = 39`.
- Added discovery schema and target aliases for `mute`/`unmute` using the same `to`/`chatId`/`channelId` target shape as other dialog controls.
- Dispatch now sends `{ oneofKind: "updateDialogNotificationSettings", updateDialogNotificationSettings: { peerId, notificationSettings } }` for mute and omits `notificationSettings` for unmute.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- This iteration only exposes binary mute/unmute. The lower-level protocol also supports an explicit mentions-only mode, which should be added later as a separate `notification-settings` style action if users need that precision.

## Iteration 17: pin and unpin sidebar dialogs

Status: complete.

Problem:
- Inline exposes `UPDATE_DIALOG_ORDER` for sidebar order and pinned state, and the Apple clients use it for pinning chats, but the OpenClaw message action adapter only had message-level `pin`/`unpin`.
- Reusing `pin` for dialogs would collide with native Slack-style message pins and the existing Inline `PIN_MESSAGE` action.

Plan:
- Add `pin-chat` and `unpin-chat` under the existing `channels` gate, with `pinChat`/`unpinChat` aliases.
- Map the actions to `UPDATE_DIALOG_ORDER` with `pinned: true` or `pinned: false`.
- Do not expose raw fractional `order`/`pinnedOrder` yet; keep this iteration to the reversible sidebar pin state.

Implementation notes:
- Added method fallback for `UPDATE_DIALOG_ORDER = 52`.
- Added discovery schema and target aliases for `pin-chat`/`unpin-chat`/camelCase aliases.
- Dispatch now sends `{ oneofKind: "updateDialogOrder", updateDialogOrder: { peerId, pinned } }` and returns updated chat/dialog/user details.
- Native OpenClaw Slack patterns reviewed: `pin`/`unpin` are message-pin actions, so Inline sidebar pinning gets explicit chat-scoped names.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- This does not implement sidebar drag-and-drop reordering. Fractional ordering requires order generation and should get a separate design if agents need deterministic sidebar placement.

## Iteration 18: follow and unfollow reply threads

Status: complete.

Problem:
- Inline exposes `UPDATE_DIALOG_FOLLOW_MODE` for reply-thread surfacing, and the macOS toolbar uses it for Follow Thread / Unfollow Thread, but the OpenClaw message action surface could not toggle it.
- This is distinct from notification mute: follow mode controls whether a reply-thread chat is actively surfaced in the sidebar for new replies.

Plan:
- Add `follow-thread` and `unfollow-thread` under the existing `channels` gate, with `followThread`/`unfollowThread` aliases.
- Map follow to `followMode: FOLLOWING` and unfollow to omitted `followMode`, matching Apple’s `following` versus `relevance` selection.
- Keep the action reply-thread-only and document that normal chats will be rejected by the server.

Implementation notes:
- Added method fallback for `UPDATE_DIALOG_FOLLOW_MODE = 60`.
- Added discovery schema and aliases for reply-thread ids.
- Dispatch now sends `{ oneofKind: "updateDialogFollowMode", updateDialogFollowMode: { peerId, followMode } }` and returns `following` plus the user-facing mode (`following` or `relevance`).
- Server/client semantics reviewed: following a reply thread opens/surfaces it; unfollowing clears the explicit follow mode.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- The action only toggles the explicit follow state. It does not expose any future granular relevance policy because the protocol currently has only `FOLLOWING` or unset/default.

## Iteration 19: compose indicators

Status: complete.

Problem:
- Inline exposes `SEND_COMPOSE_ACTION` for transient typing/uploading/recording indicators, and the Apple clients use the same enum for typing, upload states, and voice recording.
- The OpenClaw action surface could send messages and files but could not send or clear compose state, so agents had no native way to show common chat-app activity indicators.

Plan:
- Add compose actions under the existing `send` gate because they are outbound, user-visible chat signals.
- Expose direct actions for common states (`typing`, `stop-typing`, upload states, `recording-voice`) plus a generic `compose-action` for flexible tool use.
- Keep dispatch thin: resolve the Inline peer, map public action names to `UpdateComposeAction.ComposeAction`, and let the server validate access.

Implementation notes:
- Added method fallback for `SEND_COMPOSE_ACTION = 20`.
- Added discovery schema and aliases for `compose-action`, `typing`, `stop-typing`, `uploading-photo`, `uploading-document`, `uploading-video`, and `recording-voice`.
- Dispatch now sends `{ oneofKind: "sendComposeAction", sendComposeAction: { peerId, action } }` and returns the resolved target, compose label, numeric enum, and whether the current chat fallback was used.
- Server/client semantics reviewed: the server validates the peer via `ChatModel.getChatFromInputPeer`, broadcasts to other participants, and treats `NONE`/unset as stop.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (46 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- This exposes state updates only. It does not add auto-refresh loops for long uploads or typing sessions; agents can send another compose action if they need to extend the six-second client-side expiry window.

## Iteration 20: richer read history

Status: complete.

Problem:
- Inline `GET_CHAT_HISTORY` supports explicit latest, older, newer, and around-window modes, but the OpenClaw `read` action only used legacy older-history pagination through `offsetId`/`before`.
- Native Slack-style read actions accept `before`, `after`, `messageId`, and thread context. Inline agents were missing the same reliable history navigation and had no automatic current reply-thread read target.

Plan:
- Keep the existing `read` action but infer the history mode from familiar parameters: no cursor = latest, `before`/`offsetId` = older, `after` = newer, and `messageId`/`anchorId` = around-window.
- Add early errors for ambiguous cursor combinations instead of silently selecting one.
- Resolve read targets from `threadId`, explicit chat/user target, current reply-thread chat, then current chat.

Implementation notes:
- Added discovery schema and target aliases for `read` parameters: `before`, `after`, `messageId`/`anchorId`, `beforeLimit`, `afterLimit`, `includeAnchor`, `threadId`, and target aliases.
- Added numeric fallbacks for `GetChatHistoryMode` values: latest `1`, older `2`, newer `3`, around `4`.
- Dispatch now sends explicit `mode` payloads and returns cursor metadata plus whether the current chat or current reply thread default was used.
- Older reads still include `offsetId` with `beforeId` for compatibility with legacy server behavior.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (48 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.
- Blocked: `cd packages/openclaw && bun run typecheck` still fails because `@inline-chat/realtime-sdk` has no resolvable type declarations in this workspace package, causing the existing implicit-any cascade across Inline plugin files.

Tradeoff:
- The tool does not implement arbitrary before+after range reads because the Inline protocol exposes separate newer/older modes rather than a bounded range mode. Agents should use `messageId`/`anchorId` with `beforeLimit`/`afterLimit` for centered windows.

## Iteration 21: special tool discoverability

Status: complete.

Problem:
- Inline already registered several dedicated tools outside the `message` action surface, but the runtime agent guidance only named part of them.
- `inline_members`, `inline_parent_context`, `inline_update_profile`, and `inline_bot_commands` were easy for the agent to miss during normal Inline turns, despite being present in `openclaw.plugin.json` and runtime registration.

Investigation:
- Confirmed registered tool contracts in `openclaw.plugin.json`, `runtime-register-api.ts`, `manifest.test.ts`, and `index.test.ts`.
- Reviewed native OpenClaw Slack/Discord prompt style: channel hints are concise operational reminders rather than full API documentation.
- Verified README had parent-context, members, and bot-command coverage but did not list the nudge/forward/presence/profile/avatar tools together under Extra Agent Tools.

Plan:
- Keep runtime behavior unchanged and fix discoverability first.
- Add concise channel prompt hints for all registered Inline special tools.
- Guard identity-changing tools so agents only use profile/avatar/command setup when the user explicitly asks.
- Add prompt regression coverage and README documentation.

Implementation notes:
- `channel.ts` now tells agents when to use `inline_members`, `inline_parent_context`, `inline_nudge`, `inline_forward`, `inline_bot_presence`, `inline_update_profile`, `inline_bot_avatar`, and `inline_bot_commands`.
- `channel.test.ts` asserts that all registered special tools appear in the Inline prompt hints.
- README Extra Agent Tools now lists nudge, forward, bot presence, bot profile update, and bot avatar setup alongside the existing parent-context, members, and bot command docs.

Verification:
- Passed: `cd packages/sdk && bun run build` to materialize the local symlinked `@inline-chat/realtime-sdk` dist required by OpenClaw's bundled entry loader.
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts src/inline/channel.test.ts src/manifest.test.ts` (63 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- This iteration intentionally did not add duplicate message actions for existing dedicated tools. The immediate bug was discoverability; runtime/API bugs inside each special tool should be handled as separate iterations.

## Iteration 22: bot command menu retry

Status: complete.

Problem:
- Inline startup command sync capped the resolved command menu at 100 entries, but if the Bot API still rejected that menu as `BOT_COMMANDS_TOO_MUCH`, sync failed and left the bot command menu stale or missing.
- Native Telegram command sync already handles this platform failure mode by retrying with a smaller command set and logging the omitted entries.

Plan:
- Keep the explicit `inline_bot_commands` management tool strict so manual command-set requests are not silently changed.
- Add retry behavior only to automatic startup sync.
- Detect `BOT_COMMANDS_TOO_MUCH`, retry once with 80% of the attempted commands, and report the accepted command count.

Implementation notes:
- Added `isInlineBotCommandsTooMuchError` and `setInlineBotCommandsWithRetry` to `bot-commands-sync.ts`.
- The sync result now counts the account as synced when the reduced retry succeeds, and the final info log uses the accepted command count.
- README now documents the automatic reduced-menu retry.
- Added a regression that mocks a 100-command rejection and verifies the 80-command retry, warning logs, and final sync count.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-sync.test.ts` (10 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts src/manifest.test.ts src/inline/channel.test.ts src/inline/bot-commands-tool.test.ts` (69 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/bot-commands-sync.ts packages/openclaw/src/inline/bot-commands-sync.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- The retry drops lower-priority tail commands from the automatic menu rather than doing deeper prioritization. This matches the existing first-100 ordering and keeps the fix small; command ordering/priority can be improved separately if needed.

## Iteration 23: exact message fetch action

Status: complete.

Problem:
- Inline protocol exposes `GET_MESSAGES` for exact message-id fetches, and the OpenClaw plugin already used it internally for reactions, but the agent could not call it directly.
- Agents had to approximate with `read` history windows even when they already had one or more concrete message ids.

Plan:
- Add `get-messages`/`getMessages` under the existing read gate.
- Reuse read target resolution so omitted targets default to the current reply-thread chat before the parent chat.
- Return the same mapped media-aware message payload shape as `read` and `search`.
- Do not expose destructive `CLEAR_CHAT_HISTORY` in this iteration.

Implementation notes:
- Added action registration, schema, aliases, and dispatch for `GET_MESSAGES`.
- Added an explicit numeric fallback for `GET_MESSAGES = 38` so a stale bundled SDK enum does not disable exact fetch.
- Added message id de-duplication and current inbound message fallback for single-message fetches.
- README now lists exact fetch under reading/searching/translating and documents reply-thread-aware targeting.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (49 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts src/manifest.test.ts src/inline/channel.test.ts src/inline/bot-commands-sync.test.ts` (73 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/bot-commands-sync.ts packages/openclaw/src/inline/bot-commands-sync.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- This is an exact-id fetch only. It does not replace `read` pagination or add range semantics; agents should still use `read` for latest/older/newer/around history.

## Iteration 24: bot avatar clear action

Status: complete.

Problem:
- The Inline protocol and server expose `CLEAR_BOT_AVATAR`, but the `inline_bot_avatar` tool only installed/replaced Codex atlas zip packages.
- Agents could not remove their on-screen avatar even when the user explicitly asked, despite avatar setup being a registered special tool.

Plan:
- Keep avatar install behavior backward compatible as the default operation.
- Add explicit clear support with `action: "clear"` and `clear: true`.
- Ensure clearing never loads or uploads a package and rejects ambiguous clear requests that also include package/display metadata.

Implementation notes:
- Added `SET_BOT_AVATAR` and `CLEAR_BOT_AVATAR` numeric fallbacks to tolerate stale SDK enums.
- `inline_bot_avatar` now branches before package loading for clear operations and calls `{ oneofKind: "clearBotAvatar" }`.
- README and agent guidance now mention install/replace/clear while preserving the warning not to use avatar tooling for mood or presence changes.
- Added tests for successful clear and ambiguous clear-with-source rejection.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-avatar-tool.test.ts` (7 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/index.test.ts src/manifest.test.ts src/inline/actions.test.ts` (112 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/bot-avatar-tool.ts packages/openclaw/src/inline/bot-avatar-tool.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- The tool accepts a few runtime aliases (`install`, `replace`, `remove`, `delete`) even though the exposed schema keeps the public action enum to `set`/`clear`. This preserves forgiving tool behavior without broadening the documented API surface too much.

## Iteration 25: bot presence read action

Status: complete.

Problem:
- Inline protocol exposes `GET_BOT_PRESENCE`, but the `inline_bot_presence` special tool only set body state.
- Agents could update their on-screen body but could not inspect the current avatar/state for a chat or user target.

Plan:
- Add `action: "get"` to the existing `inline_bot_presence` tool instead of registering another special tool.
- Keep the default action as set so existing calls with `kind` continue to work.
- Return the current avatar, state, readable kind label, comment, peer id, and bot user id when available.

Implementation notes:
- Added numeric fallbacks for `GET_BOT_PRESENCE = 58` and `SET_BOT_PRESENCE_STATE = 59`.
- Removed the global `kind` requirement from the tool schema because reads do not require a state.
- Added a reverse state-kind mapper so `action: "get"` returns both the raw state and a readable `kind`.
- README and agent guidance now mention `action: "get"`/`action: get` for presence inspection.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/message-tools.test.ts` (10 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/index.test.ts src/manifest.test.ts src/inline/bot-avatar-tool.test.ts` (70 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/message-tools.ts packages/openclaw/src/inline/message-tools.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/bot-avatar-tool.ts packages/openclaw/src/inline/bot-avatar-tool.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- The read action returns raw avatar/peer protocol shapes in addition to normalized fields. That keeps the tool complete without designing a lossy custom avatar schema in this iteration.

## Iteration 26: dialog notification modes

Status: complete.

Problem:
- Inline dialog notification settings support explicit `all`, `mentions`, `none`, and unset/inherit modes, but the OpenClaw action surface only exposed `mute` and `unmute`.
- Agents could not set a chat to mentions-only or force all notifications for a specific dialog.

Plan:
- Keep `mute` and `unmute` as familiar aliases.
- Add `notification-settings` and `set-notifications` under the existing channel/dialog gate.
- Map `mode: "all"|"mentions"|"none"|"inherit"` and a boolean `muted` shortcut to the protocol payload.

Implementation notes:
- Added dialog notification mode constants for all/mentions/none.
- Added schema fields and aliases for `mode`, `notificationMode`, and `muted`.
- Replaced the mute/unmute-only branch with a generic resolver that clears the override for inherit/default/global/clear/unset.
- README now documents the explicit per-dialog notification mode action.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (49 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/index.test.ts src/manifest.test.ts src/inline/message-tools.test.ts` (73 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/message-tools.ts packages/openclaw/src/inline/message-tools.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- This stays scoped to per-dialog settings. It does not expose global user notification settings because those are broader account preferences and should be handled in a separate, more deliberate iteration.

## Iteration 27: parent-context history windows

Status: complete.

Problem:
- `inline_parent_context` only exposed older-history reads through `beforeMessageId`/legacy `offsetId`.
- The regular Inline `read` action and native OpenClaw Slack dispatch both support targeted `before`/`after`/`messageId` reads, but the special reply-thread parent-context tool could not fetch newer context or an around-window for a specific parent message.
- The default reply-thread path used two RPCs: one exact anchor fetch plus one older-history fetch.

Plan:
- Keep the old default semantics for reply threads: return the parent/root anchor plus older parent-chat context.
- Reuse the protocol `GET_CHAT_HISTORY` modes: `latest`, `older`, `newer`, and `around`.
- Add explicit cursor validation so impossible combinations fail early instead of being silently ignored.
- Document the richer cursor surface and agent guidance.

Implementation notes:
- Added `afterMessageId`, `messageId`/`aroundMessageId`, `mode`, `beforeLimit`, and `afterLimit` to `inline_parent_context`.
- Replaced the old parent-context loader with a shared request resolver that builds `GET_CHAT_HISTORY` inputs for latest/older/newer/around windows.
- The reply-thread default now uses one `around` request anchored to `parentMessageId`, with `afterLimit: 0`, preserving the previous "anchor plus older context" behavior while avoiding a second exact-message RPC.
- Results now include `mode`, cursor ids, before/after around limits, and both `nextBeforeMessageId` and `nextAfterMessageId`.
- Agent guidance and README now describe older/newer/around parent-context windows.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/parent-context-tool.test.ts` (4 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/parent-context-tool.ts packages/openclaw/src/inline/parent-context-tool.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- The around-window defaults remain intentionally conservative for reply-thread sessions: they do not pull newer parent-chat messages unless requested. This avoids mixing unrelated parent-chat activity into a reply-thread answer by default.

## Iteration 28: copy-text message action buttons

Status: complete.

Problem:
- Inline protocol supports `MessageActionCopyText`, but the OpenClaw plugin only emitted callback buttons from message-tool sends, reply payloads, and outbound rendered presentations.
- Agents could ask users to copy text manually, but could not send a native client-side copy button even though the platform supports it.

Plan:
- Add this as an Inline-specific `buttons` extension without changing shared OpenClaw `presentation` semantics.
- Preserve existing callback behavior by preferring `callback_data` when both callback and copy fields are present.
- Mirror the server copy-text limit in plugin-side sanitization and document the new button fields.

Implementation notes:
- Added `sanitizeInlineActionCopyText` with the server's 4096-character limit.
- Extended `resolveInlineMessageActionsParam` to accept `copy_text` and `copyText` in button rows and emit protocol `copyText` actions.
- Added the same copy-text support to the monitor reply/outbound parser so agent replies using `channelData.inline.buttons` preserve copy buttons.
- Replaced the shared callback-only button schema in Inline discovery with an Inline-specific schema that documents `callback_data`, `copy_text`, and `copyText`.
- README and agent guidance now mention copy-text buttons.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/outbound-sanitize.test.ts src/inline/actions.test.ts` (64 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "maps Inline copy-text buttons"` (1 selected test).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/src/inline/outbound-sanitize.ts packages/openclaw/src/inline/outbound-sanitize.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .wip`.

Tradeoff:
- Shared `presentation` buttons with URLs or web apps are still not mapped to Inline actions because Inline currently exposes callback and copy-text actions only. URL/web-app support should wait for a platform-level action kind instead of being degraded into a misleading copy action.

## Iteration 29: peer bot-command discovery

Status: complete.

Problem:
- Inline exposes `GET_PEER_BOT_COMMANDS`, and the server already resolves bot commands available in a chat, DM, or inherited reply-thread context.
- The OpenClaw plugin only exposed `inline_bot_commands`, which manages this bot's registered menu through the Bot API and does not answer the native-channel question "what commands are available in this peer?".
- Agents had no read-only tool/action for command discovery in the current Inline conversation.

Plan:
- Add read-only command discovery to the `message` action surface instead of broadening token-backed bot management.
- Put it under the existing `read` action gate so deployments that disable reads also disable peer command inspection.
- Reuse current Inline target resolution so omitted targets default to the current chat/reply thread.

Implementation notes:
- Added `bot-commands`, `botCommands`, `peer-bot-commands`, and `peerBotCommands` action aliases.
- Added a guarded `GET_PEER_BOT_COMMANDS` method fallback and a `getPeerBotCommands` RPC branch.
- Normalized the result to bot identity, command count, and command name/description/sort order while preserving JSON-safe ids.
- Added discovery schema and target aliases for chat/user/reply-thread targets.
- README and agent guidance now distinguish peer command discovery from `inline_bot_commands` menu management.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (50 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .wip`.

Tradeoff:
- This iteration only reads commands available in a peer. Setting this bot's own command menu remains in `inline_bot_commands`, because that path has separate ownership, validation, and token-management concerns.

## Iteration 30: infer space for member discovery

Status: complete.

Problem:
- `inline_members` required an explicit `spaceId` even when invoked from an Inline space chat or reply thread.
- This made user lookup weaker than native chat-provider behavior and forced agents to ask for or discover a space id before resolving users in the current conversation.

Plan:
- Keep explicit `spaceId` as the no-surprise path.
- When `spaceId` is omitted, infer it only from current Inline session context by reading the current chat with `GET_CHAT`.
- In reply-thread sessions, fall back to the parent chat if the child thread does not carry a space id.
- Return metadata showing whether the space id was inferred.

Implementation notes:
- Made `spaceId` optional in `inline_members` and added `space` as an alias.
- Added current Inline session parsing to the members tool context.
- Added guarded `GET_CHAT` lookup for current-chat and parent-chat space inference.
- Results now include `inferredSpaceId`, `spaceIdSource`, and `sourceChatId`.
- README and agent guidance now explain that `inline_members` can infer the current space in Inline space chats/reply threads.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/members-tool.test.ts` (2 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/members-tool.ts packages/openclaw/src/inline/members-tool.test.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .wip`.

Tradeoff:
- The tool still requires an explicit `spaceId` in DMs and non-space chats. That avoids guessing across spaces or leaking unrelated membership lists.

## Iteration 31: callback toast acknowledgement UI

Status: complete.

Problem:
- Inline protocol and server support `MessageActionResponseUi.toast` when answering a message-action callback, but OpenClaw always answered callbacks with only `interactionId`.
- Native Telegram answers callback queries immediately before heavier processing, and Discord interaction paths defer or send ephemeral acknowledgement early. Inline had the immediate ack, but it dropped the available UI feedback.
- A reply payload extension such as `channelData.inline.callbackToast` would arrive after the immediate callback answer, so using final agent output for the toast would either be too late or would risk delaying the acknowledgement.

Plan:
- Keep the existing immediate callback acknowledgement behavior.
- Resolve optional toast UI from the callback data itself because that data is available before agent dispatch.
- Mirror the server toast text limit of 256 characters and sanitize internal/runtime text before sending UI.
- Document the JSON `callback_data` convention for agents.

Implementation notes:
- Added `resolveInlineCallbackResponseUi` to parse JSON callback data and read `callbackToast`, `callback_toast`, or `toast`.
- Updated `answerInlineMessageAction` to pass optional `MessageActionResponseUi` through both the SDK `answerMessageAction` path and the fallback raw RPC path.
- Kept ordinary callback payloads unchanged; JSON without toast metadata still answers with only `interactionId`.
- Updated button schema descriptions, agent guidance, and README docs to explain short callback toast acknowledgements.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "message action callbacks"` (2 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/actions.test.ts` (107 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (136 tests).
- Passed: `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/channel.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- This only supports toasts that are known at callback press time. It intentionally does not delay the callback acknowledgement to wait for the agent's final reply, preserving the native-style fast feedback path.

## Iteration 32: prune client-control actions from bot surface

Status: complete.

Problem:
- Earlier iterations exposed several Inline personal client-state controls through the common `message` action surface: `mark-read`/`mark-unread`, `show-in-chat-list`, archive/unarchive, mute/unmute, per-dialog notification settings, sidebar chat pinning, and reply-thread follow/unfollow.
- These actions change the bot account's client UI or read/preference state rather than helping a bot participate in chat. They contradicted the new scope note that Inline OpenClaw should be a bot surface, not a full user-client control surface.
- Keeping them advertised also made the tool list noisier and increased the chance of agents choosing low-value actions.

Native reference notes:
- Telegram exposes bot/chat workflow actions such as send, edit, delete, reactions, stickers, polls, and forum-topic create/edit, but not personal read-state, sidebar, follow, or notification preference controls.
- Slack and Discord expose message, thread, file, channel, reaction, pins, and moderation/admin workflows, but hidden/archive state is mainly discovery metadata, not a default agent action.

Plan:
- Keep useful chat workflow actions, including message-level `pin`/`unpin`/`list-pins`.
- Remove personal client-state controls from `SUPPORTED_ACTIONS`, schema contributions, target aliases, and runtime dispatch branches.
- Update README/tool docs and tests so the absence is explicit.

Implementation notes:
- Removed `mark-read`/`mark-unread` from the read action group and deleted their `readMessages`/`markAsUnread` runtime branch.
- Removed `show-in-chat-list`/`showInChatList`, `archive`/`unarchive`, `mute`/`unmute`, `notification-settings`/`set-notifications`, `pin-chat`/`unpin-chat`, and `follow-thread`/`unfollow-thread` aliases from the channel action group.
- Deleted the corresponding schema blocks, target aliases, protocol method fallbacks, helper resolvers, and runtime branches.
- README now lists only bot-useful channel/thread actions and no longer documents client UI preference controls.
- Tests now assert these actions are absent from configured discovery/schema/aliases while preserving message-level pin actions.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (50 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: stale-surface search across `packages/openclaw/src`, `packages/openclaw/README.md`, and `packages/openclaw/openclaw.plugin.json`; remaining hits are negative tests and read-only `archived` metadata fields.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/README.md .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- This removes agent-facing convenience for changing the bot account's own client state. If a concrete bot workflow later needs one of these RPCs, it should return as a deliberately scoped direct tool or gated action with explicit prompting, not as part of the default common message action list.

## Iteration 33: isolate active reply-thread routes per agent

Status: complete.

Problem:
- The reply-thread route store already had an optional `agentId` dimension for active route keys, but the common Inline action adapter never passed agent identity into route remember/lookup.
- When multiple agents created reply threads under the same parent chat without a parent message id, the default active route fallback could make a later `thread-reply` land in the wrong thread.
- Native Slack/Discord-style thread routing keeps thread bindings scoped to the bot/session context that created them. Inline had the storage shape for this, but the action bridge was dropping that context.

Plan:
- Keep `agentId` as internal runtime metadata rather than advertising it as a model-facing tool argument.
- Resolve optional agent identity from action params/tool context only when present.
- Pass that identity through both `thread-create` route registration and `thread-reply` route lookup.

Implementation notes:
- Added `resolveInlineActionAgentId` in `actions.ts`, reading `__agentId`, `agentId`, `toolContext.agentId`, or `toolContext.currentAgentId`.
- `thread-create` now records an agent-specific active route when metadata is present, while still writing the existing default active route for legacy callers.
- `thread-reply` now tries the agent-specific active route before the default active route through the existing route-store lookup behavior.
- Added regression coverage for two agents creating active routes in the same parent chat and then resolving to different reply threads without passing `threadId`.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "thread-reply"` (5 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (51 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- This only isolates active-route fallback when the OpenClaw runtime supplies agent metadata. Message-specific routes remain keyed by parent message id first, and legacy calls without agent metadata still use the shared default active route for backward compatibility.

## Iteration 34: preserve active reply-thread fallback with inherited message context

Status: complete.

Problem:
- `thread-reply` used `currentMessageId` from tool context as a parent-message route key even when the agent did not explicitly pass `parentMessageId`.
- If an active route existed for the parent chat but no message-specific route existed for the inherited current message, route lookup returned null and `thread-reply` failed.
- This made a normal context-rich turn less reliable than a bare call, because extra inbound message metadata accidentally disabled the active-route fallback.

Native reference notes:
- Slack action threading resolves an automatic thread only from current channel/thread context and validates that the target channel matches; incidental message metadata does not become a hard route constraint.
- Telegram reply delivery applies reply ids according to reply mode/progress, keeping implicit context separate from explicit target selection.

Plan:
- Treat explicit `parentMessageId`/`threadParentMessageId`/`anchorMessageId` as exact route keys.
- Treat inherited `currentMessageId` as a route hint: try it first, then fall back to the active parent-chat route when no message-specific route exists.
- Keep the returned `parentMessageId` honest: active fallback without a message-specific route reports `null`.

Implementation notes:
- Replaced the route parent id helper with `resolveThreadReplyRouteParentMessageHint`, which records whether the id was explicit, context-derived, or absent.
- `resolveInlineThreadReplyTarget` now does a second lookup without `parentMessageId` only when the first miss came from context-derived message metadata.
- Added a regression where `thread-create` records only an active route, then `thread-reply` runs with `toolContext.currentMessageId` and still resolves the active route.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "thread-reply"` (6 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (52 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- Explicit parent-message route lookup remains exact and still fails when no matching route exists. The fallback is only for inherited context metadata, which prevents accidental misrouting while restoring the intended active-route recovery path.

## Iteration 35: record participation after routed thread-reply tool sends

Status: complete.

Problem:
- Inline monitor uses persistent thread participation to continue bot-participated reply threads without requiring a fresh mention when history is sparse or after restart.
- The monitor records participation for replies it delivers, but the common `message({ action: "thread-reply" })` tool did not record participation after a successful routed send.
- A bot could therefore send into a reply thread via the tool, then fail to continue a later no-mention follow-up in that same thread if recent history did not expose the bot message.

Native reference notes:
- Slack records thread participation after successful threaded sends in both normal dispatch and direct send paths.
- Slack only records after delivery succeeds and only when it knows the concrete channel/thread target. Inline should follow the same invariant.

Plan:
- Record Inline thread participation after a successful `thread-reply` send when the target was resolved through a known parent chat/thread route.
- Preserve conservative behavior for explicit `threadId` sends where no parent chat is known.
- Assert the same persistent key that the monitor later checks for implicit reply-thread continuation.

Implementation notes:
- Imported `recordInlineThreadParticipation` into `actions.ts`.
- After `thread-reply` sends successfully, the action records `{ accountId, parentChatId, childThreadId, agentId? }` when `resolveInlineThreadReplyTarget` supplied `parentChatId`.
- Extended the saved parent-message route regression to attach runtime state and verify `default:70:770` is registered with `agentId: "main"`.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "thread-reply"` (6 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/thread-participation.test.ts` (4 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (52 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- Explicit `threadId` replies without parent chat metadata still do not record participation. That avoids inventing a parent relationship and keeps implicit no-mention continuation limited to reply threads Inline can prove are tied to a parent chat.

## Iteration 36: recover parent route metadata from explicit child thread ids

Status: complete.

Problem:
- Iteration 35 recorded participation for routed `thread-reply` sends only when `resolveInlineThreadReplyTarget` already knew the parent chat.
- A later tool call may pass an explicit `threadId` after an earlier `thread-create`, but the route store only supported parent-to-thread lookup. That meant Inline could not recover known parent metadata from the child thread id and therefore could not record participation for the successful send.
- Native Slack can record participation from an explicit thread send because Slack thread ids live inside a known channel. Inline child threads are separate chats, so the plugin needs saved route metadata before it can do the same safely.

Plan:
- Add a reverse `threadId` route key whenever a reply-thread route is remembered.
- Expose a lookup helper that resolves known route metadata by child thread id.
- Enrich explicit `threadId` and current-thread reply targets only when the reverse route exists; do not guess otherwise.

Implementation notes:
- Added `threadKey(accountId, threadId)` to `thread-routes.ts` and included it in `keysForRecord`.
- Added `lookupInlineReplyThreadRouteByThreadId`, sharing the same memory, keyed-store, and file fallback lookup path as existing route recovery.
- `resolveInlineThreadReplyTarget` now uses the reverse lookup for explicit `threadId` and `currentThreadTs`, returning parent metadata when present.
- Added route-store coverage for child-thread lookup and action coverage proving an explicit `threadId` reply after `thread-create` records the monitor-readable participation key.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/thread-routes.test.ts` (5 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "thread-reply"` (6 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (53 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/thread-routes.ts packages/openclaw/src/inline/thread-routes.test.ts packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- Explicit thread ids that have no saved route still behave as before and do not record participation. That is intentional because Inline cannot infer the parent chat from a child thread id alone without risking incorrect implicit no-mention routing.

## Iteration 37: record participation after outbound reply-thread sends

Status: complete.

Problem:
- Inline channel outbound `sendText` and `sendMedia` can route sends from a parent chat target into a child reply-thread chat via `threadId`.
- Those successful sends did not record thread participation, so later no-mention continuation in the same reply thread could fail after sparse history or a restart.
- Native Slack direct sends record thread participation after successful threaded sends, not before, and only when the concrete parent/thread target is known.

Plan:
- Record participation after `sendText`/`sendMedia` succeeds when the outbound target resolved to a parent chat and `threadId` resolved to a distinct child chat.
- Avoid recording for user targets, invalid thread ids, missing thread ids, or same-parent sends.
- Add focused channel regressions that assert the same persistent key the monitor later checks.

Implementation notes:
- Added a small `recordInlineOutboundThreadParticipation` helper in `channel.ts`.
- `sendMessageInline` and `sendMediaInline` now call it after `client.sendMessage` succeeds.
- Extended the channel test runtime helper to accept a keyed store, and asserted outbound reply-thread text/media sends register `default:7:42` with the participation TTL.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts -t "outbound sendText routes into the child reply-thread chat|outbound sendMedia routes into the child reply-thread chat"` (2 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/thread-participation.test.ts` (4 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.

Tradeoff:
- Channel outbound sends do not currently expose internal agent identity, so this records account/thread participation without an `agentId`, matching the existing direct-send style. Invalid or unresolved thread ids still do not record participation.

## Iteration 38: include same-second history in fresh-thread detection

Status: complete.

Problem:
- The reusable Inline fresh-vs-existing thread resolver only treated messages with `message.date < participant.date` as pre-join history.
- Inline message and participant timestamps are second-granularity, so a user message or prior bot mention sent just before the bot was added can share the same timestamp as the participant-add event.
- That edge made an existing thread look fresh, causing the bot to stay quiet instead of introducing itself and answering prior mentions.

Native reference notes:
- Native Slack history/context reads use inclusive timestamp boundaries when fetching nearby context, then filter exact current messages as needed.
- Inline should make the freshness classifier conservative at the join boundary because a false fresh classification drops a user-visible request.

Plan:
- Treat same-second visible user messages as pre-join history for participant-add freshness.
- Keep later messages, bot-authored messages, and empty history behavior unchanged.
- Cover both the reusable resolver and the monitor participant-add path.

Implementation notes:
- Changed `isPreJoinMessage` to use `message.date <= participantDate`.
- Added a resolver test proving same-second `@inlinebot` history is existing and tracked as a prior mention.
- Moved the monitor participant-add regression onto the exact participant timestamp so the full event path queues the system event with prior-mention guidance.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/thread-freshness.test.ts` (7 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "same-second existing bot participant-add|fresh bot participant-add"` (2 selected tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/thread-freshness.ts packages/openclaw/src/inline/thread-freshness.test.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- A user message sent immediately after the add event but inside the same timestamp second can now make the thread look existing. That is the safer failure mode for a bot surface because it avoids missing prior mentions; the participant-add event still only queues a system event, not a hard-coded greeting.

## Iteration 39: keep reply-thread route cache expiry tied to the route record

Status: complete.

Problem:
- Inline reply-thread route memory entries expired by cache-entry access time, not by the route record's own `updatedAt`.
- A route read just before its TTL expired refreshed the memory entry and could keep stale parent/thread metadata alive beyond the intended 7-day route lifetime.
- That made explicit child `threadId` recovery less reliable because old reverse-route metadata could be used for later sends after the route should have expired.

Native reference notes:
- Native Slack thread participation uses a TTL-bounded shared dedupe cache plus keyed-store TTL for persistent state.
- Native Telegram thread bindings explicitly clean up stale session bindings instead of preserving route state just because it was read.

Plan:
- Make memory lookup expire a route when either the cache entry is stale or the route record itself is stale.
- Add a regression that reads a route just before expiry, then proves the next lookup after the original TTL returns null.
- Keep route read recency useful only for cache eviction order, not for extending route validity.

Implementation notes:
- Updated `getMemory` in `thread-routes.ts` to also check `isExpired(entry.value, now)`.
- Added a `thread-routes.test.ts` regression for child-thread reverse lookup expiry after a near-expiry read.
- Restored Date mocks in the route-store test cleanup so future route tests do not inherit mocked clocks.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/thread-routes.test.ts` (6 tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "thread-reply"` (6 selected tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/thread-routes.ts packages/openclaw/src/inline/thread-routes.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- A frequently used route now expires at its original route TTL unless it is refreshed by a new route record. That may require agents to recreate/recover very old reply-thread routes, but it avoids silent misrouting from stale metadata.

## Iteration 40: cancel pending Inline debounce buffers on stop

Status: complete.

Problem:
- Inline now honors the shared `messages.inbound.debounceMs` / `messages.inbound.byChannel.inline` setting and the Inline account `debounceMs` override for normal rapid text bursts.
- Unlike Telegram, an Inline `/stop` message dispatched immediately but did not cancel already-buffered same-sender debounce entries.
- That meant text sent just before `/stop` could still flush after the stop turn, making stop feel queued and potentially starting more work after the user tried to interrupt.

Native reference notes:
- Telegram resolves the same shared inbound debounce setting for `channel: "telegram"`.
- Before enqueueing an authorized abort control message, Telegram cancels pending debounce keys for the same account/conversation/sender lanes so `/stop` is not followed by stale buffered text.

Plan:
- Keep Inline using `createChannelInboundDebouncer` so the shared OpenClaw debounce config path remains authoritative.
- When Inline sees an abort request, cancel the pending debounce buffer for the same account/chat/sender before priority dispatch.
- Add a regression using `messages.inbound.byChannel.inline` that waits past the debounce window and proves only `/stop` dispatched.

Implementation notes:
- Added `cancelPendingInlineDebounce` beside Inline inbound scheduling helpers.
- The `message.new` abort fast path now calls it before scheduling the priority abort dispatch.
- Existing tests already cover global by-channel debounce batching and Inline account-level `debounceMs`; the new test covers stop cancellation of a pending buffer.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "debounces rapid inbound text messages|uses Inline account debounceMs|cancels pending debounced text"` (3 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts -t "debounce"` (1 selected test).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (137 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- `/stop` now discards pending same-sender text that has not yet reached the agent. That matches the interrupt semantics users expect from Telegram-style debounce behavior.

## Iteration 41: cancel pending debounce buffers on voice-transcript stop

Status: complete.

Problem:
- Iteration 40 fixed normal Inline `/stop` text messages so they cancel pending same-sender debounce buffers before priority dispatch.
- Held Inline voice messages can later resolve to text via a `message.edit` transcript. If that transcript was `/stop`, the voice path dispatched the abort immediately but did not cancel pending debounced text.
- That left a mixed voice/text failure mode where a user could send a quick text, then a voice `/stop`, and the earlier text could still flush after the stop.

Native reference notes:
- Telegram cancels pending inbound debounce keys for authorized abort control messages before enqueueing them, covering the same conversation/sender lanes.
- Inline should keep all abort entry points aligned with that behavior, including transcript edits that become abort text after the initial voice event was held.

Plan:
- Reuse the existing `cancelPendingInlineDebounce` helper in the held-voice flush path.
- Keep the cancellation scoped to the same account/chat/sender key.
- Add a regression where a debounced text message is pending, a voice message is held for transcript, and the transcript edit resolves to `/stop`.

Implementation notes:
- `flushPendingVoiceMessage` now calls `cancelPendingInlineDebounce` before scheduling the priority voice-transcript abort dispatch.
- Added monitor coverage proving only the transcript `/stop` reaches the dispatcher and the earlier debounced text never finalizes.
- The regression also asserts the voice audio is not downloaded when the server transcript supplies the stop text.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "cancels pending debounced text when a voice transcript resolves to stop"` (1 selected test).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "debounces rapid inbound text messages|uses Inline account debounceMs|cancels pending debounced text|voice auto-transcript|raw voice audio"` (6 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (138 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.

Tradeoff:
- A voice transcript that resolves to `/stop` now drops same-sender text still sitting in the debounce buffer, matching normal text `/stop` semantics.

## Iteration 42: cancel held voice messages on text stop

Status: complete.

Problem:
- Text `/stop` canceled pending same-sender debounce buffers, but it did not cancel textless Inline voice messages already held while waiting for server transcription.
- A user could send a voice message, then send `/stop` before Inline's transcript edit or the raw-audio fallback timer. The held voice could still dispatch later as raw audio or as a transcript after the stop turn.
- If the held voice was simply deleted from the pending map, the later transcript edit would fall through to the generic message-edit lifecycle path and enqueue a system event.

Native reference notes:
- Telegram abort handling cancels pending inbound buffers for the same account/conversation/sender before enqueueing the abort control message.
- Inline has an additional server-transcript hold buffer for voice messages, so the same interrupt semantics need to cover that buffer too.

Plan:
- On same-sender Inline abort text, cancel pending held voice messages in the same chat.
- Suppress transcript edits for canceled voice message ids so they do not become generic lifecycle events after stop.
- Keep suppression bounded and clear timers during provider shutdown.

Implementation notes:
- Added a bounded suppressed voice-edit map alongside `pendingVoiceMessages`.
- Added `cancelPendingInlineVoiceMessages`, scoped by `chatId` and `fromId`.
- Text aborts now cancel both pending debounce buffers and pending voice buffers before priority dispatch.
- Voice-transcript aborts also cancel other held same-sender voice messages before dispatching.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "cancels held voice messages and suppresses their transcript edits"` (1 selected test).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "dispatches stop requests|cancels pending debounced text|cancels held voice messages|voice auto-transcript|raw voice audio"` (6 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (139 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.

Tradeoff:
- Transcript edits for a canceled voice message are suppressed for up to 60 seconds. That avoids post-stop lifecycle wakeups while keeping the suppression map bounded.

## Iteration 43: preserve source ids for debounced Inline bursts

Status: complete.

Problem:
- Inline now honors the shared `messages.inbound` debounce setting, including `messages.inbound.byChannel.inline` and the Inline account `debounceMs` override.
- When a same-sender burst was coalesced, Inline built a synthetic message from the last event and only exposed the last `MessageSid`.
- That matches OpenClaw's active reply-target rule, but it dropped traceability for the earlier messages in the burst and diverged from native Slack/Discord/Mattermost behavior.

Native reference notes:
- OpenClaw docs define inbound debounce as same-sender batching scoped by channel and conversation, with the most recent message used for reply threading/IDs.
- Native Slack and Discord attach `MessageSids`, `MessageSidFirst`, and `MessageSidLast` when multiple messages are merged.
- Native Mattermost does the same when a collected turn includes more than one source post id.

Plan:
- Keep `MessageSid` on the most recent Inline message so reply threading and abort cutoff behavior stay compatible.
- Carry all source message ids on debounced synthetic Inline turns with the existing `MessageSids` metadata fields.
- Prove the shared Inline debounce setting still batches text and now preserves the batch id envelope.

Implementation notes:
- Added optional `messageIds` to the internal `InlineParsedInboundEvent`.
- The debounce `onFlush` path now passes every source message id when it builds the synthetic combined message.
- `handleInboundNow` adds `MessageSids`, `MessageSidFirst`, and `MessageSidLast` only when the turn has more than one source id.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "debounces rapid inbound text messages|uses Inline account debounceMs|cancels pending debounced text"` (4 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (139 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-06-19-openclaw-plugin-hardening-log.md .wip`.

Tradeoff:
- The agent still replies to the latest message id, matching OpenClaw's documented debounce behavior. The earlier ids are metadata only, so this avoids changing delivery semantics while improving observability and hook context.

## Iteration 44: gate stop debounce cancellation by authorization

Status: complete.

Problem:
- Inline text `/stop` and voice-transcript `/stop` were detected in the event loop before the normal group/DM access and command authorization gates ran.
- The fast path canceled same-sender pending debounce and held voice buffers immediately.
- In a group, an unauthorized sender could send `/stop` and silently drop another pending debounced request, even though normal command handling would later reject the stop.

Native reference notes:
- Telegram checks `resolveTelegramCommandIngressAuthorization` before canceling pending inbound debounce keys.
- Telegram has a regression that an unauthorized group `stop` must not cancel a pending same-sender debounce buffer.

Plan:
- Add an Inline abort fast-path authorization resolver that mirrors the normal provider access rules used by `handleInboundNow`.
- Let authorized aborts keep the immediate cancel/priority dispatch behavior.
- Let unauthorized abort-looking text go through the normal inbound debouncer so existing buffered text flushes and the unauthorized command is dropped by the regular gate.
- Apply the same rule to held voice transcript edits that resolve to `/stop`.

Implementation notes:
- Added `isAuthorizedInlineAbortMessage`, scoped to the active account/chat/sender and aware of reply-thread parent chat context.
- Direct messages can fast-path stop only when the DM policy allows the sender.
- Group messages can fast-path stop only when group access allows the sender and text command authorization succeeds.
- Converted the held voice flush/edit path to async so transcript `/stop` can run the same authorization check before canceling buffers.

Verification:
- Failing-before-fix regression: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "does not cancel pending debounced text for unauthorized group stop requests"`.
- Passed after fix: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "does not cancel pending debounced text for unauthorized group stop requests"` (1 selected test).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "unauthorized.*stop"` (2 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "dispatches stop requests|cancels pending debounced text|unauthorized.*stop|cancels held voice messages|voice auto-transcript|raw voice audio"` (8 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (141 tests).
- Passed: `cd packages/openclaw && bun run lint`.
- Passed: `cd packages/openclaw && bun run typecheck`.

Tradeoff:
- The fast path now does a small amount of chat/access resolution before canceling buffers. That is intentional: authorized `/stop` remains immediate relative to active runs, while unauthorized abort-looking messages no longer destroy queued user input.

## Release readiness: 0.0.47

Status: prepared, publish blocked locally.

Scope:
- Bumped `@inline-openclaw/inline` from `0.0.46` to `0.0.47` in `packages/openclaw/package.json`.
- Updated the OpenClaw workspace package version entry in `bun.lock`.
- Confirmed the registry latest before publish was still `0.0.46`.

Verification:
- Passed: `cd packages/openclaw && bun run check` after the version bump. This covered typecheck, lint, 406 Vitest tests with coverage, and the package build.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 18.7 MB unpacked size, 127 files, shasum `fbf0e4b5f9ad5645e5521d21e5c02b262135f9b8`.
- Rechecked from the current checkout: `cd packages/openclaw && bun run check` passed again with 26 files and 406 tests, then `npm pack --ignore-scripts --pack-destination /tmp` regenerated the same `0.0.47` artifact and shasum.

Publish blockers:
- `npm whoami` returns `E401`, so this shell is not logged into npm.
- The 1Password-backed npm login path could not complete because `op` was unable to provide the NPM item/OTP through the desktop app integration during this pass.
- The `clawhub` CLI is not on `PATH`, so local ClawHub package publish/pack validation cannot be run from this checkout.

External state recheck:
- npm `dist-tags.latest` is still `0.0.46`; npm has no `0.0.47` version.
- ClawHub package `@inline-openclaw/inline` is still at latest `0.0.46` under owner `inline-openclaw`.
- ClawHub `/versions/0.0.47` returns 404.

Release note:
- The package is release-ready as `0.0.47`; npm and ClawHub publishing remain the only unfinished steps.

## Iteration 45: keep group command authorization separate from DM allowFrom

Status: complete.

Problem:
- Inline's group command path used the DM `allowFrom`/pairing allowlist as a fallback when `groupAllowFrom` was unset.
- That made group `/status`, native plugin commands, and the fast `/stop` path more permissive than the Inline doctor capability advertises (`groupAllowFromFallbackToAllowFrom: false`).
- It also diverged from Telegram's native command ingress behavior, where DM allow entries are intentionally excluded from group command owner access.

Native reference notes:
- Telegram calls `resolveTelegramCommandIngressAuthorization` with `includeDmAllowForGroupCommands: false` in both normal message command handling and abort/stop handling.
- `extensions/telegram/src/ingress.ts` then excludes `effectiveDmAllow` from the command owner list for group commands and uses `effectiveGroupAllow` as `groupAllowFrom`.
- Telegram has a regression that a group sender paired in the DM store is still blocked when they are not in `groupAllowFrom`.

Plan:
- Keep regular group message ingress independent from command ownership: open groups can still process allowed, mentioned/non-mentioned messages according to group policy.
- For group command authorization, use only the resolved group sender allowlist.
- Preserve explicit command authorization escape hatches such as `commands.allowFrom`, per-group `allowFrom`, access groups, and command owner config.
- Cover both normal command handling and the fast `/stop` debounce-cancel path.

Implementation notes:
- `monitor.ts` now sets `effectiveGroupCommandAllowFrom` to `effectiveGroupAllowFrom` in both the normal inbound path and the fast abort authorization path.
- Positive command tests that are meant to exercise text/native/plugin command behavior now authorize through `groupAllowFrom` instead of relying on DM `allowFrom`.
- Added regressions proving DM `allowFrom` alone does not authorize group control commands or group `/stop`.
- Kept the targeted `@bot` command test focused on mention bypass by giving it group authorization; targeted commands bypass mention gating, not sender authorization.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "DM allowFrom|commands.allowFrom|registered Inline slash commands|registered Inline skill commands|registered Inline plugin commands|host command registry|account commands only|plugin command button"` (9 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "does not use DM allowFrom to authorize group stop requests|does not cancel pending debounced text for unauthorized group stop requests"` (2 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts -t "declares platform thread support"`.
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "publishes connected and inbound transport status"`.
- Passed: `cd packages/openclaw && bun run check` after raising the OpenClaw Vitest timeout from 15s to 30s to avoid full-coverage parallel-load false timeouts. This covered typecheck, lint, 407 Vitest tests with coverage, and build.

Tradeoff:
- Group commands in open groups now require a group/command authorization source (`groupAllowFrom`, per-group `allowFrom`, `commands.allowFrom`, access groups, or owner config). Ordinary non-command group ingress still follows the group policy and mention settings.
- The package test timeout increase does not change runtime behavior. It keeps integration-heavy coverage runs from failing when first tests cross 15 seconds under parallel load.

## Release readiness addendum after Iteration 45

Status: prepared, publish blocked locally.

Verification:
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 407 tests.
- Passed: `cd packages/openclaw && bun run build`.
- Installed local test build into `~/.openclaw/npm/projects/inline-openclaw-inline-1f9777b513/node_modules/@inline-openclaw/inline`.
- Backed up the previous local install at `~/.openclaw/plugin-backups/inline-local-test-20260620-010141`.
- Refreshed OpenClaw's plugin registry; `openclaw plugins inspect inline` reports Inline version `0.0.47`.
- Restarted the local OpenClaw LaunchAgent gateway; `openclaw gateway status` reports runtime active on port `18789`, connectivity probe ok, and admin-capable.
- Passed: `openclaw health`; Inline is configured and the gateway event loop is ok.
- Passed follow-up after restart: `openclaw plugins doctor` reported no plugin issues.
- Passed follow-up after restart: `openclaw plugins list` shows Inline enabled from the local npm project source at version `0.0.47`.
- Passed follow-up after restart: `openclaw channels status` shows `Inline default` enabled, configured, running, connected, and using the 0.0.47-loaded gateway.
- Note: `openclaw channels status` also shows a separate `Inline local` account stopped/disconnected with `Internal server error`; the default Inline account is connected, and plugin diagnostics report no plugin load issues.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 18.9 MB unpacked size, 127 files, shasum `ad1b32e820fea9169b9758d81a90cc338e3c797d`.

Publish blockers:
- npm and ClawHub external publish steps still require authenticated tooling. The previous local check showed `npm whoami` was not authenticated, 1Password CLI could not complete the NPM login flow, and `clawhub` was not on `PATH`.

## Local OpenClaw trial recheck

Status: ready for manual trial.

Verification:
- Confirmed the local OpenClaw install at `~/.openclaw/npm/projects/inline-openclaw-inline-1f9777b513/node_modules/@inline-openclaw/inline` is running package version `0.0.47`.
- Passed: `openclaw plugins inspect inline` reports the loaded Inline plugin as version `0.0.47`.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw health`; Inline is configured and the gateway event loop is ok.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; `Inline default` is enabled, configured, running, connected, and `works`.
- Expected local-account failure remains contextual: `Inline local` is stopped with `inline startup getMe failed: ProtocolClientError:rpc-error: Internal server error` against its configured local API.

## Iteration 46: annotate Inline startup failures and clean up pre-handle clients

Status: complete.

Problem:
- Local release validation exposed a secondary `Inline local` account failing with only `Internal server error`.
- The structured snapshot showed this happened after websocket open but before the monitor returned a handle.
- Because startup `getMe` failed before `startAccount` received a monitor handle, the SDK client could remain open in diagnostics while the account was marked stopped.

Native reference notes:
- Telegram status issue collection preserves runtime error context alongside the operation-specific status message, such as polling/webhook setup and transport stale states.
- Inline should provide the same operational context instead of surfacing a raw server string with no failing step.

Plan:
- Annotate monitor startup failures with the operation name.
- Keep SDK error names when available, so `ProtocolClientError:rpc-error` is visible in status.
- Close the Inline SDK client when startup fails before a monitor handle exists.
- Prove the status patch and cleanup with a focused regression.

Implementation notes:
- Added `formatInlineOperationError` based on the existing SDK meta summarizer.
- Wrapped startup `client.connect` and `GET_ME` in an operation-aware try/catch.
- On startup failure, the monitor now pushes `connected:false` plus a contextual `lastError`, closes the SDK client, and rethrows the contextual error.
- Added a regression for a `GET_ME` RPC failure that previously would have appeared as only `Internal server error`.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "startup getMe failures"` (1 selected test).
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 408 tests.
- Reinstalled the rebuilt 0.0.47 package into the local OpenClaw npm install after backing up the previous local test build at `~/.openclaw/plugin-backups/inline-local-test-20260620-010926`.
- Refreshed OpenClaw's plugin registry and restarted the local LaunchAgent gateway.
- Passed: `openclaw gateway status`; gateway active on port `18789`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Verified: `openclaw channels status` now reports the local account failure as `inline startup getMe failed: ProtocolClientError:rpc-error: Internal server error`.
- Verified: structured channel status now shows the failed local account with `diagnostics.started:false`, protocol `state:"connecting"`, transport `state:"idle"`, `pendingRpcCount:0`, and `socketReadyState:null`, proving the failed startup client was closed.
- Passed release audit: `git diff --check` across the release files.
- Verified release diff scope: `bun.lock` only changes the `packages/openclaw` workspace version from `0.0.46` to `0.0.47`; no `dist` files are tracked in the git diff.
- Passed final local probe: `openclaw channels status --channel inline --probe --timeout 15000` reports `Inline default` as running, connected, and `works`.
- Verified final local probe still reports `Inline local` as stopped with the contextual startup `getMe` failure, not the earlier bare `Internal server error`.
- Passed follow-up: `openclaw channels status` shows Telegram connected again after startup and `openclaw plugins doctor` still reports no plugin issues.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 18.9 MB unpacked size, 127 files, shasum `c00c54d10f1850698636b84948e0172969d11271`.
- Passed artifact contents check: tarball includes `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`, and excludes the workspace-only `dist/tsconfig.tsbuildinfo`.
- Passed artifact import check from an extracted tarball under `packages/openclaw/.tmp`: `dist/index.js` imports as the OpenClaw bundled channel entry (`id:"inline"`, `name:"Inline"`, with `loadChannelPlugin`, `loadChannelSecrets`, `setChannelRuntime`, and account inspector hooks), and `dist/channel-plugin-api.js` exports `inlineChannelPlugin` with config/status/gateway/message/action surfaces.
- Verified tarball package metadata matches the local OpenClaw test install: `@inline-openclaw/inline@0.0.47`.
- Verified tarball `openclaw.plugin.json` and `dist/channel-plugin-api.js` byte-for-byte match the local OpenClaw test install.

Tradeoff:
- The raw server error is still present, but it is now prefixed with the failing startup operation and SDK error class. That keeps diagnostics actionable without inventing server-specific interpretations in the plugin.

## Iteration 47: release debounce audit against native Telegram behavior

Status: complete.

Problem:
- Debouncing was implemented, but release confidence still depended on broad tests that did not isolate every config precedence path users are likely to set.
- The existing test covered `messages.inbound.byChannel.inline` only with the same global value also present, and covered account-level positive debounce, but did not prove the global fallback alone or explicit account disable behavior.

Native reference notes:
- Telegram uses the shared OpenClaw inbound debouncer and `shouldDebounceTextInbound`, with control commands excluded from debounce.
- Telegram cancels pending same-chat/same-sender debounce buffers when an authorized stop arrives, while unauthorized group stops do not clear buffered user text.
- Telegram callback queries are handled as discrete actions, not coalesced text bursts.

Implementation notes:
- Kept Inline runtime code unchanged because it already uses `createChannelInboundDebouncer`, `shouldDebounceTextInbound`, and same-key cancellation for authorized stop requests.
- Tightened the existing rapid-text test so `messages.inbound.byChannel.inline` is the setting that proves batching, even when global `messages.inbound.debounceMs` is `0`.
- Added a regression proving global `messages.inbound.debounceMs` batches Inline messages when no Inline channel override is set.
- Added a regression proving Inline account `debounceMs: 0` disables a nonzero global inbound debounce for that account.
- Confirmed Inline message action callbacks intentionally bypass debounce and remain serialized as discrete action dispatches, matching Telegram callback-query behavior.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "debounce"` (8 selected tests).
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 410 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `git diff --check -- packages/openclaw/src/inline/monitor.test.ts`.

Tradeoff:
- This pass added coverage only. No runtime behavior changed, because the code path was already on the shared OpenClaw debouncer and matched the native Telegram semantics checked here.

## Release publish tooling recheck

Status: publish still blocked by local auth/tooling, package remains prepared.

Findings:
- `npm whoami` returns `E401`; this shell is not authenticated to npm.
- `op whoami` reports the 1Password CLI account is not signed in, so the Codex vault NPM credentials cannot be fetched safely from this session.
- `command -v clawhub` returns no binary on `PATH`.
- `openclaw plugins --help` exposes install/search/update/registry commands but no publish command.
- `openclaw plugins search inline` shows public ClawHub still has `@inline-openclaw/inline` at `v0.0.46`.
- `npm view @inline-openclaw/inline version dist-tags --json` shows npm latest is still `0.0.46`.
- OpenClaw's local release scripts confirm ClawHub publish requires the `clawhub` CLI (`clawhub package pack` then `clawhub package publish`) and npm publish expects npm auth or trusted publishing.

Current state:
- Local OpenClaw install is still running the prepared `0.0.47` build for manual trial.
- External npm/ClawHub release is ready in code but cannot be completed from this shell until npm/1Password auth and ClawHub publish tooling are available.

## Iteration 48: clarify pin surface scope

Status: complete.

Problem:
- A follow-up audit started to over-prune Inline pinning after treating all pin operations as low-value client controls.
- The intended boundary is narrower: pinning a specific message by message id is useful; pinning chats/dialogs is not useful for this bot surface.

Native reference notes:
- Slack exposes message-level `pin`, `unpin`, and `list-pins` through its bot-facing message action surface.
- Telegram supports message delivery pinning and message pin/unpin operations, while chat/dialog pinning is a client organization control.

Implementation notes:
- Restored Inline message-level `pin`, `unpin`, and `list-pins` actions and the `actions.pins` gate.
- Kept chat/dialog controls such as `pin-chat`, `unpin-chat`, `pinChat`, and `unpinChat` absent from the action surface.
- Updated the README and manifest help to describe the gate as message pins rather than generic client pinning.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts src/inline/config-schema.test.ts src/manifest.test.ts` (75 tests).
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 410 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `git diff --check` for the touched action/config/manifest/docs files.

Tradeoff:
- The surface now keeps the useful message moderation/workflow operation while still avoiding user-client chat organization controls.

## Iteration 49: local release smoke after pin-scope correction

Status: complete.

Problem:
- The local OpenClaw install had already been tested with `0.0.47`, but the message-pin scope correction changed the runtime bundle, manifest, and README afterward.
- Release confidence needed one more local install pass so the running gateway and packed artifact matched the latest source state.

Implementation notes:
- Rebuilt `packages/openclaw`.
- Backed up the previously installed local test copy to `~/.openclaw/plugin-backups/inline-local-test-20260620-012958`.
- Synced the rebuilt Inline plugin into the local OpenClaw npm install at `~/.openclaw/npm/projects/inline-openclaw-inline-1f9777b513/node_modules/@inline-openclaw/inline`.
- Refreshed OpenClaw's persisted plugin registry.
- Repacked `@inline-openclaw/inline@0.0.47` and then synced the local install from the extracted tarball so the installed `dist`, `README.md`, `openclaw.plugin.json`, and `package.json` match what npm will publish.

Verification:
- Passed: `cd packages/openclaw && bun run build`.
- Passed: source-to-install compare after initial sync for `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`.
- Passed: `openclaw plugins registry --refresh` (`2/93` enabled plugins indexed).
- Passed: `openclaw gateway restart` via LaunchAgent.
- Passed: `openclaw gateway status`; runtime running on port `18789`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; `Inline default` is running, connected, and `works`.
- Verified expected secondary account failure is still contextual: `Inline local` reports `inline startup getMe failed: ProtocolClientError:rpc-error: Internal server error`.
- Verified installed bundle action surface with a dummy in-memory config: `pin`, `unpin`, and `list-pins` are present; `pin-chat`, `unpin-chat`, `pinChat`, and `unpinChat` are absent.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 18.9 MB unpacked size, 127 files, shasum `575e2e719a67d4a47cfd7a56ac142b85d6b4b80e`.
- Passed artifact import check after linking only the OpenClaw peer dependency into the temporary extraction under `/tmp`: loaded channel id `inline`, 51 actions, message pin checks present, chat/dialog pin checks absent.
- Passed artifact-to-install compare for `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`.
- Passed final restart and local probe after artifact-to-install sync: gateway running, plugin doctor clean, `Inline default` works.

Notes:
- `openclaw gateway status` still reports a service PATH recommendation. This is an OpenClaw service configuration warning, not a plugin load or runtime failure.
- `openclaw plugins inspect inline --json` still shows old install provenance fields from the original manual/npm install, but the loaded plugin version and resolved package version are both `0.0.47`, and the installed files match the freshly packed artifact.

## Iteration 50: align message-pin discovery and current-context defaults

Status: complete.

Problem:
- Inline exposed `pin`, `unpin`, and `list-pins`, but discovery did not describe the `messageId`/target fields those actions need.
- The runtime also required `chatId`/`channelId`/`to` for message pin actions even when the OpenClaw message tool was invoked from an Inline chat with `currentChannelId` or `currentThreadTs`.
- This left a common native-channel workflow brittle: "pin this message" from the current conversation could fail with a missing target even though OpenClaw already had the current Inline chat context.

Native reference notes:
- Slack's native OpenClaw message tool contributes a message-id schema for `pin` and `unpin`.
- Slack action dispatch resolves channel context before invoking the runtime pin/unpin/list pins operations, so agents do not need to restate the current channel target for normal in-channel message actions.

Implementation notes:
- Added Inline message-tool schema contributions for `pin`/`unpin` (`messageId` plus target aliases) and `list-pins` (target aliases).
- Added action target aliases for `pin`, `unpin`, and `list-pins`.
- Added current-context fallback for `pin`, `unpin`, and `list-pins`:
  - explicit `threadId` wins
  - explicit `to`/`chatId`/`channelId` wins
  - current reply-thread chat id is used when available
  - current chat id is used otherwise
- Added current-message fallback for `pin`/`unpin` when `messageId` is omitted but `toolContext.currentMessageId` exists.
- Updated the README to document the current chat/thread defaults.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "pin|message-tool buttons schema"` (2 selected tests).
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (54 tests).
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 411 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 19.0 MB unpacked size, 127 files, shasum `b5cdfeb1b9f21ecdab78b0ca3a58ce31b7f52ba4`.
- Backed up the previous local install to `~/.openclaw/plugin-backups/inline-local-test-20260620-014205`.
- Synced the local OpenClaw install from the extracted tarball using checksum mode because npm-pack source maps use normalized timestamps.
- Passed artifact-to-install compare for `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`.
- Passed artifact import check after linking only the OpenClaw peer dependency into the temporary extraction under `/tmp`: loaded channel id `inline`, 51 actions, message pin checks present, chat/dialog pin checks absent, `pin.messageId` schema present, and `list-pins.threadId` schema present.
- Passed: `openclaw gateway restart` via LaunchAgent.
- Passed: `openclaw gateway status`; runtime running on port `18789`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; both `Inline default` and `Inline local` are running, connected, and `works`.

Tradeoff:
- The fallback is limited to message-pin actions. Other write actions keep their existing target rules unless they already had current-chat fallback, keeping this change narrowly aligned with native message-action behavior.

## Iteration 51: align reaction discovery and current-context defaults

Status: complete.

Problem:
- Inline `react` could fall back to `toolContext.currentMessageId`, but still required an explicit `to`/`chatId`/`channelId`.
- Inline `reactions` required both an explicit target and explicit `messageId`.
- This made native-style current-message actions brittle: "react to this" or "show reactions on this" could fail even though OpenClaw already passes the current Inline chat/thread/message context.

Native reference notes:
- OpenClaw runtime context explicitly carries `currentChannelId`, `currentThreadTs`, and `currentMessageId` for action fallbacks; the native comment cites Telegram reactions as a message-id fallback use case.
- Slack's native message-tool API groups `react`, `reactions`, `edit`, `delete`, `pin`, and `unpin` as message-id actions.
- Slack action dispatch resolves the current channel before invoking `react`, `reactions`, `pin`, `unpin`, and `list-pins`, so these actions work as bot message actions instead of user-client chat controls.
- Telegram's local message-tool schema for extra fields stays narrow; the native behavior to mirror here is the shared runtime context and message-level operation scope, not chat/dialog pinning.

Implementation notes:
- Added Inline message-tool schema contributions for `react`/`reactions`, including target aliases, `threadId`, and `messageId`.
- Added action target aliases for `react` and `reactions`.
- Updated `react` to resolve the current Inline target with the same explicit-target, current-thread, then current-chat precedence used by other current-context message actions.
- Updated `reactions` to use current chat/thread context and current inbound message id when explicit fields are omitted.
- Kept chat/dialog pinning and follow-thread controls absent. Message-id pinning remains present and verified.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "react|reactions|message-tool buttons schema"` (9 selected tests).
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (55 tests).
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 412 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 19.0 MB unpacked size, 127 files, npm shasum `8692e118d5d57e9460cc4866d8216e2c7e3a573a`, sha256 `be5e19208ec3733e5a782d393fdad25a40da37a4c80a920fba5b9adfddd05a4b`.
- Backed up the previous local install to `~/.openclaw/plugin-backups/inline-local-test-20260620-015107`.
- Synced the local OpenClaw install from the extracted tarball using checksum mode.
- Passed artifact-to-install compare for `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`.
- Passed artifact import check from `/tmp/inline-openclaw-pack-20260620-015107`: 51 actions, `react`/`reactions` present, message `pin`/`unpin`/`list-pins` present, chat/dialog pin actions absent, follow-thread absent, and the `react.messageId`, `reactions.threadId`, `pin.messageId`, and `list-pins.threadId` schemas present.
- Passed: `openclaw gateway restart` via LaunchAgent.
- Passed: `openclaw gateway status`; runtime running on port `18789` with pid `15734`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; both `Inline default` and `Inline local` are running, connected, and `works`.

Tradeoff:
- The change stays scoped to message-level reaction operations. It does not add client-style chat/dialog controls such as chat pinning, follow/unfollow, or notification settings.
- `openclaw gateway status` still reports the existing service PATH recommendation; plugin doctor and channel probes are clean, so this remains a local service config warning rather than a release blocker for the plugin.

## Iteration 52: add native-style download-file support

Status: complete.

Problem:
- OpenClaw's canonical message action names include `download-file`, and Slack exposes it as a read-side bot action.
- Inline read/search/get-messages already returned media URLs and URL-preview image URLs, but the Inline plugin did not expose a native-style way for the agent to download those files into a local tool-result path.
- This was a useful bot-surface gap, unlike client-only controls such as chat pinning, follow/unfollow, or notification settings.

Native reference notes:
- OpenClaw core lists `download-file` in `CHANNEL_MESSAGE_ACTION_NAMES`.
- Slack contributes a `download-file` schema, dispatches it to an internal `downloadFile` action, returns `{ ok: false }` for inaccessible files, and returns structured file metadata/media details for non-image downloads.
- Inline has no Slack-style file id, so the equivalent selector surface is direct `mediaUrl`/`url` or an Inline message plus `mediaId`/`attachmentId` from `read`, `search`, or `get-messages`.

Implementation notes:
- Added `download-file` under the existing `read` action gate.
- Added message-tool discovery schema and aliases for direct URL downloads and message/media/attachment selectors.
- Added `downloadInlineMediaFromUrl`, sharing the upload helper's media size limits, local-root/read-file options, MIME detection, and redacted error context.
- `download-file` now supports:
  - direct `mediaUrl`/`fileUrl`/`url`/`media`/`filePath`/`path` downloads without opening an Inline SDK connection
  - current chat/thread and current message fallback when resolving a source message
  - message media downloads by default
  - URL-preview image attachment downloads via optional `attachmentId`
  - soft `{ ok: false }` failures for missing messages or messages with no matching downloadable media
- Returned results include `path`, `sourceUrl`, `contentType`, and `details.media.mediaUrl/mediaUrls` with `trustedLocalMedia: true`.
- Kept chat/dialog pinning, follow/unfollow, and notification controls absent.

Verification:
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "download-file|message-tool buttons schema|lists gated actions"` (2 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "downloads"` (2 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (57 tests).
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 414 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 19.0 MB unpacked size, 127 files, npm shasum `f43b678134c8f55ec6784abf0e3f5fd70740fc88`, sha256 `db6c18634488070e5e1223f6119ae1feb2faf2601350dfeb16882b9298440057`.
- Backed up the previous local install to `~/.openclaw/plugin-backups/inline-local-test-20260620-020621`.
- Synced the local OpenClaw install from `/tmp/inline-openclaw-pack-20260620-download-file-xcxKe5/package` using checksum mode.
- Passed artifact-to-install compare with an empty checksum dry run.
- Passed packed-build import check from `/tmp/inline-openclaw-pack-20260620-download-file-xcxKe5`: channel id `inline`, 52 actions, `download-file` present, `upload-file` present, message `pin` present, chat/dialog pin actions absent, follow-thread absent, and `download-file` schema/aliases present.
- Passed: `openclaw gateway restart` via LaunchAgent; previous pid `15734`, new pid `29498`.
- Passed: `openclaw gateway status`; runtime running on port `18789`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; both `Inline default` and `Inline local` are running, connected, and `works`.

Tradeoff:
- The action downloads Inline media and URL-preview images, not arbitrary text links embedded in message bodies. Direct `mediaUrl`/`url` remains available when the agent explicitly wants a specific URL.
- Download output is written under the OS temp directory (`openclaw-inline-downloads`) instead of the workspace to avoid surprising user-file writes. The returned absolute path is still available to the agent/runtime.
- The local gateway still reports the existing service PATH recommendation; plugin doctor and channel probes are clean, so this remains a local service configuration warning rather than a plugin release blocker.

## Iteration 53: finalize debounce release hardening

Status: complete.

Scope note:
- Release-cut scope was narrowed here. No new tool/API surface was added beyond the debounce tests already in progress.
- Message ID pinning remains in scope. Chat/dialog pinning, follow/unfollow, and notification settings remain intentionally out of scope for this bot surface.

Problem:
- Inline debounce behavior had runtime support and stop-path coverage, but the release lacked explicit tests for the native Telegram-style debounce boundaries: same sender and same conversation may batch, different senders/chats must not, and interactive callbacks/control paths must not wait behind pending text debounce.

Native reference notes:
- OpenClaw's shared `createChannelInboundDebouncer` resolves `messages.inbound.debounceMs`, `messages.inbound.byChannel.<id>`, and optional per-account override in that order.
- Telegram builds debounce keys from account, conversation key, sender, and debounce lane. For Inline, reply threads are represented as child chats, so the existing account/chat/sender Inline key already gives the equivalent conversation boundary.
- Telegram cancels pending debounce buffers for authorized abort control messages and keeps callback/button handling out of the text debounce lane. Inline already follows that runtime shape.

Implementation notes:
- Added regression coverage to `packages/openclaw/src/inline/monitor.test.ts` for:
  - different senders in the same chat staying in separate debounce turns
  - the same sender in different chats staying in separate debounce turns
  - message action callbacks dispatching before pending debounced text flushes
- No runtime code change was needed; the audit found the existing Inline debounce implementation matches the native behavior after accounting for Inline's child-chat reply-thread model.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts -t "debounce|callbacks before pending debounced"` (11 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (148 tests).
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 417 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Artifact details: 2.4 MB package size, 19.0 MB unpacked size, 127 files, npm shasum `f43b678134c8f55ec6784abf0e3f5fd70740fc88`, sha256 `db6c18634488070e5e1223f6119ae1feb2faf2601350dfeb16882b9298440057`.
- Backed up the previous local install to `~/.openclaw/plugin-backups/inline-local-test-20260620-021646/inline`.
- Synced the packed artifact into the local OpenClaw install at `~/.openclaw/npm/projects/inline-openclaw-inline-1f9777b513/node_modules/@inline-openclaw/inline`.
- Passed artifact-to-install checksum dry-runs for `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`.
- Passed packed-build import check from `/tmp/inline-openclaw-pack-20260620-final-tT9LSj`: channel id `inline`, 52 actions, `download-file` present, `upload-file` present, message `pin` present, chat/dialog pin actions absent, follow-thread absent, `download-file` schema present, and `pin.messageId` schema present.
- Passed: `openclaw gateway restart`; previous pid `29498`, new pid `38607`.
- Passed: `openclaw gateway status`; runtime running on port `18789`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; both `Inline default` and `Inline local` are running, connected, and `works`.

Tradeoff:
- This pass intentionally stopped at release hardening. Further native-surface parity work should wait until after this clean release cut.
- The gateway still reports the existing LaunchAgent PATH recommendation; plugin doctor and channel probes are clean, so this remains a local service configuration warning rather than a plugin release blocker.

## Iteration 54: fix thread-create placeholder parent regression

Status: complete.

Problem:
- A DM request like "create a new thread and tell me cool" became slow and failed before creation.
- Local OpenClaw logs showed the message tool call was over-filled with optional placeholder ids such as `spaceId: "x"`, plus current-message parent aliases like `messageId`/`replyTo`/`parentMessageId`.
- Inline treated `"x"` as a real `spaceId` and threw `inline action: invalid spaceId "x"`.
- The same over-filled parent aliases could also push `thread-create` toward reply-thread/subthread semantics even when the user asked for a new top-level private thread with participants.
- Logs also showed a separate local model configuration fallback: `openai-codex/gpt-5.3-codex` was selected but not registered, so OpenClaw fell back to `gpt-5.5`. That added latency independently from the plugin bug.

Implementation notes:
- Added reusable optional-id normalization for placeholder values: `x`, `n/a`, `na`, `none`, `null`, `undefined`, `unknown`, and `-`.
- Applied that normalization to optional thread parent ids and `thread-create` `spaceId`/`space`.
- Filtered placeholder participant refs before user resolution.
- Refined `thread-create` routing so participant/private or public/space creation stays top-level even when the model over-fills current message aliases.
- Preserved intentional reply-thread creation when there is a real parent anchor, including the existing `spaceId + parentMessageId` subthread path.
- Switched local OpenClaw defaults from `openai-codex/gpt-5.3-codex` to `openai-codex/gpt-5.5` and removed the manual `gpt-5.3-codex` provider-model registration. This removes the fallback delay without inventing a local provider model.

Verification:
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts -t "thread-create|message-tool buttons schema"` (7 selected tests).
- Passed: `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts` (58 tests).
- Passed: `cd packages/openclaw && bun run typecheck`.
- Passed: `cd packages/openclaw && bun run check` with 26 test files and 418 tests. This covered typecheck, lint, coverage tests, and build.
- Passed: `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`.
- Packed artifact: `/tmp/inline-openclaw-inline-0.0.47.tgz`.
- Backed up the previous local install to `~/.openclaw/plugin-backups/inline-local-test-20260620-024114/inline`.
- Synced the packed artifact into the local OpenClaw install at `~/.openclaw/npm/projects/inline-openclaw-inline-1f9777b513/node_modules/@inline-openclaw/inline`.
- Passed artifact-to-install checksum dry-runs for `dist`, `README.md`, `openclaw.plugin.json`, and `package.json`.
- Passed packed-build import check from `/tmp/inline-openclaw-pack-20260620-thread-create-4lzjFG`: 52 actions and `thread-create` schema/aliases present.
- Passed: `openclaw gateway restart`; previous pid `43075`, new pid `55689`.
- Passed: `openclaw gateway status`; runtime running on port `18789`, connectivity probe ok, admin-capable.
- Passed: `openclaw plugins doctor`; no plugin issues detected.
- Passed: `openclaw channels status --channel inline --probe --timeout 15000`; both `Inline default` and `Inline local` are running, connected, and `works`.
- Re-ran the channel probe after the immediate post-restart CPU warning; the second probe was clean.
- Correction: removed the manual `gpt-5.3-codex` provider-model registration and switched the local default to `openai-codex/gpt-5.5`.
- Passed dry-runs for:
  - `openclaw config set agents.defaults.model '{"primary":"openai-codex/gpt-5.5","fallbacks":["openai/gpt-5.5"]}' --strict-json --dry-run`
  - `openclaw config set agents.defaults.models '{"openai-codex/gpt-5.5":{},"openai/gpt-5.5":{}}' --strict-json --replace --dry-run`
  - `openclaw config set models.providers.openai-codex.models '[]' --strict-json --replace --dry-run`
- Applied those local config updates and restarted the gateway; new pid `61200`.
- Confirmed targeted config values: primary model is `openai-codex/gpt-5.5`, `agents.defaults.models` has no `gpt-5.3-codex`, and `models.providers.openai-codex.models` is empty.
- Passed after the final restart: `openclaw gateway status`, `openclaw plugins doctor`, and `openclaw channels status --channel inline --probe --timeout 15000`.
- Latest startup log shows `agent model: openai-codex/gpt-5.5` without a `model_not_found` fallback warning.

Tradeoff:
- This only hardens optional-id/parent-intent interpretation for the observed `thread-create` regression. The model switch is intentionally local OpenClaw configuration, not a plugin code change.
- The gateway still reports the existing LaunchAgent PATH recommendation in `openclaw gateway status`; plugin doctor and channel probes are clean, so this remains a local service configuration warning rather than a plugin release blocker.
