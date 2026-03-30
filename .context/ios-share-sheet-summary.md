# iOS Share Sheet Fix Summary

## Goal
- Fix share extension issues where file shares sent `file://` URLs instead of actual files.
- Preserve text + URL + caption reliably.
- Raise max supported media/file items to 10.

## What Changed
- Replaced the single `SharedContentType` enum with an aggregated `SharedContent` model that can hold images, files, URLs, and text together.
- Added a thread-safe `SharedContentAccumulator` to merge data from multiple `NSItemProvider` callbacks without losing content.
- Updated share parsing to:
  - Prefer file handling (movies/files/data) over URL handling.
  - Treat `file://` URLs as files, not text links.
  - Accept both `UTType.text` and `UTType.plainText`, and handle `String`, `NSAttributedString`, and UTF-8 `Data`.
  - Capture attributed text from `NSExtensionItem`.
- Implemented safe file handling:
  - Security-scoped access and copying to a temp file.
  - Temporary file creation for raw `Data`.
- Updated send flow to:
  - Upload multiple images/files (up to 10).
  - Combine caption + shared text + URLs into a single message attached to the first media item.
  - Send text-only shares when no media exists.
- Increased max limits in `InlineShareExtension/Info.plist` for images, files, and movies to 10.

## Files Touched
- `apple/InlineShareExtension/ShareState.swift`
- `apple/InlineShareExtension/ShareView.swift`
- `apple/InlineShareExtension/Info.plist`

## Notes / Follow-ups
- UI still uses a fixed empty caption string; if a share UI caption field is desired, add input to `ShareView` and pass it into `sendMessage`.
- Consider surfacing user-facing warnings when attachments exceed max limits (currently logged only).
