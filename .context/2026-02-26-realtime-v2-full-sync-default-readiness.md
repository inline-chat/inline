# RealtimeV2 Full Sync Default Readiness + Flaky Disconnect Investigation

## Goals
- Assess whether `enableSyncMessageUpdates` can safely become default-on in RealtimeV2.
- Evaluate reliability, correctness, performance, and overall design risks.
- Fix the observed flaky-network delayed disconnection/reconnect state issue.

## Scope
- `apple/InlineKit/Sources/RealtimeV2/*`
- `apple/InlineKit/Tests/InlineKitTests/RealtimeV2/*`
- Server contract checks for sync: `server/src/functions/updates.getUpdates.ts`, `server/src/modules/updates/sync.ts`, `server/src/functions/updates.getUpdatesState.ts`

## Investigation Notes
- Baseline focused RealtimeV2 tests passed (45 tests, 0 failures):
  - `SyncTests`
  - `ConnectionManagerTests`
  - `RealtimeStateDisplayTests`
  - `RealtimeSendTests`
  - `AuthRealtimeIntegrationTests`
- Identified correctness gap:
  - `chatMoved` is produced by server sync inflation but skipped by RealtimeV2 catch-up filtering.
- Identified flaky-network responsiveness issue:
  - Liveness detection depends on ping interval + timeout and was too slow under intermittent drops.

## Planned Changes
1. Sync correctness:
- Handle `chatMoved` in RealtimeV2 catch-up filtering/routing.
- Add targeted regression test.
- Add user-bucket routing for `updateReadMaxID` in `getBucketKey` (defensive consistency).

2. Flaky disconnect responsiveness:
- Tighten default ping cadence/timeouts in `ConnectionPolicy`.
- Reduce default connection-state display delay in `RealtimeState` so connecting is surfaced sooner.
- Add targeted tests to pin new defaults.

3. Verification:
- Re-run focused RealtimeV2 tests.
- Report residual risks and go/no-go recommendation for default-on rollout.

## Risks to Call Out in Final Review
- Long-offline (>14 days) stale sync state path still uses cursor reset without full cache reconciliation.
- Any remaining intentionally skipped catch-up update kinds (if any) should be explicitly documented before default-on.
