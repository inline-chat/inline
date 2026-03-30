# Non-space thread home work (step 1) — discarded

Date: 2026-01-17

## Summary
Implemented server access/update-group support for non-space threads (threads without space_id, membership via chat_participants) and added focused tests. Ran tests successfully. These changes were then discarded per request.

## Files changed
- server/src/modules/authorization/accessGuards.ts
  - Added non-space thread access check using chat_participants and AccessGuardsCache.
- server/src/modules/updates/index.ts
  - Allowed threadUsers update group for non-space threads (participants only).
  - Made UpdateGroup.threadUsers.spaceId optional.
- server/src/__tests__/modules/accessGuards.test.ts
  - Added test: allows participants for non-space threads and rejects others.
- server/src/__tests__/functions/getUpdateGroup.test.ts
  - Added tests for non-space thread in getUpdateGroup and getUpdateGroupFromInputPeer.

## Tests run
- cd /Users/mo/dev/inline/server && bun test src/__tests__/modules/accessGuards.test.ts src/__tests__/functions/getUpdateGroup.test.ts

## Notes
- No client or proto changes were made.
- UpdateGroup threadUsers now works for non-space threads by returning participant userIds.
