# Sync Hardening: Persisted Read/Unread State + Catch-up Reliability (2026-02-08)

## Goal
Make sync stable, reliable, and fast enough for production by fixing correctness gaps in full sync (catch-up) and reducing flakiness. In particular, ensure dialog read state (`readMaxId`) and manual unread state (`unreadMark`) are repairable across sessions/devices via user-bucket catch-up.

## Summary Of What Changed

### Server: Persist Per-User Dialog State In User Bucket
- Added new server-bucket update types to persist per-user dialog state changes:
  - `ServerUserUpdateReadMaxId` (`user_read_max_id`)
  - `ServerUserUpdateMarkAsUnread` (`user_mark_as_unread`)
- `readMessages` now:
  - Persists `userReadMaxId` when the read max advances.
  - Persists `userMarkAsUnread(false)` when it clears `unreadMark` without advancing read max.
  - Persists the empty-chat path (no `maxId`) when clearing `unreadMark`.
  - Hardening: never regresses `readInboxMaxId` if the client sends a stale smaller `maxId`.
  - Only sends iOS notification cleanup when read max advances.
- `markAsUnread` now:
  - No-ops if already marked unread.
  - Persists `userMarkAsUnread(true)` to the user bucket.
  - Pushes realtime only to the user’s sessions (per-user setting), skipping the initiating session.
- Sync inflation:
  - User bucket `userReadMaxId` inflates into core update `updateReadMaxId`.
  - User bucket `userMarkAsUnread` inflates into core update `markAsUnread`.

### Apple (InlineKit): Sync Engine Robustness
- Sync engine now holds strong references to the protocol client (weak refs were causing silent sync stoppage and test flakiness).
- Catch-up filter now includes dialog state updates:
  - `updateReadMaxID`
  - `markAsUnread`
- Tests:
  - Added/updated tests to validate user bucket catch-up applies `updateReadMaxId`.
  - Tweaked timeouts/yields to reduce flakiness in reconnect-related tests.

## Tests Added / Coverage
- Server tests:
  - Inflation unit tests for the new user-bucket update types.
  - Integration-style test: `readMessages` persists `userReadMaxId` and `getUpdates` inflates it into `updateReadMaxId`.
  - Regression tests: `readMessages` does not regress `readInboxMaxId`; can clear `unreadMark` without regressing read max.
  - `markAsUnread` tests include the empty-chat readMessages path persisting `userMarkAsUnread(false)`.
- Apple tests:
  - Catch-up applies `updateReadMaxId` in user bucket.

## Commits
- `fa6f9f04 server: persist dialog read/unread state for sync`
  - Server proto additions, persistence in `readMessages` and `markAsUnread`, inflation in `Sync`, and tests.
- `ead4c7df apple: harden realtime sync catch-up`
  - Sync engine strong refs, catch-up filter, and test stabilization.

## Commands Run (Green)
- `cd server && bun test`
- `cd server && bun run typecheck`
- `cd apple/InlineKit && swift test`
- `cd web && bun run typecheck` (sanity check after proto/codegen)

## Production Readiness
Ready to ship the scoped changes.

## Rollout Notes / Operational Risks
- Deploy server first (backwards compatible; older clients ignore new server-only update types).
- Watch user-bucket write volume to the `updates` table.
  - Sequencing uses `SELECT ... FOR UPDATE` in user-bucket enqueue; monitor for contention/latency under heavy read/unread churn.

