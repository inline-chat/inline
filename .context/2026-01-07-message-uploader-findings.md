# Message uploader migration findings (2026-01-07)

## Current state (key files)
- Old v1 send with attachments lives in `apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift` (`TransactionSendMessage`). It uploads inside `execute()` via `FileUploader` and uses v1 `Transactions` retry loop.
- v2 send for text-only is `apple/InlineKit/Sources/InlineKit/Transactions2/SendMessageTransaction.swift` (RealtimeV2). No attachments and no upload.
- Upload engine is `apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift` (`FileUploader` actor). It does a single upload attempt, progress callbacks, DB update, and `waitForUpload`.
- Compose routes:
  - iOS: `apple/InlineIOS/Features/Compose/ComposeView.swift` uses v2 for text-only, v1 transaction for attachments.
  - macOS: `apple/InlineMac/Views/Compose/ComposeAppKit.swift` uses v2 for text-only, v1 transaction for attachments.
- UI hooks:
  - iOS document upload uses `NotificationCenter` notifications in `apple/InlineIOS/Features/Media/DocumentView.swift`.
  - macOS video cancel uses `FileUploader` + transaction cancel in `apple/InlineMac/Views/Message/Media/NewVideoView.swift`.
- Compose upload actions (`uploadingPhoto/Video/Document`) exist but are currently commented out in v1 send: `apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift`.

## Server/proto context
- `SendMessageInput` supports `InputMedia` (photo/video/document) in `proto/core.proto` and server handler expects IDs already uploaded (`server/src/functions/messages.sendMessage.ts`).
- REST v1 send (used by share extension) is separate: `apple/InlineShareExtension/ShareState.swift` uses `ApiClient.shared.sendMessage` and `uploadFile`.

## Findings summary
- Attachments currently depend on v1 transaction + `FileUploader` with retry via v1 `Transactions` loop.
- RealtimeV2 pipeline (transactions) does not support attachments or upload/prepare hooks.
- `FileUploader` has no retry/backoff; it is synchronous and in-memory only.
- Optimistic message insert is currently duplicated in v1 + v2 with different data (v1 includes photo/video/document IDs pre-upload in local DB via temp IDs).

## Proposed plan options

### Plan A — MessageUploader orchestrates uploads, then fires v2 send
- Add new `MessageUploader` actor (e.g. `apple/InlineKit/Sources/InlineKit/Files/MessageUploader.swift`).
- Wrap/extend `FileUploader` to do retry/backoff (attempts + retryable errors).
- Flow: optimistic insert -> upload -> on success send v2 `SendMessageTransaction` with `InputMedia` -> on failure mark message failed.
- Update compose to use `MessageUploader` for attachments.
- Update `SendMessageTransaction` to accept `media` and avoid double optimistic insert when message already exists.

### Plan B — Upload inside v2 transaction (prepare step)
- Extend RealtimeV2 `Transaction` protocol with async `prepare()` (default no-op).
- RealtimeV2 `runTransaction` calls `prepare()` before RPC send.
- `SendMessageTransaction` includes attachments and uploads in `prepare()` via `MessageUploader` (retry/backoff there), then constructs `InputMedia` for send.
- Keeps upload/send under a single transaction queue + persistence.

### Plan C — Protocol/server change for upload tokens
- Extend `SendMessageInput` to accept upload tokens (fileUniqueId) for photo/video/document.
- Client uploads first, then send message with token; server resolves token to media ID.
- Reduces client orchestration complexity, but requires proto + server changes and updates across clients.

## Open decisions / questions
- Should upload retry persist across app restarts? (Current v1 has disk persistence; v2 transactions expire after 10 min.)
- Keep NotificationCenter hooks for document upload or introduce typed progress publisher?
- Keep `FileUploader` as engine or replace it entirely with `MessageUploader`?
