# macOS: Fix Avatar + Media Flicker (2026-02-07)

From notes (Feb 3-7, 2026): "photos flicker on macOS, profile photos flicker", "flicker on video and photo".

## Symptoms

1. Profile avatars flicker or show placeholders during list refresh and scrolling.
2. Photo/video thumbnails in messages repeatedly fade from placeholder to image while scrolling or when cells update.

## Root Causes (High Confidence)

### A. Profile photo flicker

1. Avatar view identity depends on `remoteUrl` changes.
2. Remote URLs appear to churn (likely signed URLs), so the view resets frequently.
3. Local avatar cache is not used as the primary source, so remote fetch is repeated.

Files:
- `apple/InlineUI/Sources/InlineUI/UserAvatar.swift`
- `apple/InlineKit/Sources/InlineKit/Models/User.swift`

### B. AppKit <-> SwiftUI bridge rebuilding

1. `MessageAvatarView.updateAvatar()` removes and recreates a `NSHostingView` instead of updating `rootView`.
2. Rebuilding hosting views during table updates can cause transient blank frames.

Files:
- `apple/InlineMac/Views/Message/MessageAvatarView.swift`

### C. Photo/video thumbnail flicker

1. `ImageCacheManager` has disk path and sync load API but does not persist to disk, so sync loads only hit memory.
2. `NewPhotoView` resets to a loading state on refresh and animates image transitions, which reads as flicker on reuse.
3. `NewVideoView` is defensive but still depends on the same cache behavior.
4. There are multiple image loading implementations (Nuke-based `PhotoView` vs custom `ImageCacheManager` in `NewPhotoView`), creating inconsistent caching behavior.

Files:
- `apple/InlineMac/Views/ImageCache/ImageCacheManager.swift`
- `apple/InlineMac/Views/Message/Media/NewPhotoView.swift`
- `apple/InlineMac/Views/Message/Media/NewVideoView.swift`
- `apple/InlineMac/Views/Message/Media/PhotoView.swift`

## Goals

1. No placeholder flashes for avatars while scrolling or when user info refreshes.
2. No repeated fade-in animations for already-loaded media while scrolling.
3. Stable cache keys so identical logical images reuse cached bytes even if URL query changes.
4. Avoid large refactors in the first pass; keep changes contained to image loading and view identity.

## Non-Goals

1. Full media pipeline rewrite across every client.
2. Perfect offline avatar/media behavior (but do not regress it).

## Plan (Recommended)

### Phase 1: Avatars (Stop URL-Churn Flicker)

1. Introduce a stable avatar cache key.
2. Key candidates:
3. `profileFileUniqueId` if it exists and changes when the avatar changes.
4. `profilePhoto.id` if it is versioned per new photo.
5. Use this key for:
6. SwiftUI view identity (Equatable) to prevent re-render thrash.
7. Image cache key (so signed URL changes do not invalidate the cache).

8. Prefer local file URL first using the profile photo file record.
9. `userInfo.profilePhoto?.first?.getLocalURL()` should be the primary local source if available.
10. Only fall back to remote if local is missing.

Touchpoints:
- `apple/InlineUI/Sources/InlineUI/UserAvatar.swift`
- `apple/InlineKit/Sources/InlineKit/Models/User.swift`

Tradeoff:
1. Stable keys must update when avatar changes, or we risk serving stale images.
2. Using fileUniqueId/photo.id mitigates staleness because a new avatar should produce a new key.

### Phase 2: AppKit Bridge (Stop Blank Frames)

1. Change AppKit avatar container views to reuse `NSHostingView` and update `rootView`.
2. Do not remove/add hosting subviews during updates.
3. Ensure layer rasterization scale is updated on backing scale changes if rasterization is used.

Touchpoints:
- `apple/InlineMac/Views/Message/MessageAvatarView.swift`
- `apple/InlineMac/Views/ChatIcon/ChatIconView.swift`
- `apple/InlineMac/Views/ChatIcon/SidebarChatIconView.swift`

### Phase 3: Thumbnails (Stop Placeholder + Fade Loop)

Pick one of these two approaches.

Option A (Recommended): unify on Nuke for `NewPhotoView` and `NewVideoView`.
1. Use a single image pipeline with memory + disk cache.
2. Use stable request/cache keys based on file unique IDs, not raw signed URLs.
3. Keep the existing `PhotoView` approach as the reference.

Option B: make `ImageCacheManager` real.
1. Implement disk writes so `loadSync` can hit disk.
2. Add eviction policy (size limit, TTL, or LRU).
3. Ensure file paths are stable (unique ID based).

### Phase 4: Animation Hygiene (Perceived Flicker)

1. `NewPhotoView` should not reset to placeholder if the same image is already displayed.
2. Only animate when transitioning from "no image" to "image", not on every update.
3. During scroll-driven updates, prefer "keep current bitmap while loading next".

Touchpoints:
- `apple/InlineMac/Views/Message/Media/NewPhotoView.swift`
- `apple/InlineMac/Views/Message/Media/NewVideoView.swift`

## Validation Checklist

1. Scroll a long media-heavy chat: thumbnails should not flash placeholders repeatedly.
2. Reload sidebar/home: avatars should not flicker if the same users are still present.
3. Change a user avatar: the new avatar should appear (stable key must rotate).
4. Verify disk cache size stays bounded if disk caching is enabled.

## Acceptance Criteria

1. Avatars remain stable under frequent user info updates (no placeholder flash).
2. Thumbnails do not fade-in repeatedly during scroll once cached.
3. No significant regression in CPU usage while scrolling.

## Open Questions

1. Are avatar/media URLs actually signed/ephemeral today, or do they change due to a separate bug? The fix above covers both.
2. Should we standardize on Nuke everywhere on macOS for images, or keep custom cache for specific cases?

