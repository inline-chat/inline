# Sentry Symbols, Noise, and Important Issues Plan

## Goal

Make Sentry useful again by fixing symbolication/source context, cutting expected-error noise, and then spending engineering time on the small set of issues that look like real product or data-integrity bugs.

## What is true today

- Apple builds already produce dSYMs in release configurations, but no symbol upload step is wired into the repo’s release flow.
- The macOS direct release flow is in `.github/workflows/macos-direct-release.yml`, `scripts/macos/build-direct.sh`, and `scripts/macos/release-app.ts`.
- Apple Sentry startup is in `apple/InlineKit/Sources/InlineKit/Analytics.swift`.
- Apple logger reporting is too aggressive in `apple/InlineKit/Sources/Logger/Logger.swift`. Both `.warning` and `.error` create Sentry events.
- Server builds already emit external sourcemaps in `server/scripts/build.ts`, but no source artifact upload is wired into the repo.
- Server Sentry startup is in `server/src/index.ts`.
- Server logger reporting is also too aggressive in `server/src/utils/log.ts`. `warn()` captures a Sentry warning message, and `error()` captures many expected failures.
- The modern `sentry` binary installed locally is good for browsing issues and API access, but its local help output does not expose artifact upload commands. The upload step should therefore live in CI/release automation via Sentry-supported upload tooling, while keeping `sentry` for triage.

## Workstream 1: Fix symbolication and source context

### 1. Apple symbols

Owner: release pipeline + Apple client

Targets:

- `apple/InlineKit/Sources/InlineKit/Analytics.swift`
- `.github/workflows/macos-direct-release.yml`
- `scripts/macos/build-direct.sh`
- whichever external pipeline currently ships iOS/TestFlight builds

Plan:

- Set explicit Sentry `releaseName` and `dist` in `Analytics.start()`.
- Use a single release format for both platforms, for example `inline-apple@<marketing-version>+<build-number>`.
- Add `dist = <build-number>` so Sentry can separate builds cleanly.
- Add the current commit as a tag or extra field so symbol/debug uploads, releases, and issue triage all point to the same code revision.
- After each macOS release build in `.github/workflows/macos-direct-release.yml`, upload all generated `.dSYM` bundles from the derived data/release output to Sentry.
- Do the same for iOS in the real shipping pipeline. I did not find an iOS release workflow in this repo, so this likely lives outside the repo today.
- Add a release check step that fails the pipeline if zero dSYMs are found or if the upload step fails.

Verification:

- A new Apple issue no longer shows “missing dSYM”.
- Sentry debug-file view shows the uploaded UUIDs for the shipped build.
- A fresh crash from the next release resolves into symbolicated Swift frames instead of raw addresses.

Notes:

- The current missing-symbol symptom is confirmed by Apple issue `INLINE-IOS-MACOS-17W`, which showed missing dSYMs for build `1042`.

### 2. Server sourcemaps and source context

Owner: server deploy/build pipeline

Targets:

- `server/scripts/build.ts`
- `server/src/index.ts`
- whichever CI/deploy path runs the production server build

Plan:

- Set explicit Sentry `release` and `dist` in `server/src/index.ts`.
- Use the same release identifier during build, deploy, and source upload. A practical format is `inline-server@<version>+<commit>`.
- Keep `dist` stable per deployment, ideally the full commit SHA or a deployment ID.
- After `server/scripts/build.ts` finishes, upload `server/dist/**/*.map` plus matching built files to Sentry as source artifacts for that exact release.
- Fail deploy if source artifact upload fails in production mode.
- Add a short smoke check in deployment that queries the release and confirms artifacts exist before promotion.

Verification:

- New Bun/TS exceptions show source context and mapped TypeScript line numbers.
- `js_no_source` stops appearing on newly created server events.

Notes:

- The translation parse issue `INLINE-SERVER-68` showed missing source context on the server side.

## Workstream 2: Reduce Sentry noise without hiding real bugs

### 1. Apple logging and filtering

Owner: Apple client

Targets:

- `apple/InlineKit/Sources/Logger/Logger.swift`
- `apple/InlineKit/Sources/InlineKit/Analytics.swift`
- `apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift`
- `apple/InlineKit/Sources/InlineKit/Transactions2/SendMessageTransaction.swift`
- `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`

Plan:

- Stop treating every `.warning` as a Sentry issue. Keep warnings in OSLog and breadcrumbs unless explicitly marked reportable.
- Introduce a small reporting policy layer:
  - `reportable error`
  - `expected error`
  - `warning only`
- Add a filter in Sentry startup or logger code to drop known expected failures before event capture.
- Suppress or downgrade these classes of Apple noise:
  - `Swift.CancellationError`
  - transport disconnect churn and reconnect noise
  - routine `NSURLErrorDomain` cases such as cancelled, offline, and transient disconnect conditions
  - transaction failures that are expected user/server validation results rather than client bugs
  - stop-state sync failures when the client is intentionally disconnected or shutting down
  - benign media/compression warnings
- Keep enough context as breadcrumbs or tags so a real failure still has the lead-up attached.
- For the errors that remain reportable, add stronger tags/fingerprints such as RPC code, transaction type, transport state, and app build.

Verification:

- Apple issue volume drops materially within one release.
- Top Apple issues become mostly database, data-integrity, or crash issues instead of cancellations and transport churn.
- Grouping becomes cleaner because message-only warning capture is no longer mixing unrelated warnings together.

### 2. Server logging and filtering

Owner: server

Targets:

- `server/src/utils/log.ts`
- call sites that currently send expected failures as `error`
- likely first pass:
  - `server/src/functions/messages.sendMessage.ts`
  - `server/src/modules/files/uploadPhoto.ts`
  - `server/src/modules/files/uploadAFile.ts`
  - `server/src/modules/files/metadata.ts`

Plan:

- Stop sending every `warn()` to Sentry.
- Add an explicit way to log locally without reporting to Sentry for expected cases.
- Keep `error()` for real invariants, unavailable dependencies, unexpected exceptions, and data corruption risks.
- Reclassify user-caused or expected failures as warnings or info:
  - invalid upload dimensions
  - routine bad requests
  - protocol skew such as unknown method calls
  - idempotency collisions that the code already recovers from
- Preserve counters or structured logs for these paths so operational visibility is not lost.
- Review top-volume server groups after the first filter pass and tighten any remaining noisy paths individually.

Verification:

- Server issue volume drops without reducing important exception coverage.
- The remaining top groups are mostly correctness, infra, or integrity problems.

## Workstream 3: Fix the important real issues

### Priority 1: Apple delete-path database bug

Issue: `INLINE-IOS-MACOS-1B`

Targets:

- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
- compare with the safer delete/update handling in `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`

Plan:

- Fix `Message.deleteMessages` so `prevChatLastMsgId` is updated to the promoted predecessor instead of the deleted message ID.
- Use deterministic ordering for predecessor lookup, not `date` alone.
- Add a focused regression test around deleting the current last message when another message should become the new chat last message.

Why first:

- This is a concrete local client bug with repeatable database damage semantics, not just observability noise.

Verification:

- Reproduce the deletion scenario locally and confirm the GRDB datatype mismatch disappears.
- Add a database-level regression test for the delete path.

### Priority 2: Apple message insert foreign-key failures

Issue: `INLINE-IOS-MACOS-V`

Targets:

- `apple/InlineKit/Sources/InlineKit/Models/Message.swift`
- `apple/InlineKit/Sources/InlineKit/Database.swift`
- message-only sync/save paths:
  - `apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift`
  - `apple/InlineKit/Sources/InlineKit/Transactions2/GetMessagesTransaction.swift`
  - `apple/InlineKit/Sources/InlineKit/Transactions2/SearchMessagesTransaction.swift`
  - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift`

Plan:

- Make parent-row availability explicit before inserting messages.
- Choose one consistent strategy:
  - upsert minimal parent stubs first, then insert message rows
  - or buffer message inserts until the required chat/user rows are present
- Audit all message-only save paths so they use the same invariant.
- Add regression coverage for message saves when parent chat/user rows arrive slightly later.

Why second:

- This is the highest-volume Apple issue and likely affects real data consistency.

Verification:

- Reproduce with a message payload that references absent parents and confirm the save path now succeeds.
- Add focused tests for out-of-order realtime/history delivery.

### Priority 3: Server translation entity parsing bug

Issue: `INLINE-SERVER-68`

Target:

- `server/src/modules/translation/entityConversion.ts`

Plan:

- Stop modeling translated entities as a JSON string inside JSON.
- Return structured entity data from the model response schema.
- Parse directly into the translation entity type instead of calling `JSON.parse` on a model-provided string.
- Downgrade the per-message fallback log from error to warning if the system can still return a usable translation without entities.
- Add tests for valid entities, null entities, and malformed model output.

Why third:

- This looks like a real correctness bug, but it has less blast radius than the Apple database issues.

Verification:

- Translation responses with entities no longer trigger parse errors.
- Sentry issue volume for this group drops to zero after deploy.

### Priority 4: Server duplicate `randomId` noise and recovery path

Issue: `INLINE-SERVER-5E`

Targets:

- `server/src/functions/messages.sendMessage.ts`
- `server/src/utils/log.ts`
- `server/src/db/schema/messages.ts`

Plan:

- Treat duplicate `random_id_per_sender_unique` as an idempotency recovery path, not an error report.
- Either:
  - suppress Sentry reporting for the duplicate-key recovery branch
  - or change the write path to use conflict-aware insert semantics and fetch-existing behavior cleanly
- Keep a local counter/log for monitoring if the rate spikes unexpectedly.

Why fourth:

- The current send path already appears to recover. This is primarily observability debt.

Verification:

- Existing send-message idempotency behavior remains correct.
- The issue disappears from Sentry without increasing send failures.

## Execution order

1. Ship symbol/source uploads first so every later fix has usable crash context.
2. Tighten Apple and server reporting policy next so the issue list becomes trustworthy.
3. Fix the Apple delete-path bug.
4. Fix the Apple foreign-key ordering bug.
5. Fix the server translation entity parsing bug.
6. Clean up duplicate-random-id reporting and other expected server noise.
7. Re-rank the issue list after one release/deploy and repeat only on still-high-value groups.

## Success metrics

- New Apple production events are symbolicated within the next release.
- New server production events show mapped TypeScript frames and source context.
- Total weekly issue volume drops sharply, but crash-free signal quality improves.
- The top 10 issue list is dominated by real bugs, not transport churn or user-caused validation failures.
- The four priority issues above trend to zero after their fixes ship.

## Risks and guardrails

- Over-filtering can hide a real regression. Keep filters narrow, code-based, and reviewable.
- Release names must match exactly between runtime and uploaded artifacts, or symbol/source uploads will look successful but still not resolve events.
- Do not replace visibility with silence. Expected failures should still exist as logs, counters, or breadcrumbs.
- Any Apple database fix here should include regression tests because these are data-integrity paths.

## Production readiness

Current production readiness is not ideal. The biggest operational risk is not a single bug, but that missing symbols/source context plus aggressive event capture are hiding the real failures behind noise. Fixing symbolication and reporting policy is the fastest way to make the next bug-fix cycle efficient and safe.
