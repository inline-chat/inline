# Inline OpenClaw Progress Placeholder

Date: 2026-06-01

## Goal

Implement a separate temporary progress indicator for the Inline OpenClaw plugin while the LLM is working/thinking/calling tools.

Active goal as of 2026-06-01:

Design and document robust Inline OpenClaw reply-thread handling by comparing native Telegram/Discord/Slack plugin patterns, then implement only after user approval.

Refined active goal:

Make Inline OpenClaw reply threads stable for long AI conversations while keeping small/new conversations in the parent chat, avoiding one reply thread per message, and clarifying tool availability, markdown instructions, session handling, config semantics, fallback behavior, and cache strategy based on native OpenClaw Telegram/Discord/Slack patterns.

Required behavior:

- Send a separate progress placeholder message with `sendMode: "silent"`.
- Continuously edit that same placeholder as progress events arrive.
- Delete the placeholder when the final answer is ready, before or around final delivery.
- Keep this independent from answer streaming/edit previews.

## User Correction

Important correction from Mo:

> Do not confuse the progress "working..." temporary message with streaming messages.

This task is not about turning `streaming.mode=progress` into answer streaming. It needs a separate progress placeholder lifecycle. If Inline already had answer edit streaming, that is not the feature being requested.

## Initial Prompt

Mo's starting request for this work:

> now even discord has progress updates in the openclaw plugin. first telegram now this. https://github.com/openclaw/openclaw/releases/tag/v2026.5.28
> we are desperately lacking good progress indicator while the llm is working/thinking/agent calling, before generating full answer.
> we should use a silent: true message with editing it continuously until final message is ready and deleting it when that is ready.
> set a goal, read native source codes from ~/dev/openclaw/ for telegram and discord, and get to work making it happen in our inline plugin.

Follow-up constraints from Mo:

- The progress "working..." temporary message is separate from streaming answer messages.
- Keep context, findings, learnings, logs of work, and todos in this markdown file.
- For reply-thread robustness, do not code until the design/gaps are reviewed.
- Reply-thread tools should stay available. Config should guide automatic routing, not hide capabilities the claw can use when asked.
- `replyThreadMode` should mean "route all replies in a parent chat to a reply thread" only when the user explicitly requests that behavior.
- Reply threads are enabled for all Inline bots.

## Current Reply-Thread Question

Mo's latest design asks:

1. Keep reply-thread tools always available and treat config as user guidance. The claw can decide to reply in a thread if asked. `replyThreadMode` should only mean that all replies in a parent chat are routed to a reply thread.
2. Add fallback if Telegram/Discord/Slack have an equivalent pattern.
3. Check native OpenClaw plugin patterns and choose the best route.
4. Do not over-optimize for two events trying to create the same thread if that scenario is not real.
5. If native plugins cache thread mappings/context, Inline should use a comparable cache.
6. Keep session routing metadata consistent.
7. Assume reply-thread capability is enabled for all Inline bots.

Initial design stance:

- Yes, the `replyThreadMode` split makes sense. Tool availability and automatic routing should be separate concepts.
- Inline should not gate `thread-create` or `thread-reply` discovery on `replyThreadMode`; those tools represent available API behavior.
- `replyThreadMode="thread"` should be the opt-in mode for automatic parent-chat reply routing into reply threads.
- The plugin should still handle API errors or missing metadata defensively, even though reply threads are enabled for all bots.

Desired outcome for long conversations:

- Small or newly-started parent-chat conversations should stay in the parent chat by default.
- Long AI conversations should have a stable way to move into one reply thread, not create a new reply thread for every message.
- Once a parent message/conversation is associated with a reply thread, future replies should reuse that thread.
- Tools should make the model's options clear: continue in parent, create/reuse a reply thread, or reply into a known thread.
- Config should express user routing preference, not platform capability.

## Native Reply-Thread Patterns

Slack:

- `extensions/slack/src/monitor/thread-resolution.ts` uses a short TTL cache plus an `inflight` map to resolve missing `thread_ts` once per channel/message. If Slack cannot resolve it, the message is marked ambiguous rather than crashing dispatch.
- `extensions/slack/src/monitor/thread.ts` caches thread starter context with TTL/LRU behavior.
- `extensions/slack/src/sent-thread-cache.ts` stores bot thread participation in a shared global dedupe cache and, when available, OpenClaw persistent keyed state. Persistent failures are best-effort and never break message handling.

Discord:

- `extensions/discord/src/monitor/threading.auto-thread.ts` tries to create an auto-thread, and if creation fails it refetches the source message to reuse an existing thread. If neither works, it returns `undefined` and the delivery plan falls back to the original channel target.
- `extensions/discord/src/monitor/monitor.threading-utils.test.ts` explicitly covers "race condition returns existing thread" and "other error returns undefined" for auto-thread creation failures.
- `extensions/discord/src/monitor/threading.cache.ts` caches thread starter context with TTL/LRU.
- `extensions/discord/src/monitor/thread-bindings.manager.ts` keeps durable session/thread bindings, touches activity, sweeps expired/stale bindings, and only removes stale entries for known gone/deleted/permission errors. Transient probe failures keep bindings.
- `extensions/discord/src/monitor/thread-bindings.discord-api.ts` has best-effort fallback sends and logs failures instead of making binding cleanup fatal.

Telegram:

- `extensions/telegram/src/thread-bindings.ts` persists conversation-to-session bindings on disk, registers a session binding adapter, supports current/child placements, touches activity, and sweeps idle/max-age expired entries.
- `extensions/telegram/src/message-cache.ts` persists message/reply context and keeps thread ids on cached nodes.
- `extensions/telegram/src/topic-name-cache.ts` uses global shared state plus optional persisted topic-name cache with max-entry eviction.
- `extensions/telegram/src/bot/helpers.ts` carefully distinguishes real forum topics from incidental non-forum `message_thread_id` values; this is the same class of "thread metadata must mean a real conversation route" problem Inline has.
- `extensions/telegram/src/bot-message.test.ts` verifies fallback error messages are sent into the current topic when possible and that fallback delivery failures are swallowed after the original dispatch error is logged.

## Current Inline Reply-Thread State

Current strong points:

- `packages/openclaw/src/inline/monitor.ts` already keeps small ordinary parent chats in-place using `DEFAULT_REPLY_THREAD_AUTO_CREATE_MIN_MESSAGES = 50`.
- `replyThreadMode="thread"` plus `replyThreadAutoCreateMinMessages` can auto-create one child thread for a sufficiently high parent message id.
- Inbound child-thread messages get `SessionKey: ...:thread:<childChatId>`, `ParentSessionKey`, `MessageThreadId`, `ThreadLabel`, and parent-chat context.
- `packages/openclaw/src/inline/thread-participation.ts` already mirrors Slack-style participation persistence: global dedupe plus OpenClaw keyed state or a file-backed persistent dedupe fallback.
- `inline_parent_context` can load parent-chat context from a current reply-thread session.

Current gaps:

- Tool availability and docs still treat `capabilities.replyThreads`/reply-thread config as a feature gate. This conflicts with the desired "Inline bots all support reply threads" model.
- `thread-create` falls back to normal chat creation when reply threads are considered disabled. That is now the wrong behavior; it should consistently mean "create/reuse an Inline reply thread".
- `thread-reply` has legacy fallback behavior when reply threads are considered disabled. That is now the wrong behavior; it should consistently target a reply-thread chat id.
- Message-tool hints currently say reply threads can be disabled and describe legacy fallback semantics. That should be replaced with routing-policy language.
- Auto-create failure currently aborts dispatch: `monitor.test.ts` has a test named `does not fall back to the parent chat when configured thread creation fails`, and `monitor.ts` returns before dispatch if createSubthread fails. This is more brittle than Discord/Telegram patterns.
- Auto-create currently creates a thread anchored to the inbound message that triggered threshold crossing. That avoids one thread per message after the user is inside the child thread, but it does not reuse a previously created child thread for later parent-chat messages unless those later messages occur inside the child thread or the model/tool explicitly knows the child id.
- There is no parent-chat -> active reply-thread route cache. Participation cache is keyed by `(accountId, parentChatId, threadId)` and answers "did we participate in this thread", but not "which thread should this parent chat reuse".
- Inline does not have a session binding adapter equivalent to Discord/Telegram child conversation bindings. It has static configured binding normalization, but no durable bind/touch/unbind manager for auto-created reply-thread sessions.

## Proposed Inline Reply-Thread Design

Config semantics:

- Treat Inline reply threads as available by default for all bot accounts.
- Keep `capabilities.replyThreads` as a backwards-compatible override only if needed during migration, but stop using it to hide tools or switch `thread-create` into normal chat creation.
- `replyThreadMode` should only control automatic delivery placement for parent-chat inbound replies:
  - `auto`: default. Stay in parent chat unless the user/model explicitly uses thread tools or a known long-conversation policy decides to move.
  - `main`: force automatic parent-chat replies to remain in the parent chat, while still allowing explicit thread tools.
  - `thread`: opt into automatic parent-chat replies moving to/reusing a reply thread after the threshold/policy says the chat is long enough.
- Keep `replyThreadAutoCreateMinMessages` as the "do not create reply threads for small/new conversations" threshold. The current default of `50` is aligned with the desired behavior.
- Keep `replyThreadRequireExplicitMention` as reply-thread inbound gating only: after the bot participates in a thread, replies in that child thread may continue without `@bot` unless this is true.
- Keep `replyThreadParentHistoryLimit` as context hydration policy only.

Tool and prompt semantics:

- Always advertise `thread-create`, `thread-reply`, and `inline_parent_context` when the relevant action group is enabled.
- `thread-create` should mean "create or reuse a real Inline reply thread under a parent chat/message". It should never silently create a normal chat.
- `thread-reply` should mean "send into a real Inline reply-thread chat id". If no `threadId` is available, fail with a clear tool error that says to call `thread-create` first or use parent-chat `reply`.
- Prompt hints should tell the model:
  - Use normal reply for short/new conversations.
  - Use `thread-create` when the user asks for a thread or a long parent-chat conversation should be moved out of the parent.
  - Reuse an existing returned `threadId` instead of creating a new thread for every message.
  - Use `inline_parent_context` inside a reply-thread when parent context is missing.

Fallback behavior:

- For automatic `replyThreadMode="thread"` creation, if `createSubthread` fails:
  - Try to resolve/reuse an existing child thread for the same parent message or active parent conversation from cache/state.
  - If reuse fails, fall back to dispatch/deliver in the parent chat, with parent-chat session metadata, and log/statusSink the create failure.
  - Do not drop the user's reply solely because thread creation failed.
- For explicit `thread-create` tool calls, failure should remain visible as a tool error unless a reusable existing thread is found. Explicit tool failures are actionable for the model; automatic delivery failures should preserve a user-visible answer.

Cache/state strategy:

- Add a small reply-thread route cache, separate from participation:
  - key candidates: `(accountId, parentChatId, parentMessageId)` and optionally `(accountId, parentChatId, agentId)` for the current active long-conversation thread.
  - value: `childChatId`, `parentChatId`, `parentMessageId`, `title/threadLabel`, `updatedAt`, optional `agentId`.
  - memory: TTL/LRU with an `inflight` map for create/lookup single-flight, following Slack.
  - persistence: use OpenClaw `runtime.state.openKeyedStore` when available, with a file-backed fallback like Inline participation already uses.
- Record mappings when:
  - auto-create succeeds;
  - `thread-create` succeeds;
  - inbound child-thread metadata is loaded successfully;
  - a sent bot message confirms participation in a child thread.
- Read mappings when:
  - deciding whether parent-chat auto-routing should reuse an existing child thread;
  - `createSubthread` fails;
  - metadata fetch for a child thread fails but a recent cache entry can recover parent/session context.
- Keep persistent errors best-effort and non-fatal, matching Slack/Discord/Telegram.

Session handling:

- Keep child-thread sessions as `agent:<agent>:inline:group:<parentChatId>:thread:<childChatId>`.
- Always include `ParentSessionKey`, `MessageThreadId`, and `ThreadLabel` for child-thread turns/delivery.
- For automatic fallback to parent after create failure, use the parent session key and do not include `MessageThreadId`.
- Consider adding an Inline session binding adapter only if OpenClaw's generic conversation binding commands need durable dynamic child bindings. The immediate stability need can be met by a reply-thread route cache plus existing static binding normalization.

Implementation order when approved:

1. Untangle capability from routing: reply-thread helpers default to enabled, tools always expose real thread semantics, docs/hints stop saying disabled/legacy fallback.
2. Change auto-create failure from abort to parent-chat fallback, with tests replacing the current no-fallback assertion.
3. Add reply-thread route cache/state and reuse it before creating a new thread.
4. Record cache mappings from successful create, inbound metadata, and participation.
5. Add tests for long-chat reuse, small-chat no-thread behavior, explicit tool semantics, create-failure fallback, and cache-backed metadata recovery.

## Implementation Update: Reply-Thread Stability

Files changed:

- `packages/openclaw/src/inline/reply-threads.ts`
- `packages/openclaw/src/inline/thread-routes.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/actions.ts`
- `packages/openclaw/src/inline/channel.ts`
- Inline tests for reply threads, actions, channel hints/routing, and monitor routing
- `packages/openclaw/README.md`
- `packages/openclaw/openclaw.plugin.json`

What changed:

- Inline reply threads are now treated as available for bot accounts by default. The legacy `capabilities.replyThreads` field remains accepted in config but no longer acts as the tool/routing gate.
- `thread-create` now consistently means `createSubthread`; it no longer falls back to normal chat creation.
- `thread-reply` now consistently requires `threadId` and sends into that child reply-thread chat; it no longer falls back to legacy parent reply behavior.
- Message-tool hints now tell the model to keep short/new conversations in normal `reply`, create a thread for explicit/long work, reuse the returned `threadId`, and avoid one thread per message.
- Added `thread-routes.ts`, a reply-thread route cache:
  - 7-day memory TTL with max-size pruning.
  - OpenClaw `runtime.state.openKeyedStore` persistence when available.
  - JSON file fallback under the Inline state dir.
  - Keys for exact parent message and active parent-chat/agent route.
- The monitor records route mappings when:
  - inbound reply-thread metadata is loaded;
  - auto-create succeeds;
  - the bot successfully delivers into a child reply-thread chat.
- Automatic `replyThreadMode="thread"` delivery now checks the route cache before creating a new thread.
- If automatic `createSubthread` fails, Inline checks the route cache again for race/reuse recovery and then falls back to delivering in the parent chat instead of dropping the response.
- Parent-chat fallback uses the parent session and does not include `MessageThreadId`/`ParentSessionKey`.

Verification:

- `cd packages/openclaw && bun run typecheck` passed.
- `cd packages/openclaw && bun run lint` passed.
- Focused test run passed: `bun vitest run --coverage.enabled=false src/inline/reply-threads.test.ts src/inline/actions.test.ts src/inline/channel.test.ts src/inline/monitor.test.ts src/inline/thread-participation.test.ts`
  - 5 files, 219 tests.
- Full package test run passed: `cd packages/openclaw && bun vitest run --coverage.enabled=false`
  - 22 files, 322 tests.
- Post-manifest wording check passed: `cd packages/openclaw && bun vitest run --coverage.enabled=false src/manifest.test.ts`

## Local References Read

Inline plugin files inspected:

- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `packages/openclaw/src/inline/config-schema.ts`
- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/package.json`
- `packages/sdk/src/sdk/types.ts`
- `packages/sdk/src/sdk/inline-sdk-client.ts`
- `proto/core.proto`

OpenClaw native reference files inspected:

- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-message-dispatch.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/draft-stream.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/preview-streaming.ts`
- `/Users/mo/dev/openclaw/extensions/discord/src/monitor/message-handler.draft-preview.ts`
- `/Users/mo/dev/openclaw/extensions/discord/src/monitor/message-handler.process.ts`
- `/Users/mo/dev/openclaw/extensions/discord/src/preview-streaming.ts`
- `/Users/mo/dev/openclaw/src/plugin-sdk/channel-streaming.ts`

Web reference checked:

- `https://github.com/openclaw/openclaw/releases/tag/v2026.5.28`

## Findings

Inline already has:

- `InlineSdkClient.sendMessage({ sendMode: "silent" })`.
- `Method.EDIT_MESSAGE` support via `client.invokeRaw(...)`.
- `Method.DELETE_MESSAGES` support through the protocol/action path.
- Existing progress-related config schema fields: `streaming.mode`, `streaming.preview.toolProgress`, `streaming.progress.*`.
- Existing tests around edit-message streaming.

Inline currently does not appear to have:

- A separate temporary silent progress placeholder lifecycle in `monitor.ts`.
- Progress callbacks wired for `onItemEvent`, `onPlanUpdate`, `onApprovalEvent`, `onCommandOutput`, or `onPatchSummary` in the Inline reply options.
- Cleanup that deletes a temporary progress message before the final answer.

Existing Inline behavior seen in `monitor.ts`:

- `streaming.mode="progress"` currently participates in `streamViaEditMessage`:
  - partial answer text can be sent and edited;
  - `onToolStart` resets the edit-stream boundary;
  - tool progress is not posted as its own placeholder.
- Tests explicitly say `streaming.mode=progress` maps to Inline edit previews without exposing tool lanes. That test wording should not define the new feature.

Telegram/Discord reference behavior:

- They use OpenClaw SDK helpers from `openclaw/plugin-sdk/channel-streaming`:
  - `createChannelProgressDraftGate`
  - `buildChannelProgressDraftLine`
  - `buildChannelProgressDraftLineForEntry`
  - `formatChannelProgressDraftText`
  - `mergeChannelProgressDraftLine`
  - `resolveChannelProgressDraftMaxLines`
  - `resolveChannelStreamingPreviewToolProgress`
  - `resolveChannelStreamingSuppressDefaultToolProgressMessages`
  - `isChannelProgressDraftWorkToolName`
- The gate delays the placeholder until meaningful work:
  - first work event schedules a delayed start;
  - second work event starts immediately;
  - some patch events start immediately.
- Discord defaults unset preview streaming to progress mode.
- Telegram defaults preview streaming to partial mode.

## Implementation Direction

Do not modify answer streaming semantics as the primary mechanism.

Add an Inline-specific temporary progress controller in `monitor.ts`, likely near the existing edit-stream state because it shares `sendMessage`, `editMessage`, delete cleanup, `deliveryChatId`, `parseMarkdown`, and `buildChatPeer`.

Controller responsibilities:

- `sendProgressPlaceholder(text)`:
  - `client.sendMessage({ chatId: deliveryChatId, text, sendMode: "silent" })`
  - save `messageId`
  - remember sent bot message with `rememberSentBotMessage`
- `editProgressPlaceholder(text)`:
  - `client.invokeRaw(Method.EDIT_MESSAGE, { oneofKind: "editMessage", editMessage: { messageId, peerId: buildChatPeer(deliveryChatId), text } })`
- `deleteProgressPlaceholder()`:
  - `client.invokeRaw(Method.DELETE_MESSAGES, { oneofKind: "deleteMessages", deleteMessages: { peerId: buildChatPeer(deliveryChatId), messageIds: [messageId] } })`
  - do not fail final delivery if cleanup fails; log with `runtime.error`.
- Sequence all send/edit/delete operations with an op chain to avoid races.
- Avoid showing final answer in the progress placeholder.
- Delete before final delivery when possible; otherwise cleanup in `finally`.

Progress event wiring to add in `replyOptions`:

- `onReasoningStream`: note work so a generic progress placeholder can appear without exposing raw reasoning text.
- `onToolStart`: build a channel progress line and start or update placeholder.
- `onItemEvent`: update placeholder with item/tool progress.
- `onPlanUpdate`: update for `phase === "update"`.
- `onApprovalEvent`: update for `phase === "requested"`.
- `onCommandOutput`: update for `phase === "end"`.
- `onPatchSummary`: update for `phase === "end"`.
- `onCompactionStart` / `onCompactionEnd`: can set compacting/thinking progress lines if useful; do not conflate with answer streaming.

Use OpenClaw SDK progress helpers if available in the plugin bundle:

- Import from `openclaw/plugin-sdk/channel-streaming`.
- `openclaw` dev dependency is `2026.5.28`, so these helpers exist.

Default chosen:

- Enable the separate placeholder for `streaming.mode === "progress"` and for configs that provide a `streaming.progress` object.
- Also enable it by default when streaming config is unset and legacy `streamViaEditMessage` is not true, matching the newer Discord-style progress default. Text-only turns still do not create a placeholder because the gate only starts on work/progress callbacks.
- Keep legacy answer edit-streaming behind `streaming.mode === "partial"` or `streamViaEditMessage: true`; progress mode is no longer treated as answer edit-streaming.

## Test Coverage Implemented

Added/adjusted focused tests in `packages/openclaw/src/inline/monitor.test.ts`:

- `streaming.mode=progress` sends a silent progress placeholder on tool/progress activity:
  - assert `sendMessage` called with `sendMode: "silent"` and progress label text.
- Edits the same placeholder as more progress events arrive:
  - assert `Method.EDIT_MESSAGE` with placeholder `messageId`.
- Deletes placeholder before visible final reply:
  - assert `Method.DELETE_MESSAGES` occurs before final non-silent `sendMessage`.
- Does not start a placeholder for text-only turns with no work/progress events.
- Does not deliver tool progress as a normal visible final answer.
- Existing cleanup path logs and continues to final answer; a dedicated cleanup-failure test remains optional.

Harness changes made:

- Extended `setupMonitorHarness` to simulate item progress events.
- Add `DELETE_MESSAGES: 4` to mocked `Method`.
- Make mocked `invokeRaw` return `{ oneofKind: "deleteMessages", deleteMessages: { updates: [] } }` for method `4`.
- Make `sendMessage` return distinct `messageId`s per call so tests can distinguish placeholder from final message.

## Work Log

- Created active goal for implementing Inline OpenClaw progress placeholder.
- Checked repo state; worktree already had many unrelated modified/untracked files. Stay scoped to `packages/openclaw`.
- Searched local `~/dev/openclaw` references for Telegram and Discord progress handling.
- Found Telegram/Discord progress-draft architecture and OpenClaw shared channel-streaming helpers.
- Inspected Inline monitor implementation and tests.
- Initially described the gap incorrectly as progress-mode answer streaming; user corrected this. Treat that as resolved: the implementation must be separate from answer streaming.
- Implemented Inline progress placeholder state in `packages/openclaw/src/inline/monitor.ts`:
  - `sendMessage(..., sendMode: "silent")` for the temporary placeholder.
  - `Method.EDIT_MESSAGE` for progress updates.
  - `Method.DELETE_MESSAGES` cleanup before visible final reply/fallback.
  - Serialized progress operations with an op chain.
  - Wired `onReasoningStream`, `onToolStart`, `onItemEvent`, `onPlanUpdate`, `onApprovalEvent`, `onCommandOutput`, `onPatchSummary`, and compaction callbacks.
  - Suppressed default visible tool-progress messages while the placeholder is active.
- Final pass adjustment: suppression is now tied directly to the Inline placeholder being active, because the shared helper returns false for an unset streaming config while Inline intentionally defaults to placeholder progress.
- Updated Inline tests to mock distinct sent message IDs and `DELETE_MESSAGES`, and added a focused send/edit/delete-before-final progress placeholder test.
- Updated schema/manifest docs for `streaming.progress.maxLineChars` and the new separate progress placeholder behavior.
- Bumped Inline OpenClaw package host/peer floor from `>=2026.5.18` to `>=2026.5.28` because the implementation imports the new channel-streaming progress helpers.
- Enabled progress mode in local OpenClaw config at `~/.openclaw/openclaw.json`:
  - `channels.inline.streaming.mode = "progress"`
  - `channels.inline.streaming.progress.toolProgress = true`
  - `channels.inline.streamViaEditMessage = false`
- Restarted the gateway with `openclaw gateway restart --safe`; health check passed with Inline configured.
- Checked the current managed installed plugin under `~/.openclaw/npm/node_modules/@inline-openclaw/inline/dist`; the runtime JS does not yet contain the new `inline progress placeholder` implementation, so config is ready but the patched dist still needs to be installed for the new behavior.
- After user approval, ran `bun run build`, copied the fresh `dist`, `openclaw.plugin.json`, and `package.json` into `~/.openclaw/npm/node_modules/@inline-openclaw/inline`, and confirmed the installed runtime JS contains the new progress placeholder code.
- Restarted the gateway again with `openclaw gateway restart --safe`; health check passed with Inline configured.
- Started release prep for `@inline-openclaw/inline@0.0.39`:
  - npm latest is `0.0.38`.
  - local npm auth is not configured (`npm whoami` returned 401), so publishing needs login/token/CI trusted publishing.
  - bumped package version to `0.0.39`.
  - updated README minimum OpenClaw version to `2026.5.28`.
  - reran release checks and produced `/tmp/inline-openclaw-inline-0.0.39.tgz`.
  - npm publish dry-run passed for `0.0.39` with `latest` tag and public access.
- Confirmed npm registry latest is now `@inline-openclaw/inline@0.0.39`.
- Updated local OpenClaw managed Inline plugin install from `0.0.38` to `0.0.39` with `openclaw plugins install @inline-openclaw/inline@latest --force`.
- Verified the installed managed runtime contains the new progress placeholder code.
- `openclaw plugins doctor` reports no plugin issues.
- Restarted gateway and confirmed health: `OK`, Telegram configured, Inline configured.
- Fresh startup log check found zero `warn`/`error`/`fatal` entries in the latest gateway startup window.
- Set `plugins.allow` to `["inline"]` to remove OpenClaw's non-bundled plugin auto-load warning; config validation passed.
- Checked OpenClaw core updater status: stable latest is `2026.5.28`, matching the installed `OpenClaw 2026.5.28 (e932160)`.
- Investigated suspected reply-thread creation failures after live testing:
  - Targeted log search found no current `createSubthread`, `subthread`, `thread-create`, or `inline create reply thread failed` entries.
  - A previous 2026-05-31 log showed an agent `config.patch` attempt failed because `channels.inline.replyThreadMode` is a protected config path.
  - Current config had `capabilities.replyThreads=true` but no `replyThreadMode`, so ordinary group replies stayed in parent chats by design.
  - Set `channels.inline.replyThreadMode="thread"` with `openclaw config set`; config validation passed.
  - Kept the default auto-create threshold (`replyThreadAutoCreateMinMessages=50`, unset) rather than forcing every parent-chat message into a thread.
- Re-pinned the local managed plugin install from `@inline-openclaw/inline@latest` to exact `@inline-openclaw/inline@0.0.39`; this removed the unpinned plugin security finding.
- Restarted gateway after the reply-thread config and plugin pin:
  - health passed with Telegram and Inline configured.
  - `openclaw plugins doctor` reported no plugin issues.
  - latest startup log scan found zero `warn`/`error`/`fatal` entries.
  - health JSON showed a fresh Inline reply-thread session key: `agent:main:inline:group:1020:thread:2508`, confirming thread routing is active after the config change.
- Compared Inline progress placeholder behavior against current OpenClaw Telegram/Discord sources:
  - Inline uses the same shared `channel-streaming` helpers for progress labels, tool/action line formatting, line merging, max-line bounds, command output, approval, plan, patch, and item events.
  - Inline suppresses default tool-progress messages while its progress placeholder is active, matching the current Discord/Telegram direction.
  - Inline intentionally differs in transport: it sends a separate silent message, edits it, and deletes it before final delivery; Discord/Telegram use their draft/preview lanes and clear/discard them during cleanup.
  - Telegram still special-cases status reactions; Discord uses status reactions and a draft preview abstraction. Inline has no equivalent reaction transport, so the text progress payload is the relevant parity point.
- Full `openclaw doctor` still reports broader non-plugin warnings: legacy `openai-codex/*` model refs, Codex plugin disabled for Codex runtime models, one expired old OAuth profile, command owner missing, plaintext secret-bearing config fields, optional skills missing dependencies, and gateway service PATH hygiene. Did not run `openclaw doctor --fix` because it rewrites unrelated OpenClaw config.

## Commands Run

- `rg --files packages/openclaw`
- `rg --files /Users/mo/dev/openclaw`
- `git status --short`
- `rg --files /Users/mo/dev/openclaw/extensions | rg '/(telegram|discord)/'`
- `rg -n "progress|draft|silent|editMessage|..." /Users/mo/dev/openclaw/extensions/telegram/src`
- `rg -n "progress|draft|silent|editMessage|..." /Users/mo/dev/openclaw/extensions/discord`
- `rg -n "progress|draft|silent|editMessage|..." packages/openclaw/src`
- Multiple `sed -n` reads of the files listed above.
- `web.open` on the OpenClaw `v2026.5.28` release page.
- Config update command that rewrote only Inline streaming fields in `~/.openclaw/openclaw.json`.
- `openclaw gateway restart --safe`
- `openclaw gateway health --expect-final --timeout 30000`
- `rg -n "inline progress placeholder|allowProgressCallbacksWhenSourceDeliverySuppressed|progressPlaceholderEnabled|createChannelProgressDraftGate" "$HOME/.openclaw/npm/node_modules/@inline-openclaw/inline/dist" -g '!*.map'`
- `cd packages/openclaw && bun run build`
- `cp -R dist/. "$HOME/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/"`
- `cp openclaw.plugin.json package.json "$HOME/.openclaw/npm/node_modules/@inline-openclaw/inline/"`
- `npm view @inline-openclaw/inline version dist-tags --json`
- `npm whoami`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun vitest run --coverage.enabled=false`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp --json`
- `cd packages/openclaw && npm publish --dry-run --ignore-scripts --access public --tag latest`
- `openclaw plugins inspect inline`
- `openclaw plugins update inline`
- `openclaw plugins install @inline-openclaw/inline@latest --force`
- `openclaw plugins doctor`
- `openclaw config set plugins.allow '["inline"]' --strict-json`
- `openclaw config validate`
- `openclaw gateway restart --safe`
- `openclaw gateway health --expect-final --timeout 30000`
- `openclaw logs --limit 300 --json --timeout 30000`
- `openclaw update status --json`
- `openclaw update --dry-run --json`
- `rg -n "create reply thread failed|createSubthread|subthread|reply thread failed|reply-thread|reply thread|thread-create" /Users/mo/.openclaw/logs /tmp/openclaw`
- `openclaw status --json --all --timeout 30000`
- `openclaw config get channels.inline.capabilities.replyThreads`
- `openclaw config get channels.inline.accounts.default.capabilities.replyThreads`
- `openclaw config set channels.inline.replyThreadMode '"thread"' --strict-json`
- `openclaw plugins install @inline-openclaw/inline@0.0.39 --force --pin`
- `openclaw models status --json`
- `openclaw doctor`
- Source reads comparing `/Users/mo/dev/openclaw/extensions/telegram/src/bot-message-dispatch.ts`, `/Users/mo/dev/openclaw/extensions/discord/src/monitor/message-handler.draft-preview.ts`, and `/Users/mo/dev/openclaw/extensions/discord/src/monitor/message-handler.process.ts`.

## Verification Log

- 2026-06-01 review pass: found and fixed a reply-thread route-cache edge case where JSON fallback files could outlive the intended 7-day route TTL.
- Added `src/inline/thread-routes.test.ts` for route memory lookup, state-dir fallback lookup, and expired fallback rejection.
- Passed review rerun: `cd packages/openclaw && bun run typecheck`.
- Passed review rerun: `cd packages/openclaw && bun run lint`.
- Passed review rerun: `cd packages/openclaw && bun vitest run --coverage.enabled=false src/inline/thread-routes.test.ts src/inline/monitor.test.ts src/inline/actions.test.ts src/inline/channel.test.ts src/inline/reply-threads.test.ts` (5 files, 218 tests).
- Passed review rerun: `cd packages/openclaw && bun vitest run --coverage.enabled=false` (23 files, 325 tests).
- Passed: `cd packages/openclaw && bun run typecheck`
- Passed: `cd packages/openclaw && bun run lint`
- Passed: `cd packages/openclaw && bun vitest run src/inline/monitor.test.ts src/manifest.test.ts --coverage.enabled=false`
- Passed: `cd packages/openclaw && bun vitest run --coverage.enabled=false` (22 files, 321 tests)
- Passed after user approval: `cd packages/openclaw && bun run build`
- Passed after local install: `openclaw gateway health --expect-final --timeout 30000`
- Passed after `0.0.39` bump: `cd packages/openclaw && bun run lint`
- Passed after `0.0.39` bump: `cd packages/openclaw && bun run typecheck`
- Passed after `0.0.39` bump: `cd packages/openclaw && bun vitest run --coverage.enabled=false` (22 files, 321 tests)
- Passed after `0.0.39` bump: `cd packages/openclaw && bun run build`
- Packed release artifact: `/tmp/inline-openclaw-inline-0.0.39.tgz`
- Passed: `cd packages/openclaw && npm publish --dry-run --ignore-scripts --access public --tag latest`
- Registry latest confirmed: `@inline-openclaw/inline@0.0.39`.
- Local OpenClaw managed plugin install confirmed: `inline` version `0.0.39`.
- Passed: `openclaw plugins doctor`
- Passed: `openclaw config validate`
- Passed: `openclaw gateway health --expect-final --timeout 30000`
- Passed: latest gateway startup log scan had `issueCount: 0` for `warn`/`error`/`fatal`.
- OpenClaw core is already latest stable (`2026.5.28`).
- Reply-thread mode now verified from config: `channels.inline.replyThreadMode = "thread"`.
- Pinned plugin spec now verified: `@inline-openclaw/inline@0.0.39`.
- Passed after reply-thread/plugin config changes: `openclaw config validate`.
- Passed after restart: `openclaw gateway health --expect-final --timeout 30000`.
- Passed after restart: `openclaw plugins doctor`.
- Passed after restart: latest gateway startup log scan had `issueCount: 0`.
- Confirmed after restart: OpenClaw health reports a current Inline reply-thread session (`agent:main:inline:group:1020:thread:2508`).
- Progress/tool-call text formatting parity verified against Telegram/Discord shared helper usage.

## Remaining Todos

- Optional: send a real Inline group mention to verify automatic child reply-thread creation end-to-end with `replyThreadMode="thread"`.
- Optional: run `openclaw doctor --fix` only after deciding to accept broader OpenClaw config rewrites.

## Constraints

- Never read `.env` files.
- Do not touch unrelated dirty files.
- Use `apply_patch` for edits.
- Do not run destructive commands without explicit confirmation.
- For JS/TS tooling use `bun`, not npm/yarn.
