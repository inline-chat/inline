# Telegram-inspired sync reliability plan

Date: 2026-06-03

## Goal

Improve RealtimeV2 sync correctness and reliability using Telegram's difference/channel-difference patterns, while keeping the hot path fast:

- realtime pushes stay strict, cheap, and ordered
- catch-up/difference is the authoritative repair path
- catch-up responses are referentially complete
- gaps, invalid peers, and too-long histories do not cause replay loops
- server and client cursors never advance through unproven state

## Telegram patterns worth copying

Telegram uses two related repair APIs:

- global `updates.getDifference`
- per-channel `updates.getChannelDifference`

Both difference responses include sidecars. Global difference has messages, other updates, chats, users, and state. Channel difference has channel messages, other updates, chats, users, and sometimes a dialog reset snapshot. Clients apply users/chats before messages.

Live updates are stricter. Telegram and TDLib check whether referenced peers/chats/users are already locally acceptable. If not, they do not synthesize missing rows from the live update; they schedule difference.

For channels, PTS is per-channel. If a channel update has a PTS gap, clients postpone the update, run channel difference, then replay or drop postponed updates depending on whether they still make sense. This matches Inline chat/thread buckets better than Telegram global seq.

## Current Inline shape

- `GetUpdatesResult` returns only `repeated Update` plus seq/date/final/resultType.
- Chat, space, and user buckets share one `getUpdates` RPC.
- Chat bucket seq is effectively our thread/channel PTS.
- `getUpdatesState` is date-based and pushes `chatHasNewUpdates` / `spaceHasNewUpdates` hints out-of-band.
- Some server updates inflate full payloads, but not in a uniform sidecar model.
- Current client catch-up can materialize minimal missing chat/user rows only as a fallback.

## First-pass recommendation

Do not start by replacing `getUpdates` with a new RPC. Add sidecars to the existing `GetUpdatesResult` first. This is lower risk, backward compatible at the protobuf level, and fixes the class of bugs where a catch-up message references a missing chat/user.

Design `getChatDifference` in parallel, but implement it only if the too-long/reset semantics become awkward inside generic `getUpdates`.

## 1. Add required sidecars to getUpdates

Protocol:

- Add a new optional message field to `GetUpdatesResult`, for example `UpdatesEntities entities = 7`.
- `UpdatesEntities` should include at least:
  - `repeated Chat chats`
  - `repeated User users`
  - `repeated Dialog dialogs`
  - optionally `repeated Space spaces`
- Keep `updates` unchanged for backward compatibility.

Server:

- While inflating updates, collect referenced entities:
  - chats for `message.chatId`, thread peers, forwarded thread peers, `newChat`, `chatMoved`, `chatOpen`
  - users for `message.fromId`, private peer users, forwarded users, private-chat other users
  - dialogs for user-visible/open chats when needed
  - spaces when a user/space update references a space snapshot
- Fetch sidecars in bounded batch queries, not per update.
- Deduplicate sidecars by id.
- Apply privacy filtering the same way as existing encoders.
- Add regression tests for a thread message catch-up where the local client lacks the thread chat row.

Client:

- Add an `applySidecars` step before catch-up updates.
- Apply sidecars in the same DB write transaction, or in a prelude transaction immediately before the update chunk.
- For catch-up, require sidecars or existing local rows for all message FKs.
- Keep the current placeholder materialization only as a temporary compatibility fallback for old servers.
- Realtime pushes remain strict and should not create placeholder chats/users.

Acceptance:

- Missing local thread chat + catch-up new message applies without FK failure.
- Missing local private chat + catch-up new message applies without FK failure.
- Realtime new message with missing references still does not silently create rows.
- Sidecar application is idempotent and does not regress existing chat/dialog fields.

## 2. Decide on separate getChatDifference / getThreadDifference

Reasons to add it:

- Chat buckets are closer to Telegram channel PTS than generic update streams.
- Thread catch-up can return thread-specific reset snapshots: chat, dialog, latest messages, pinned state, read state, users.
- Access errors are clearer. A `peerIDInvalid` for a chat difference means invalidate that chat bucket.
- Active-thread fetching can be prioritized and tuned separately.
- `tooLong` can have a richer result without complicating user/space buckets.

Reasons to delay it:

- Existing generic `getUpdates` already has bucket routing and broad tests.
- Sidecars can be added there with less client/server churn.
- Space and user buckets also benefit from sidecars.
- A new RPC requires protocol generation, SDK updates, and rollout coordination.

Decision:

- First patch: sidecars on existing `getUpdates`.
- Second patch: design `getChatDifference` as a v2 API, then implement if `tooLong` reset or active-thread priority needs cannot stay clean in `getUpdates`.

## 3. Improve TOO_LONG behavior

Current risk:

- A cold-start `TOO_LONG` can fast-forward the cursor and discard pending updates.
- This prevents loops, but it does not repair local chat/message state.

Plan:

- For chat buckets, make `TOO_LONG` return an authoritative reset snapshot:
  - target chat
  - dialog if visible to the user
  - latest N messages
  - pinned messages
  - read/unread state if available
  - required users/chats/spaces sidecars
  - final seq/date to advance to
- Client applies reset snapshot, marks history as having a hole before the snapshot, then advances seq.
- For user/space buckets, keep bounded slices unless a proper reset shape is defined.

Acceptance:

- Large thread gap resets local thread header and latest messages without loading full history.
- Cursor advances only after reset snapshot applies.
- History pagination can still fetch older messages normally.

## 4. Stop advancing over failed inflation

Current risk:

- Server can advance delivered seq beyond records that were not inflated.
- This is okay only for explicitly unsupported/no-op updates, not for missing referenced data.

Plan:

- Classify skipped records:
  - `unsupported_but_safe_to_skip`
  - `missing_message`
  - `missing_chat`
  - `missing_user`
  - `access_denied`
  - `corrupt_update`
- Only safe skips can advance.
- Missing/corrupt required data should return a typed sync error or `TOO_LONG` reset.
- Add logs/Sentry breadcrumbs with bucket, seq, type, and classification, but no message text.

Acceptance:

- Missing message referenced by update does not silently advance cursor.
- Unsupported update can advance only if explicitly marked safe.
- Tests cover missing message/chat/user paths.

## 5. Make chat/space seq allocation drift-safe

Current risk:

- User bucket allocation already reconciles against persisted `updates`.
- Chat/space paths still largely trust `entity.updateSeq + 1`.

Plan:

- Create a shared allocator for chat/space buckets using the same idea as `UserBucketUpdates`:
  - update entity `updateSeq = greatest(entity.updateSeq, latest persisted update seq) + 1`
  - write `lastUpdateDate` in the same statement/transaction
  - insert update with returned seq
- Replace direct `UpdatesModel.insertUpdate` call sites for chat/space with bucket-specific helpers.
- Add guardrail tests preventing direct chat/space `updates` inserts outside the allocator.

Acceptance:

- Stale `chats.updateSeq` or `spaces.updateSeq` cannot produce duplicate seq.
- Concurrent updates for one chat produce unique monotonic seq.
- Existing update push call sites still publish correct `updateSeq`.

## 6. Add acceptable-update validation

Goal:

- Fail fast and schedule catch-up when live updates reference missing local state.

Plan:

- Keep realtime strict.
- Add typed missing-reference errors from update apply instead of only raw SQLite FK failures.
- Avoid adding extra DB reads on the hot path until sidecars are in place.
- After sidecars, optionally add a small known-entity cache for chat/user existence if profiling shows FK failures are expensive.
- Missing refs in realtime should schedule catch-up; missing refs in catch-up should be a sidecar/protocol bug.

Acceptance:

- Realtime missing chat/user produces a typed failure and catch-up.
- Catch-up missing sidecar produces an explicit sync error, not placeholder rows unless compatibility mode is active.
- Send/open-chat latency does not regress.

## 7. Bound realtime gap buffers

Current risk:

- `bufferedRealtimeUpdates` can grow under repeated out-of-order or invalid updates.

Plan:

- Add per-bucket buffer limits:
  - max count
  - max age from first buffered update
  - max seq gap
- If exceeded, clear buffered updates and run bounded catch-up to the highest known seq.
- Keep non-retryable invalidation behavior from the current fix.
- Add stats for buffer size, buffer clear count, and oldest gap age.

Acceptance:

- Large out-of-order burst does not grow memory unbounded.
- Buffer overflow triggers one catch-up, not a fetch storm.
- Contiguous realtime updates still apply with no added DB work.

## 8. Make getUpdatesState deterministic

Current risk:

- `getUpdatesState` is date-based and pushes bucket hints as a side effect.
- Date cursors need safety gaps and can rescan or miss edge cases if update dates drift.

Plan:

- Extend `GetUpdatesStateResult` with `repeated ChangedBucket changed_buckets`.
- Each changed bucket includes bucket key, seq, and date.
- Client processes returned buckets directly.
- Keep server push side effect temporarily for old clients.
- Consider storing a global user-visible update index later if date scans become expensive.

Acceptance:

- Reconnect can discover changed buckets from the RPC response alone.
- Duplicate pushed hints remain harmless.
- Date fallback remains for old clients during rollout.

## 9. Prioritize active-thread catch-up

Plan:

- Add priority to bucket fetch requests:
  - visible/open chat
  - user bucket
  - active/recent chats
  - spaces/background chats
- Let UI route changes tell Sync which chat is active.
- Keep global concurrency limit, but schedule high-priority fetches first.
- Do not starve background buckets; use fairness after active work drains.

Acceptance:

- Opening a thread with a gap repairs that thread before background buckets.
- User-bucket removals/kicks still run promptly.
- No increase in max concurrent `getUpdates` RPCs.

## 10. Add sync observability

Plan:

- Add structured metrics/counters:
  - bucket fetch count/failure/follow-up
  - too-long count
  - invalidated bucket count
  - missing-reference classification
  - catch-up apply duration
  - realtime apply failure count
  - buffer size and buffer age
  - sidecar counts and sidecar apply duration
- Add Sentry breadcrumbs for bucket key, seq range, result type, and error classification.
- Never include message text or decrypted payloads.

Acceptance:

- A future report like the `peerIDInvalid`/FK loop identifies the exact failing bucket, seq, missing entity kind, and whether catch-up returned sidecars.
- Slow apply over threshold is visible before it becomes a UI stall.

## Proposed implementation phases

### Phase 1: Sidecar-compatible getUpdates

- Extend proto.
- Regenerate protocol.
- Server returns sidecars for chat bucket message updates and chat/user/dialog structural updates.
- Apple applies sidecars before catch-up updates.
- Keep placeholder materialization as compatibility fallback.
- Add focused server and Apple tests.

### Phase 2: Cursor correctness

- Classify update inflation failures.
- Stop advancing over missing required data.
- Add drift-safe chat/space seq allocators.
- Add guardrail tests.

### Phase 3: Gap handling and buffers

- Add buffer count/age/gap bounds.
- Add typed apply failures and catch-up scheduling.
- Improve retry/backoff behavior around non-progress and invalid buckets.

### Phase 4: Deterministic reconnect and priority

- Extend `getUpdatesState` with `changed_buckets`.
- Add priority scheduling for active chat/user bucket.
- Preserve legacy date/push behavior during rollout.

### Phase 5: getChatDifference v2

- Add dedicated chat/thread difference only if Phase 1-4 reveal that generic `getUpdates` cannot express reset semantics cleanly.
- Include explicit `empty`, `difference`, and `too_long_reset` variants.
- Make `too_long_reset` authoritative for thread header, dialog, latest messages, pinned/read state, and sidecars.

## Production readiness notes

- Security: sidecars must obey the same access/privacy checks as current encoders. Public-space user sanitization still applies.
- Performance: sidecars must be batched and deduped. Avoid per-update DB queries. Realtime hot path should not gain extra DB reads in Phase 1.
- Compatibility: protobuf field additions are safe, but generated Swift/TS must be rolled out carefully. Old clients ignore sidecars; new clients should tolerate missing sidecars only during compatibility fallback.
- Reliability: cursor advancement must happen only after update plus sidecar apply succeeds.
