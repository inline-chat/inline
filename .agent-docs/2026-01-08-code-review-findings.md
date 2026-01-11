# Code Review Findings - 2026-01-08

Review of uncommitted changes before pushing to remote.

## Summary of Changes

### Major Features
1. **Message Forwarding** - New end-to-end feature allowing users to forward messages to other chats (iOS forward sheet, server handler, file/media cloning, protocol types)
2. **macOS Sidebar Redesign** - Replaced tabs (archive/inbox) with a single archive button; split home view into "Threads" and "DMs" sections
3. **Video Download Progress UI** - Added circular progress indicator with cancel button during video downloads
4. **WebSocket Resilience Improvements** - Added network path monitoring (NWPathMonitor), foreground probe ping before reconnect, improved stuck connection detection

### Medium Changes
5. **iOS Chat toolbar refactored** - Extracted `ChatToolbarLeadingView` as separate View struct
6. **Share extension improvements** - Added loading and "no content" states
7. **FullChat refetch throttling** - Added cooldown to prevent excessive `refetchHistoryOnly` calls
8. **DocumentView & PhotoView updates** - Added `update(with:)` methods for reuse, improved intrinsic content size

### Minor Changes
- Print statement replaced with Log in ImageViewerController
- Layout tweaks (MessageReactionView stackView, layoutIfNeeded to setNeedsLayout)
- CODEX.md documentation updates
- Bun lock file and package.json updates

---

## Issues Found

### 1. HIGH - Share extension view logic order may show wrong state

**File:** `apple/InlineShareExtension/ShareView.swift:157-165`

```swift
} else if state.isSending {
  sendingView
} else if state.isLoadingContent {  // <-- This check comes AFTER isSending
  loadingView
```

The `isLoadingContent` check happens after `isSending`. If for some reason both flags are true simultaneously, `sendingView` takes precedence over `loadingView`. The more concerning case is the state machine logic - typically loading should be checked before sending to ensure proper sequencing.

**Action:** Verify that `isLoadingContent` and `isSending` are mutually exclusive in `ShareState`.

---

### 2. MEDIUM - Forward header schema naming inconsistency

**Swift DB migration:** `apple/InlineKit/Sources/InlineKit/Database.swift:528-532`
```swift
t.add(column: "forwardFromPeerUserId", .integer)
t.add(column: "forwardFromPeerThreadId", .integer)  // <-- "ThreadId"
```

**Server schema:** `server/src/db/schema/messages.ts:60-63`
```typescript
fwdFromPeerChatId: integer("fwd_from_peer_chat_id"),  // <-- "ChatId"
```

The Swift client uses `forwardFromPeerThreadId` while the server uses `fwdFromPeerChatId`. The encoder correctly maps from server's `fwdFromPeerChatId` to the protobuf peer type, and Swift's `Message.init(from:)` correctly extracts `.asThreadId()` from the peer.

**Risk:** Low - the mapping is correct but naming inconsistency may cause maintenance confusion.

---

### 3. MEDIUM - Race condition potential in PingPongService probe

**File:** `apple/InlineKit/Sources/RealtimeV2/Client/PingPongService.swift:100-120`

```swift
let result = await withCheckedContinuation { (continuation: ...) in
  pongWaiters[nonce] = continuation
  Task { await client.sendPing(nonce: nonce) }

  Task.detached { [weak self] in
    try? await Task.sleep(for: timeout)
    guard let self else { return }
    await self.timeoutProbe(nonce: nonce)  // <-- Potential race with pong receipt
  }
}
```

The continuation is stored, then two tasks race: sending ping and the timeout. If a pong arrives at nearly the same time as the timeout fires, there's potential for double-resuming the continuation.

The current implementation uses `removeValue(forKey:)` returning nil if already removed, which should prevent double-resume. However, Swift continuations can only be resumed once - resuming twice is undefined behavior.

**Risk:** Low probability but undefined behavior if triggered.

**Recommendation:** Consider using a dedicated state enum or explicit single-use tracking.

---

### 4. LOW - UIHostingController not in view controller hierarchy

**File:** `apple/InlineIOS/UI/CircularProgressHostingView.swift:5`

```swift
final class CircularProgressHostingView: UIView {
  private let hostingController = UIHostingController(rootView: CircularProgressRing(progress: 0))
```

The `UIHostingController` is retained but never properly added to the view controller hierarchy (only its view is added as subview). While this works, it may cause memory leaks or lifecycle issues.

**Recommendation:** Add child view controller using `addChild()` and `didMove(toParent:)`.

---

### 5. LOW - Duplicated forward header encoding logic

**File:** `server/src/realtime/encoders/encodeMessage.ts`

The forward header encoding logic is duplicated between `encodeMessage` (lines 109-128) and `encodeFullMessage` (lines 258-277).

**Recommendation:** Extract to a helper function to avoid drift.

---

### 6. INFO - Network monitor not stopping on deinit

**File:** `apple/InlineKit/Sources/RealtimeV2/Transport/WebSocketTransport.swift`

`stopNetworkMonitoring()` cancels the path monitor, but this is only called in `stop()`. If the transport actor is deallocated without explicit stop, the monitor continues running. The weak self pattern means it won't crash, but the monitor thread continues until the process exits.

**Risk:** Minor resource leak.

---

## Items That Look Correct

1. **Forward messages authorization** - Uses `AccessGuards.ensureChatAccess` for both source and destination chats before forwarding
2. **File cloning** - Creates new file records with new unique IDs instead of sharing, preserving ownership tracking
3. **Message forwarding preserves original forward chain** - If forwarding an already-forwarded message, uses original sender info
4. **Throttling in FullChatViewModel.refetchHistoryOnly** - Properly guards against rapid re-fetches
5. **Transaction registration** - ForwardMessagesTransaction properly registered in TransactionTypeRegistry

---

## Production Readiness

**Verdict: Ready for production with minor concerns**

The changes are generally solid and well-implemented:
- Message forwarding feature is complete with proper authorization
- WebSocket resilience improvements are well-designed
- No security vulnerabilities found

**Items to verify before release:**
1. Share extension state logic order (issue #1) - verify mutual exclusivity of flags
2. Test message forwarding with media (photos, videos, documents) to confirm cloning works correctly
3. Test WebSocket reconnection on network transitions (WiFi to cellular)

**Items for future improvement:**
- Harden PingPong probe race condition (issue #3)
- Fix UIHostingController hierarchy (issue #4)
- Deduplicate forward header encoding (issue #5)
