# Message View Manual Layout Plan (iOS)

Goal: remove UIStackView usage in message cell + UIMessageView + bubble contents, and replace with manual constraint-based layout (updateConstraints-style) similar to macOS MessageView.

## Scope
- UIMessageView bubble layout (text, metadata, reply, attachments, media, reactions inside/outside).
- Child views used inside bubble: EmbedMessageView, DocumentView, MessageReactionView (reaction pill).
- Verify MessageCell has no UIStackView; adjust if needed.

## Plan
1) Inventory current stack-view usage and define a layout plan object for iOS (bubble size, content slots, top offsets, width caps, in/outgoing alignment) mirroring macOS layout fields.
2) Refactor UIMessageView:
   - Remove containerStack/singleLine/multiLine/mediaText/attachments stacks.
   - Add explicit subviews inside a single content container.
   - Create and store NSLayoutConstraints for each subview (top/leading/trailing/width/height).
   - Update constraints in `updateConstraints()` using a layout plan from current `Content`.
3) Implement reaction placement without stacks:
   - If reactions are inside bubble, pin below text/attachments within bubble content.
   - If reactions are outside, pin below bubble with bottom anchor changes.
   - Ensure constraints are mutually exclusive (activate/deactivate).
4) Refactor child views to remove UIStackView:
   - EmbedMessageView: manual layout for icon + label.
   - DocumentView: manual layout for icon + labels (title/size).
   - MessageReactionView: manual layout for emoji + count.
5) Validate bubble sizing:
   - Keep min width based on metadata (time/status) and padding.
   - Preserve max bubble width cap and outgoing/incoming alignment.
   - Ensure multi-line width stays fit (no full-width jump).
6) Clean up/verify:
   - Remove stack-view helper methods in UIMessageView+extensions.
   - Re-run message layout flows (single/multi/media/reactions), fix any constraint conflicts.

Notes
- Update the plan file after each step is completed before moving on.
- Avoid destructive resets; keep existing logic where possible, just swap layout mechanism.

## Progress
- Step 1 complete (inventory): UIStackView usage in UIMessageView (containerStack/singleLine/multiLine/mediaText/attachments), EmbedMessageView (messageStackView), DocumentView (horizontal/text/vertical stacks), MessageReactionView (emoji+avatars stack). MessageCell has no UIStackView. Reaction picker stack view is outside bubble scope.
- Step 2 complete: UIMessageView now uses a manual layout in `updateConstraints()` with `bubbleContentView` + `singleLineRowView`, and attachments use a custom `AttachmentsContainerView` (no UIStackView).
- Step 3 complete: reactions are placed inside/outside bubble via explicit constraints (no stack), with inside reactions keeping intrinsic width (trailing ≤).
- Step 4 complete: removed UIStackView from EmbedMessageView, DocumentView, and MessageReactionView (manual constraints + sizing).
- Step 5 complete: bubble sizing + multiline width logic preserved (text width uses metadata width; media-text insets handled).
- Step 6 complete: stack-view helpers removed from UIMessageView extensions; remaining stack usage only outside bubble.
