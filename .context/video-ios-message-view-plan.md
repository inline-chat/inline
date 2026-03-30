# Video Rendering on iOS – Message View Plan

## Context
- Add inline video rendering for iOS messages.
- Align with existing media patterns (photo/document) and macOS video behavior.
- Use InlineKit file caching and download/upload flows.

## Plan
1. Create an iOS `NewVideoView` in `apple/InlineIOS/Features/Media/` that:
   - Shows the video thumbnail when available.
   - Renders an overlay state (play, download, spinner) based on local file + download/upload state.
   - Downloads via `FileDownloader` and stores via `FileCache`.
   - Opens the video on tap (e.g., `AVPlayerViewController`).

2. Integrate video into `UIMessageView`:
   - Add a `videoView` property and `setupVideoViewIfNeeded()`.
   - Include video in multiline/message layout decisions and metadata placement.
   - Keep interaction and layout consistent with photo/document handling.

3. Remove “unsupported” treatment for video in UI:
   - Add `Message.hasVideo` and adjust `hasUnsupportedTypes` logic.
   - Update `EmbedMessageView`, `ComposeEmbedViewContent`, and `ChatItemView` to show a video icon + label.

4. Add `PlatformPhotoView` in `InlineUI`:
   - Provide a UIKit/AppKit view with a shimmering placeholder.
   - Load from `FileCache` local paths using Kingfisher.
   - Render immediately when local files exist (avoid flicker).

5. Swap iOS video thumbnail rendering to use `PlatformPhotoView`.

6. Sanity checks:
   - Build/compile affected targets where feasible (avoid full app builds).
   - Note manual QA for playback, download, and mixed text+video messages.

## Status
- [ ] Not started
- [x] In progress
- [ ] Done

## Progress
- [x] Step 1: iOS NewVideoView with thumbnail + overlay + playback
- [x] Step 2: UIMessageView integration + layout updates
- [x] Step 3: UI updates to treat video as supported
- [x] Step 4: PlatformPhotoView in InlineUI
- [x] Step 5: iOS video thumbnail uses PlatformPhotoView
- [ ] Step 6: Sanity checks / manual QA
