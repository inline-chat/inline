# macOS Document Upload Progress Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add circular upload progress with centered cancel for pending outgoing document messages on macOS, while leaving compose attachments and normal document download UI unchanged.

**Architecture:** Keep document upload state handling inside `DocumentView`, add a small reusable circular ring primitive extracted from `NewVideoView`, and extend `FileUploader` with a document-specific cancel helper. Drive the feature from pending message state plus `FileUploader` progress publishers, and mirror video cancel semantics for transaction/message cleanup.

**Tech Stack:** Swift, AppKit, Combine, GRDB, Swift Testing

---

## Chunk 1: InlineKit upload helpers

### Task 1: Add failing tests for document upload cancellation

**Files:**
- Modify: `apple/InlineKit/Tests/InlineKitTests/FileUploadProgressTests.swift`
- Modify: `apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift`

- [ ] **Step 1: Write the failing test**

Add tests that exercise a document-specific cancel entry point and any extracted helper used to classify pending document upload state.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apple/InlineKit --filter FileUploadProgressTests`
Expected: FAIL because the new document cancel API and/or helper does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add `cancelDocumentUpload(documentLocalId:)` and any small helper needed by the tests.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apple/InlineKit --filter FileUploadProgressTests`
Expected: PASS

## Chunk 2: Shared circular ring primitive

### Task 2: Extract the ring drawing view from video UI

**Files:**
- Modify: `apple/InlineMac/Views/Message/Media/NewVideoView.swift`

- [ ] **Step 1: Write the failing test**

No practical isolated UI test exists here. Keep this extraction behavior-preserving and verify through targeted build plus existing view behavior.

- [ ] **Step 2: Implement minimal extraction**

Move the circular progress ring drawing/animation primitive into a small reusable type that still allows caller-owned sizing and layout. Keep video dimensions and button layout unchanged.

- [ ] **Step 3: Run targeted verification**

Run: `swift build --package-path apple/InlineKit`
Expected: PASS for shared package code still used by macOS build graph.

## Chunk 3: DocumentView upload state and cancel UI

### Task 3: Add pending-upload state resolution and bindings

**Files:**
- Modify: `apple/InlineMac/Views/DocumentView/DocumentView.swift`

- [ ] **Step 1: Add a small testable helper if needed**

If state resolution is extracted into a helper or static function, cover the case where a sending document message with `localPath` must still resolve to upload state.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apple/InlineKit --filter FileUploadProgressTests`
Expected: FAIL if a new helper-backed test was added.

- [ ] **Step 3: Implement minimal upload state support**

Extend `DocumentState` with upload processing/uploading states, add upload subscriptions, and prioritize pending outgoing upload state over `localPath`-based availability.

- [ ] **Step 4: Implement circular control UI**

Use the extracted ring primitive inside `DocumentView`, with document-owned dimensions, stroke, tint, and centered `X` layout. Keep download UI behavior unchanged.

- [ ] **Step 5: Implement cancel semantics**

When the centered `X` is tapped for a pending upload:
- cancel the document upload
- cancel the send transaction by `transactionId` or `randomId`
- delete the local pending message row

- [ ] **Step 6: Run tests/builds to verify**

Run: `swift test --package-path apple/InlineKit --filter FileUploadProgressTests`
Expected: PASS

## Chunk 4: Focused verification

### Task 4: Run fresh verification

**Files:**
- Modify: `apple/InlineMac/Views/DocumentView/DocumentView.swift`
- Modify: `apple/InlineMac/Views/Message/Media/NewVideoView.swift`
- Modify: `apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift`
- Modify: `apple/InlineKit/Tests/InlineKitTests/FileUploadProgressTests.swift`

- [ ] **Step 1: Run focused InlineKit tests**

Run: `swift test --package-path apple/InlineKit --filter FileUploadProgressTests`
Expected: PASS

- [ ] **Step 2: Run focused package build**

Run: `swift build --package-path apple/InlineKit`
Expected: PASS

- [ ] **Step 3: Review diff for unintended changes**

Run: `git diff -- apple/InlineMac/Views/DocumentView/DocumentView.swift apple/InlineMac/Views/Message/Media/NewVideoView.swift apple/InlineKit/Sources/InlineKit/Files/FileUpload.swift apple/InlineKit/Tests/InlineKitTests/FileUploadProgressTests.swift`
Expected: Only the upload progress and cancel changes needed for this feature.
