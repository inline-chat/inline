# Sentry Noise Reduction and Important Error Fix Plan

## Goal

Make Sentry actionable again without hiding real production problems.

The plan is deliberately split into:

- signal hygiene: source maps, dSYMs, release metadata, grouping, tags
- reporting policy: fewer Sentry events for expected states, better breadcrumbs for context
- product fixes: database, sync, transport, translation, timezone, app hang/crash issues

No implementation is included here.

## Current Signal From June 10 Triage

Projects checked:

- `usenoor/inline-server`
- `usenoor/inline-ios-macos`

Important observations:

- Latest backend Sentry logs were repeated `error handling message` entries on trace `8d55902fb2514d60b812a8668f43b062`, latest seen around `2026-06-10 18:41 UTC`.
- Sentry log dataset showed no warning-level logs in the last 24h for either project.
- Apple did not show error/warning logs in the log dataset, but Apple issues are very active.
- Backend source context is still incomplete on some server events (`js_no_source`).
- Mac crashes still have missing dSYMs for current app builds, which blocks reliable root-cause analysis.

Most important issue groups from the triage:

- `INLINE-SERVER-8B`: unhandled fatal `postgres` driver `socket.write` null crash.
- `INLINE-SERVER-88`: `write CONNECTION_CLOSED ...` affecting realtime RPC handling.
- `INLINE-SERVER-8F`: invalid markdown translation output.
- `INLINE-SERVER-8D`: `timeZone=US/Pacific` rejected by `updateProfile`.
- `INLINE-SERVER-8G`: Notion API 529 dependency failure.
- `INLINE-SERVER-5B`: high-volume `PEER_ID_INVALID`.
- `INLINE-SERVER-39`: duplicate `user_ids_unique`.
- prior plan item still relevant: duplicate `random_id_per_sender_unique` send-message recovery noise.
- `INLINE-IOS-MACOS-V`: message insert FK failures.
- `INLINE-IOS-MACOS-R`: high-volume sync stopped / disk write exception grouping.
- `INLINE-IOS-MACOS-2E2`, `2ED`: escalating sync `notConnected` / non-progress update loops.
- `INLINE-IOS-MACOS-2EC`, `2DX`: Mac crash/app hang, currently hard to triage due missing dSYMs.
- prior plan item still relevant: `INLINE-IOS-MACOS-1B` delete-path GRDB datatype mismatch.

## Principles

- Do not silence an issue until we know whether it is expected, recoverable, user-caused, dependency-caused, or a real invariant failure.
- Expected failures should remain visible as structured logs, breadcrumbs, counters, or sampled events, not top-level Sentry issues.
- Errors that can lose user data, corrupt local DB state, crash, hang, or break send/edit/open-chat flows stay reportable.
- Sentry event messages should be specific enough to group usefully. Generic messages like `error handling message` should carry method, error code, origin, and recovery state as tags/fingerprint data.
- Do not add PII to new tags/logs. Keep existing redaction rules intact.
- For latency-critical paths, especially send-message and open-chat, fixes must avoid extra synchronous DB work on hot render or send paths.

## Phase 0: Baseline and Classification

Before code changes, build a short baseline table from Sentry:

- top 20 issues by frequency for the last 24h and 7d
- top new issues from the last 7d
- latest backend logs by trace
- Apple crash/app-hang groups with build, dist, and symbol status

Classify each top group as one of:

- `bug`: code/data invariant failure, crash, app hang, DB corruption, lost message risk
- `dependency`: Notion, Postgres connection, network/provider outage
- `expected-user-input`: invalid id, invalid request, stale client request
- `expected-lifecycle`: cancellation, stopped sync, app background/foreground disconnect
- `observability-bug`: missing symbols/source, bad grouping, overly generic message

Output:

- a small issue table in the PR or follow-up plan
- explicit allowlist/drop-list candidates
- no production behavior changes yet

## Phase 1: Fix Observability Quality First

This makes later triage cheaper and prevents hiding real crashes behind bad symbols.

### Apple dSYMs

Targets:

- `scripts/apple/upload-dsyms.sh`
- `scripts/macos/upload-dsyms.ts`
- `scripts/macos/release-app.ts`
- `.github/workflows/macos-direct-release.yml`
- iOS release pipeline, if it lives outside this repo
- `apple/InlineKit/Sources/InlineKit/Analytics.swift`

Plan:

- Confirm release and dist values match Sentry events: `inline-apple@<version>` plus build number dist.
- Make macOS release upload dSYMs as a required production release step.
- Ensure iOS release pipeline also uploads dSYMs.
- Fail or loudly block release if the app dSYM UUID for the built app is not uploaded.

Verification:

- A fresh Mac crash does not show `native_missing_dsym`.
- `INLINE-IOS-MACOS-2EC`-style crashes become symbolicated enough to point at app code.

### Server Source Maps

Targets:

- `server/src/index.ts`
- `server/scripts/upload-sourcemaps.ts`
- server build/deploy pipeline

Plan:

- Confirm production `release` and `dist` exactly match uploaded artifact release/dist.
- Upload server sourcemaps and built files on deploy.
- Fail deploy or pre-promotion check if sourcemaps are missing for the release.

Verification:

- New backend exceptions map to TypeScript source files and line numbers.
- `js_no_source` stops appearing on new server events.

## Phase 2: Reduce Server Noise

Targets:

- `server/src/utils/log.ts`
- realtime RPC error handling
- high-volume call sites for invalid peers/chats, auth/access denial, translation, upload, and integrations

Plan:

- Introduce an explicit reporting policy at the logging boundary:
  - report unexpected exceptions and invariant failures
  - do not report expected user/input errors by default
  - report dependency outages with stable low-cardinality tags
  - keep expected cases as structured logs/breadcrumbs
- Stop relying on generic event messages like `error handling message`.
- Add stable tags/fingerprints for reportable realtime errors:
  - `rpc_method`
  - `error_code`
  - `input_kind`
  - `transport_state`
  - `origin`
  - `dependency`
- Reclassify high-volume expected server errors:
  - `PEER_ID_INVALID`, `CHAT_INVALID`, invalid chat/space/user ids
  - user not participant / access denied when caused by stale or unauthorized client input
  - duplicate random id cases where send-message already recovers
  - Notion 529 as dependency outage, sampled or grouped by integration operation
- Keep reportable:
  - unhandled exceptions
  - DB constraint violations that indicate invariant drift
  - failed send/edit operations after recovery fails
  - translation output validation failures
  - connection/pool failures that affect active RPCs

Verification:

- Latest Sentry logs are no longer dominated by generic `error handling message`.
- Top server issues after 24h are real correctness/dependency failures, not expected validation churn.
- No loss of breadcrumbs around real exceptions.

## Phase 3: Reduce Apple Noise

Targets:

- `apple/InlineKit/Sources/Logger/Logger.swift`
- `apple/InlineKit/Sources/InlineKit/Analytics.swift`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/WebSocketTransport.swift`
- Sync/update handling under `apple/InlineKit`

Plan:

- Stop turning warning logs into Sentry issues by default.
- Keep warnings in local logs and breadcrumbs.
- Add an explicit reportable path for warnings that indicate data loss or invariant failure.
- Suppress or downgrade expected lifecycle/network churn:
  - `notConnected` during stopped/background/intentional disconnect
  - `connectionTimeout` during retryable reconnect
  - `NSURLErrorDomain` offline/cancelled/transient cases
  - `NSPOSIXErrorDomain` 53/54 connection abort/reset when transport is already reconnecting
  - sync stopped because the sync engine is intentionally shutting down
- Keep reportable:
  - GRDB FK/datatype/constraint failures
  - app hangs and fatal hangs
  - crashes
  - non-progress sync loops
  - repeated failed catch-up that leaves seq stuck
- Add stable tags/fingerprints:
  - bucket type
  - sync phase
  - connection state
  - app build/dist
  - platform iOS/macOS
  - recoverable vs unrecoverable

Verification:

- Top Apple Sentry groups shift away from transport churn and toward DB/sync/crash groups.
- Expected network churn is still visible as breadcrumbs on real issues.
- No new privacy-sensitive user data is added to tags.

## Phase 4: Fix Important Server Errors

### 1. Postgres connection-close / fatal socket write

Issues:

- `INLINE-SERVER-8B`
- `INLINE-SERVER-88`

Risk:

- Can break active realtime RPCs.
- May crash or destabilize the server process.
- Breadcrumbs showed send/edit/translation failures and very slow update-state timing nearby.

Plan:

- Audit Postgres client/pool lifecycle, reconnect behavior, shutdown behavior, and deploy restart timing.
- Identify whether failures cluster around deploy, DB restart, idle timeout, or long-running queries.
- Add safe retry only where the operation is idempotent or has an existing idempotency key.
- For non-idempotent sends/edits, fail cleanly with one reportable dependency outage event and preserve enough context.
- Ensure graceful shutdown stops accepting realtime work before DB connections are torn down.
- Consider driver/runtime version issue only after local code lifecycle is ruled out.

Verification:

- No new unhandled `socket.write` fatal events.
- Realtime RPCs during DB reconnect return controlled errors.
- Send/edit idempotency behavior remains correct.

### 2. Translation markdown validator

Issue:

- `INLINE-SERVER-8F`

Plan:

- Review `server/src/modules/translation2/markdownTranslation.ts`.
- Make validation report exact missing/duplicate/unexpected ids with low-cardinality Sentry tags.
- Add fallback behavior for partial translation output if safe.
- Add tests for duplicate, missing, unexpected, and reordered translation ids.
- Carry over the prior plan's entity-specific cases: valid entities, null entities, and malformed model output.

Verification:

- Invalid model output is either corrected/retried or returned as a controlled translation failure.
- Sentry issue volume drops to only real repeated model-contract failures.

### 3. Timezone alias rejection

Issue:

- `INLINE-SERVER-8D`
- related Apple HTTP 500 updateProfile reports

Plan:

- Decide whether legacy IANA aliases like `US/Pacific` should be normalized server-side.
- If accepted, normalize to canonical `America/Los_Angeles`.
- If rejected, return a typed validation error instead of an internal 500.
- Add tests for common aliases and invalid strings.

Verification:

- `US/Pacific` no longer creates a server error.
- Client receives a predictable response.

### 4. Notion 529

Issue:

- `INLINE-SERVER-8G`

Plan:

- Treat 529 as dependency overload.
- Add operation-specific retry/backoff if the Notion SDK call is safe to retry.
- Otherwise return a controlled integration-unavailable result.
- Report sampled dependency outage events, not every user attempt.

Verification:

- Notion overload does not pollute top error groups.
- User-facing behavior is predictable.

### 5. Duplicate random id recovery noise

Prior issue:

- `INLINE-SERVER-5E`

Targets:

- `server/src/functions/messages.sendMessage.ts`
- `server/src/utils/log.ts`
- `server/src/db/schema/messages.ts`

Plan:

- Treat `random_id_per_sender_unique` duplicate-key hits as the normal idempotency recovery path when the code can fetch the existing message.
- Do not report the recovered branch as a Sentry error.
- Prefer conflict-aware insert/fetch-existing behavior if it simplifies the path.
- Keep a local structured counter/log so a spike is still visible operationally.
- Keep unrecovered duplicate-key failures reportable.

Verification:

- Send-message idempotency behavior remains correct.
- Recovered duplicate random id cases disappear from Sentry without increasing send failures.

## Phase 5: Fix Important Apple Errors

### 1. Delete-path datatype mismatch

Prior issue:

- `INLINE-IOS-MACOS-1B`

Targets:

- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
- safer delete/update handling near realtime update application paths

Plan:

- Re-check the delete path before suppressing any related Sentry noise.
- Ensure deleting the current last message promotes the correct predecessor as the chat's new last message.
- Use deterministic predecessor ordering, not only `date`.
- Add a regression test for deleting the current last message when another message should become the chat last message.

Verification:

- GRDB datatype mismatch no longer reproduces for the delete scenario.
- Chat last-message state remains consistent after deletes.

### 2. Message FK failures

Issue:

- `INLINE-IOS-MACOS-V`

Risk:

- Local DB consistency and sync correctness.

Plan:

- Audit every message write path.
- Make parent chat/user/thread availability explicit before message insert.
- Use one shared strategy:
  - insert minimal parent stubs before message save, or
  - buffer message saves until required parents exist
- Add tests for out-of-order parent/message arrival.

Verification:

- FK failures stop on new builds.
- Catch-up and realtime message insert paths use the same invariant logic.

### 2. Sync stopped / disk write / non-progress loops

Issues:

- `INLINE-IOS-MACOS-R`
- `INLINE-IOS-MACOS-2E2`
- `INLINE-IOS-MACOS-2ED`

Risk:

- High volume, possible battery/disk/perf impact, stuck sync state.

Plan:

- Separate expected stopped/notConnected states from true non-progress loops.
- For non-progress responses, add bounded retry with explicit abort reason and a catch-up recovery path.
- Investigate the disk write metric grouped under `R`; confirm whether it is real excessive local DB/log writes or bad grouping.
- Add sync state tags so Sentry groups by actionable state, not just log text.

Verification:

- No repeated single-user loop producing hundreds of events.
- Sync seq either progresses or schedules a clear catch-up path.

### 4. Mac crashes and app hangs

Issues:

- `INLINE-IOS-MACOS-2EC`
- `INLINE-IOS-MACOS-2DX`
- repeated new `App Hanging` groups

Plan:

- Do not spend much debugging time before dSYMs are fixed.
- After symbolication, group crashes/hangs by app frame and feature area.
- For app hangs, inspect main-thread stacks and correlate with DB writes, sync catch-up, and window/event routing.
- Add focused performance validation for any fix touching message list, send, sync, or DB observation paths.

Verification:

- Crashes point to app code.
- App hang groups reduce or have concrete app-frame ownership.

## Phase 6: Acceptance Criteria

Noise reduction is successful when:

- warning-level logs do not create Sentry issues by default
- generic `error handling message` is no longer a top issue/log message
- expected invalid input and transport churn no longer dominate top 20 issue lists
- real failures still have breadcrumbs and enough tags to debug

Important-error work is successful when:

- no new unhandled backend postgres socket-write fatal appears
- backend translation invalid-output has tests and controlled behavior
- timezone alias input no longer reports as internal server error
- Apple message FK failures stop on new app builds
- escalating sync loops are either resolved or grouped with clear root state
- current macOS/iOS release builds upload symbols

## Suggested Execution Order

1. Fix Apple dSYMs and server sourcemaps.
2. Add reporting policy and grouping improvements, starting with backend realtime and Apple logger.
3. Reclassify expected validation/network/lifecycle noise.
4. Fix backend postgres connection-close handling.
5. Fix Apple delete-path and message FK issues.
6. Fix Apple sync non-progress loops.
7. Fix translation validator, timezone alias handling, and duplicate random id reporting.
8. Re-run Sentry comparison after 24h and one app release.

## Trade-offs To Confirm

- We should not drop expected errors entirely; keep them as structured logs, breadcrumbs, or sampled events.
- Some server validation errors may still represent client bugs. Downgrading should be code-aware, not blanket suppression by error name.
- Apple network errors should stay attached to real crashes as breadcrumbs, even when not reported as standalone issues.
- Symbol/source upload should be treated as release infrastructure, not a best-effort nice-to-have.
