# iOS: Memory Background Jetsam Investigation + Fix Plan (2026-02-07)

From notes (Feb 7, 2026): "investigate why iOS app is quit in background by OS bc of memory".

This is an investigation-first spec: confirm the dominant retention paths, then ship low-risk cache/retention fixes.

## Problem Statement

The iOS app is being terminated by the OS while in background (likely Jetsam due to memory pressure). We need to identify which subsystems retain memory across background and add bounded caches + trimming on lifecycle events.

## High-Confidence Suspects (From Code Review)

1. Unbounded in-memory cache for users/chats/spaces.
2. Media tab loads all chat media into memory (`fetchAll`) and does expensive grouping/sorting.
3. Message list retains an unbounded `[FullMessage]` graph (heavy joins per message).
4. Image prefetcher and shared Nuke cache can grow without explicit limits or pruning.
5. Compose multi-photo preview holds large arrays of `UIImage`.

Key files:
- Object cache: `apple/InlineKit/Sources/InlineKit/ObjectCache/ObjectCache.swift`
- Media tab: `apple/InlineKit/Sources/InlineKit/ViewModels/ChatMedia.swift`, `apple/InlineIOS/Features/ChatInfo/PhotosTabView.swift`
- Message list model: `apple/InlineKit/Sources/InlineKit/ViewModels/FullChatProgressive.swift`, `apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift`
- Image prefetch: `apple/InlineIOS/Utils/ImagePrefetcher.swift`
- Compose previews: `apple/InlineIOS/Features/Compose/PhotoUtils.swift`, `apple/InlineIOS/Features/Media/SwiftUIPhotoPreviewView.swift`

## Goals

1. Reduce steady-state memory footprint during long chat sessions and media browsing.
2. Ensure memory is trimmed aggressively on background and memory warning.
3. Avoid UX regressions: keep scrolling smooth and avoid re-downloading aggressively.

## Non-Goals

1. Re-architect the entire message model in one pass.
2. Perfect memory usage on all device classes without measurement.

## Investigation Plan (Do This First)

### 1. Confirm Jetsam reason and peak memory

1. Fetch Jetsam logs from device (Xcode Organizer -> Device Logs).
2. Record the kill reason and memory footprint at termination time.

### 2. Instruments scenarios (real device)

Run Allocations + VM Tracker for:
1. Open a large chat, scroll up for minutes, background the app.
2. Open Chat Info -> Photos tab, scroll to load many groups, background the app.
3. Select 20-30 large photos in compose, open preview, background the app.

Track:
1. Largest classes: `UIImage`, `CGImage`, `NSAttributedString`, `FullMessage`, Nuke cache types.
2. Dirty/Compressed size over time (VM Tracker) to see whether memory is released.

### 3. Memory Graph Debugger snapshots

Capture graphs:
1. Right after app launch.
2. After each scenario.
3. Immediately before background (if possible).

We want concrete retention chains for:
1. `MessagesProgressiveViewModel.messages` and `messagesByID`.
2. `ChatMediaViewModel.mediaMessages`.
3. `ObjectCache` storage.
4. Nuke caches and any custom caches.

## Fix Plan (Phased)

### Phase 0: Low-Risk Mitigations (Ship First)

1. Configure Nuke memory and disk cache limits explicitly once at app startup.
2. Clear or trim caches on:
3. `UIApplication.didReceiveMemoryWarningNotification`
4. `UIApplication.didEnterBackgroundNotification`

5. Prune image prefetch state.
6. Cap `prefetchedPhotoIDs` size and clear on background.

7. Add a retention window for chat messages.
8. Keep only a sliding window of messages in memory while allowing DB to remain complete.
9. Evict older `FullMessage` objects when far from viewport.

10. Make media browsing paged.
11. Replace `fetchAll` in `ChatMediaViewModel` with page-based reads and keep a bounded in-memory list.

### Phase 1: Medium Refactors (After We Have Data)

1. Split heavy message graphs from row-level data.
2. Load reactions/attachments/url previews lazily for visible cells only.

3. Add eviction to `ObjectCache`.
4. Options: per-space clear, TTL, or LRU with a hard cap.

4. Move compose multi-photo preview to a disk-backed pipeline.
5. Keep only thumbnails in memory, store originals as temp files.

### Phase 2: Deeper Cleanup

1. Unify media caching and lifecycle hooks (background purge, size limits, eviction) into one module.
2. Add periodic memory-pressure handling to proactively trim.

## Acceptance Criteria

1. Repro scenario no longer triggers background termination on a typical test device.
2. Memory drops after background or memory warning (observable in VM Tracker).
3. Scrolling performance remains acceptable after adding retention windows and cache limits.

## Risks / Tradeoffs

1. Smaller caches can increase network usage and perceived load time.
2. Aggressive eviction can cause visible image reloads while scrolling; mitigate by tuning limits and using disk cache.
3. Sliding windows require careful correctness: go-to-message and pagination must still work (DB remains source of truth).

## Next Concrete Actions (Tomorrow)

1. Run the three Instruments scenarios and capture top allocations.
2. Implement Phase 0 Nuke cache config + lifecycle trimming.
3. Add message retention window in `FullChatProgressive` if it is a top retainer in the graph.

