# macOS: “Save failed” Should Wait For Media To Load (2026-02-07)

From notes (Feb 3, 2026): "\"save failed\" -> wait for it to load".

Most likely user-facing interpretation: when saving an image/video/document from a message, we shouldn’t error just because the media is still downloading or not yet decoded.

## Goals

1. “Save…” works reliably even if the media is not fully loaded yet.
2. The UI communicates “Downloading…” or “Preparing…” instead of “Failed”.
3. Avoid duplicating download work (reuse existing file cache/download pipeline).

## Current State (Observed)

1. `NewPhotoView.saveImage()` fails early if `currentImage == nil`.
2. Later it checks `imageLocalUrl()` and errors with “Image isn’t downloaded yet”.
3. `NewVideoView.saveVideo()` already has a download-on-save path, but it uses a modal confirmation (“Download video to save?”).
4. `MessageView.saveDocument()` fails if `document.localPath` is nil or the file is missing and does not start a download.

Key file:
- `apple/InlineMac/Views/Message/Media/NewPhotoView.swift`

Similar patterns exist for:
1. Video save actions.
2. Document/file save actions.

Additional touchpoints:
1. Video: `apple/InlineMac/Views/Message/Media/NewVideoView.swift`
2. Document: `apple/InlineMac/Views/Message/MessageView.swift`
3. Document download UI: `apple/InlineMac/Views/DocumentView/DocumentView.swift`
4. Downloads and progress publishers: `apple/InlineKit/Sources/InlineKit/Files/FileDownload.swift`
5. File cache helpers: `apple/InlineKit/Sources/InlineKit/Files/FileCache.swift`

## UX Spec

When the user selects “Save…”:
1. If the media is already available locally, show save panel immediately and save.
2. If it is not available locally, the app should not error immediately.
3. Show the save panel immediately (recommended) and store the chosen destination.
4. Start (or attach to) download.
5. Show a non-error toast: “Downloading to save…” (optional progress, optional Cancel).
6. Once available, copy the local file to the chosen destination and show success.
7. If download fails, then show an error.

Alternative:
1. Wait to show save panel until download completes. This is “pure” but feels slower; prefer save panel first.

## Implementation Approaches

### Option A (Recommended): Save uses local file URL only

1. For save-to-disk, we do not need `currentImage` at all.
2. We only need a stable local file URL from the file cache.
3. So, change save to:
4. Ensure file is downloaded -> get local URL -> save panel -> copy file.

Pros:
1. Works even if the image isn’t decoded yet.
2. Less memory pressure.

Cons:
1. Requires a reliable “ensure downloaded” API.

### Option B: Save decoded image fallback

If the media is not cached as a file (rare), fall back to encoding `currentImage` and writing bytes.

Pros:
1. More robust for “in-memory only” images.

Cons:
1. Can be memory heavy.

## Concrete Plan

### Phase 1: Photo

1. Refactor `saveImage` to not gate on `currentImage`.
2. Add a helper:
3. `ensurePhotoDownloaded() async throws -> URL`
4. That returns the local file URL.

3. If local URL is missing:
4. Trigger the existing download pipeline and await completion.
5. Then continue to save panel flow.

Download coordination notes:
1. Prefer awaiting a single download per file unique id.
2. If there is an existing `waitForDownload(photoId:)` helper in `FileCache`, reuse it.

### Phase 2: Video and Document

1. Implement the same “ensure downloaded -> save” flow for:
2. `NewVideoView` save:
3. Remove the modal “Download video to save?” confirmation and just do the same queued flow.
4. Document/file attachment save in `MessageView`:
5. Reuse the same download mechanism `DocumentView` uses, but triggered from Save.

Optional shared coordinator:
1. Add a small `MediaSaveCoordinator` that tracks pending save requests keyed by file unique id.
2. This prevents duplicate downloads and lets multiple views reuse the same queued save logic.

### Phase 3: UI polish

1. Disable “Save…” menu item while a download is in progress for that media item (optional).
2. If a save is requested during download, coalesce requests so we only save once.

## Edge Cases

1. User cancels the save panel while download is still happening:
2. Option: cancel download if it was started solely for this save action.
3. Or let download complete for cache reuse (simpler).

2. Multiple save requests:
3. Deduplicate by file unique id.

## Testing Checklist

1. Save image while it is still loading: should download then allow save.
2. Save image after it is loaded: immediate.
3. Save video while loading: same behavior.
4. Simulate download failure: show error only after failure.

## Acceptance Criteria

1. “Save failed” no longer appears for the common case of “not downloaded yet”.
2. Save always succeeds after download unless the user cancels the panel.
