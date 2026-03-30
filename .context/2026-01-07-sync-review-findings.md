# Sync Review Findings (Backend -> Apple Clients)

Date: 2026-01-07
Scope: `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift`, `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift`

## Findings

1) **Catch-up drops older updates if realtime advances `seq` mid-fetch (ordering + gaps + loops).**  
   - In `Sync.process`, realtime updates are applied immediately and `updateBucketStates` updates the bucket actor’s `seq`.  
   - In `BucketActor.fetchNewUpdatesOnce`, duplicate filtering uses `update.seq <= self.seq`.  
   - If realtime updates advance `self.seq` while a fetch is in progress, older catch-up updates are filtered out as duplicates. That creates gaps and out-of-order application, and can keep the server emitting `hasNewUpdates`, which looks like a loop.  
   - Files/lines: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:119`, `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:302`, `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:636`, `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:746`

2) **Event ordering is not preserved between transport and sync.**  
   - Transport events are handled in a detached task; each event is forwarded via a new `Task`. This allows reordering of `.connecting`, `.open`, `.updates`, `.ack`, `.rpcResult`.  
   - That can explain out-of-order sync events and connection state flapping (“slow connecting”).  
   - Files/lines: `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift:155`, `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift:193`, `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift:105`

3) **Realtime updates and bucket catch-up are intentionally uncoordinated.**  
   - TODO comment acknowledges ordering is not guaranteed between catch-up batches and realtime updates for the same bucket.  
   - This can reapply older updates after newer ones.  
   - Files/lines: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:137`, `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:672`

4) **Potential infinite `TOO_LONG` loop.**  
   - When `payload.resultType == .tooLong` and `seqGap <= maxTotalUpdates`, the code sets `sliceEndSeq` and `continue`s without advancing `currentSeq`.  
   - If the server keeps returning `tooLong` for the same `startSeq`, the loop never progresses.  
   - File/line: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:597`

5) **Aggressive reconnect loop on auth timeout.**  
   - `startAuthenticationTimeout` reconnects every 10s with `skipDelay: true` and does not increment `connectionAttemptNo`.  
   - On slow handshake/connectionOpen, this can cause repeated reconnects and perceived slow/stuck connecting.  
   - File/line: `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift:317`

6) **Ordering of updates without `seq` is unstable.**  
   - `orderUpdatesBySeq` puts unsequenced updates at the end; if such updates exist, their original order is lost.  
   - File/line: `apple/InlineKit/Sources/RealtimeV2/Sync/Sync.swift:715`

## Open Questions

- What are the exact server semantics for `getUpdates.startSeq`, `seqEnd` (inclusive/exclusive), and `totalLimit` in `tooLong` cases?
- Are `chatHasNewUpdates` / `spaceHasNewUpdates` designed to repeat until `seq` advances? If so, the seq-jump/duplicate filtering issue will cause loops.
- Do any bucket updates arrive without `seq` in production?

