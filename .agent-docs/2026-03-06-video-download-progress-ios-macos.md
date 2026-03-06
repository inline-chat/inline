# Video Download Progress for iOS and macOS

## Context
- Add visible inline download progress for message videos.
- Start with the existing iOS `NewVideoView`, then align macOS `NewVideoView`.
- Reuse `FileDownloader` progress publishers instead of adding a new transfer layer.
- Follow-up: match the macOS ring styling to iOS and remove the iOS post-download flicker before the play state appears.

## Plan
1. iOS
- Surface active video download progress in the existing video badge text.
- Preserve the current circular overlay progress and cancel behavior.
- Keep the badge fallback to duration when there is no active transfer.

2. macOS
- Replace the indeterminate download spinner treatment with determinate progress.
- Surface the same download progress text in the existing duration badge.
- Reuse the same cancel path and existing downloader publisher.

3. Validation
- Run focused Swift builds for the touched Apple targets/packages.
- Review the final diff for reuse, cancellation, and view update regressions.

## Follow-up
- iOS: keep the download UI alive until the local cache path is resolvable, including a DB fallback when the message model lags.
- macOS: make the determinate progress ring visually match the iOS transfer ring behavior.
