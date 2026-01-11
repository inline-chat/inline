# External Task Attachment Layout Analysis (macOS + iOS)

Date: 2026-01-06

## Context
Reports of layout issues for “will do” (external task message attachment) in message view cells on macOS and iOS. Analysis focused on view setup, constraints, layout properties, updating/removal, and reuse.

## macOS (AppKit)

### View Setup
- `MessageViewAppKit` creates `MessageAttachmentsView` and inserts it into the message content view.
  - `apple/InlineMac/Views/Message/MessageView.swift`
- `MessageAttachmentsView` (vertical `NSStackView`) creates `ExternalTaskAttachmentView` for external tasks.
  - `apple/InlineMac/Views/Message/Attachments/MessageAttachmentsView.swift`
- `ExternalTaskAttachmentView` uses internal `NSStackView`s for first/second lines, `NSTextField`s for labels.
  - `apple/InlineMac/Views/Message/Attachments/ExternalTaskAttachmentView.swift`

### Constraints / Layout Details
- `MessageAttachmentsView` has `alignment = .leading` and does **not** constrain arranged subviews to fill width.
- `ExternalTaskAttachmentView`:
  - Only a **minimum height** constraint (`heightAnchor >= Theme.externalTaskViewHeight`).
  - No explicit **width** constraint.
  - Internal `contentStackView` uses `trailing <=` constraint (not equal).
- Text labels (`NSTextField`) are 1 line, truncating, but **not width-constrained**, so intrinsic width can exceed expected bubble width.

### Update / Reuse Behavior
- `MessageViewAppKit.updateTextAndSize` refreshes attachments and sets `needsUpdateConstraints = true`, but:
- `MessageAttachmentsView.configure(...)` **short-circuits** when attachment IDs are unchanged. If only attachment content (title/userInfo) changes, the view does not reconfigure.

### Likely Root Cause (macOS)
1. Attachment view is **not width-constrained** in a `.leading` stack, so the view’s intrinsic width can expand beyond the bubble width calculated by `MessageSizeCalculator`.
2. If attachment content changes without ID changes, **configure short-circuit prevents layout refresh**, leaving stale sizes.

Net effect: external task attachment can overflow bubble bounds or clip in message cells.

## iOS (UIKit)

### View Setup
- `MessageAttachmentEmbed` is used for external tasks in `UIMessageView.setupMultilineMessage`.
  - `apple/InlineIOS/Features/Message/UIMessageView.swift`
  - `apple/InlineIOS/Features/Message/MessageAttachmentEmbed.swift`

### Constraints / Layout Details
- `taskTitleLabel` has `numberOfLines = 0` (multi-line) but is constrained with:
  - `centerY` to checkbox (not top aligned).
  - `bottom <=` to container (not equal).
  - trailing is `<=` (not equal).
- This creates an **unstable vertical layout** for a multi-line label: it expands around a center line and can collide with the first line or under-report height.

### Update / Reuse Behavior
- `MessageCollectionViewCell` recreates `UIMessageView` per configure, so reuse is not the primary issue here.

### Likely Root Cause (iOS)
- The multi-line `taskTitleLabel` is **center-aligned vertically** with the checkbox; there’s no top/bottom pinning to establish a stable height. This causes overlapping/clipping when titles are long or dynamic type changes.

## Root Cause Summary
- **macOS:** `ExternalTaskAttachmentView` is not width-constrained inside a `.leading` stack view; label intrinsic sizes can expand beyond the expected bubble width. The configure short-circuit can also prevent relayout after content changes.
- **iOS:** Multi-line task title is constrained by `centerY` instead of top/bottom anchors, leading to ambiguous height and clipping/overlap.

## Files Referenced
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/Attachments/MessageAttachmentsView.swift`
- `apple/InlineMac/Views/Message/Attachments/ExternalTaskAttachmentView.swift`
- `apple/InlineMacUI/Sources/MacTheme/Theme.swift`
- `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`
- `apple/InlineIOS/Features/Message/UIMessageView.swift`
- `apple/InlineIOS/Features/Message/MessageAttachmentEmbed.swift`
- `apple/InlineIOS/Features/Chat/MessageCell.swift`
