# AppKit avatar plan (future)

Goal: Replace SwiftUI avatar in macOS sidebar with a fully AppKit avatar view when needed.

Notes / constraints:
- Keep user cache behavior (User profiles are not real Photo objects yet).
- No chat photos support yet (match current ChatAvatar behavior).
- Use Kingfisher for image loading, with local cache first and downsample to target size.
- Avoid extra layout work: fixed size constraints and no preferredLayoutAttributesFitting.
- Avoid main-thread heavy work: precompute image options and reuse views/cells.

Suggested approach:
- Create a reusable NSView in InlineMacUI (e.g. `AppKitChatAvatarView`).
- Provide a minimal `update(peer:size:)` API and `prepareForReuse()`.
- Use a single NSImageView + optional overlay (emoji/initials/symbol) layers.
- For initials, consider embedding the existing SwiftUI `InitialsCircle` via NSHostingView if text metrics are hard to match in AppKit.

Perf instrumentation (if needed):
- Keep one `ChatNavigation` signpost in Nav2 with end in ChatViewAppKit.
- Add temporary `SidebarSnapshot` signposts only while profiling; remove afterward.

Checklist for rollout:
- Add Kingfisher dependency to InlineMacUI.
- Ensure cache key matches user profile file id (or user id fallback).
- Validate avatar rendering at all sidebar sizes (compact/regular).
- Run `swift build` in `apple/InlineMacUI` after changes.
