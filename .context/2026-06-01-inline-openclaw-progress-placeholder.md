# Inline OpenClaw Progress Placeholder

Date: 2026-06-01

## Goal

Implement a separate temporary progress indicator for the Inline OpenClaw plugin while the LLM is working/thinking/calling tools.

Required behavior:

- Send a separate progress placeholder message with `sendMode: "silent"`.
- Continuously edit that same placeholder as progress events arrive.
- Delete the placeholder when the final answer is ready, before or around final delivery.
- Keep this independent from answer streaming/edit previews.

## User Correction

Important correction from Mo:

> Do not confuse the progress "working..." temporary message with streaming messages.

This task is not about turning `streaming.mode=progress` into answer streaming. It needs a separate progress placeholder lifecycle. If Inline already had answer edit streaming, that is not the feature being requested.

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

## Verification Log

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
- Blocked for real public npm publish until npm auth is available.

## Remaining Todos

- Commit release prep for `@inline-openclaw/inline@0.0.39`.
- Publish to npm once auth is available.

## Constraints

- Never read `.env` files.
- Do not touch unrelated dirty files.
- Use `apply_patch` for edits.
- Do not run destructive commands without explicit confirmation.
- For JS/TS tooling use `bun`, not npm/yarn.
