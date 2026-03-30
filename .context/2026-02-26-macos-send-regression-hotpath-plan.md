# macOS Send Regression Rollback Plan (2026-02-26)

## Goal
Restore pre-refactor send behavior and animation smoothness by undoing the progressive/message-list refactor path that regressed latency.

## Commits in Scope
- `c51bcf2a` `macos/chat: add progressive history window and local jump flow`
- `c6695c8a` `mac: finalize minimal message mode v0.1` (overlap in `MessageListAppKit`; keep minimal-mode wiring, undo only `c51`-introduced hot-path logic)

## Rollback Mapping
1. Full file rollback to pre-`c51bcf2a`:
   - `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`
   - `apple/InlineKit/Tests/InlineKitTests/FullChatProgressiveTests.swift`
   - `apple/InlineMac/Views/Chat/State/ChatState.swift`
   - `apple/InlineMac/Views/EmbeddedMessage/EmbeddedMessageView.swift`
   - `apple/InlineMac/Views/Message/MessageView.swift`
2. Targeted rollback in `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`:
   - Remove `c51` scroll request struct usage.
   - Remove `c51` remote-older fallback fetch path in `loadBatch`.
   - Remove `c51` around-target local-window jump path.
   - Keep post-`c51` minimal render-style wiring from `c669`.
3. Compatibility follow-up:
   - `apple/InlineMac/Views/Message/MinimalMessageView.swift`: restore `chatState.scrollTo(msgId:)` call shape.

## Validation Run
- `cd apple/InlineKit && swift build` ✅
- `cd apple/InlineKit && swift test --filter FullChatProgressiveTests` ✅

## Traceability Note
When committing, reference both commit IDs in the message body:
- Reverted baseline: `c51bcf2a`
- Partial overlap handled in `MessageListAppKit`: `c6695c8a`
