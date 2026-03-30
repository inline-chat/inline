# macOS Send/Open Chat Performance Investigation (2026-02-24)

## Scope
- Investigate perceived slowdown after recent progressive view model changes.
- Focus paths:
  - Open chat on macOS (`ChatViewAppKit` + `MessageListAppKit` + `MessagesProgressiveViewModel`)
  - Send message on macOS (`ComposeAppKit` + progressive update pipeline)

## Findings
1. `MessagesProgressiveViewModel` was doing local-availability metadata checks on every message add/update/delete, including the send hot path.
2. Those availability checks used `baseQuery()` (`FullMessage.queryRequest()`), which is expensive for existence checks.
3. Add-path duplicate detection also rebuilt a `Set` from all messages on each add.

## Changes Implemented
- `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
  - Use `messagesByID` for add dedupe (remove full-array `Set` rebuild in add path).
  - Skip local-availability DB checks for add/update hot path (`updateLoadedWindowMetadata(updateAvailability: false)`).
  - Keep message window bounds updated in O(1) from first/last message ids.
  - Switch availability checks to scoped `Message` queries instead of `FullMessage` joins.
  - Cache last queried bounds to avoid redundant availability queries.
  - Minor: add/delete incremental cleanups (`Set` lookup for deleted message ids, correct inserted index ranges).

## Validation
- `cd apple/InlineKit && swift build` passed.
- `cd apple/InlineKit && swift test --filter FullChatProgressive` passed (Swift Testing suite executed).

## Remaining Risks / Follow-ups
1. `MessageListAppKit.applyUpdate` rebuilds row structures for every update, including non-structural updates.
2. `MessagesProgressiveViewModel.messages` still rebuilds `messagesByID` on every mutation via `didSet`.
3. Text-only sends in `ComposeAppKit` use direct RPC (`Api.realtime.send`) rather than optimistic local transaction, which can make perceived latency network-dependent.
