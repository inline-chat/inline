# Rich Text Entity Checklist (End-to-End)

Use this checklist when adding a new rich text entity (email, phone, etc.) across protocol, server, and clients.

## 1) Protocol / Shared Schema
- [ ] Add enum value to `MessageEntity.Type` in `proto/core.proto`.
- [ ] If the entity needs extra data, add a new `message MessageEntityX` and include it in the `oneof entity`.
- [ ] Regenerate protos: `bun run generate:proto` (and any per-language generators, e.g. `bun run proto:generate-swift`).
- [ ] Confirm generated code exists in:
  - `server/packages/protocol/src/core.ts`
  - `web/packages/protocol/src/core.ts`
  - `apple/InlineKit/Sources/InlineProtocol/core.pb.swift`

## 2) Server: Markdown / Text Processing
- [ ] Add detection in `server/src/modules/message/parseMarkdown.ts` (or other server entity pipeline).
  - [ ] Ensure priority ordering (e.g. do not detect inside code blocks).
  - [ ] Avoid overlapping with existing entities.
- [ ] Update `server/src/modules/message/processText.ts` only if new logic is needed beyond parseMarkdown.
- [ ] Add/extend tests in `server/src/modules/message/processText.test.ts` for:
  - [ ] Basic detection
  - [ ] Overlap/precedence with code blocks or other entities
  - [ ] Offsets/length correctness

## 3) Apple Shared Text Processing
- [ ] Add an `NSAttributedString.Key` for the entity in `apple/InlineKit/Sources/InlineKit/RichTextHelpers/AttributedStringHelpers.swift` if needed.
- [ ] Render entity in `apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift`:
  - [ ] Apply link/color attributes as appropriate.
  - [ ] If it should not open a native link, store custom attribute instead of `.link`.
- [ ] Extract entity in `ProcessEntities.fromAttributedString`:
  - [ ] Read the custom attribute (preferred) and emit entity.
  - [ ] If native `.link` can appear (e.g. mailto), convert it to the custom attribute/entity.
- [ ] Add parsing from plain text if needed (regex or detector), and ensure:
  - [ ] Not inside code blocks
  - [ ] No overlap with existing entities
  - [ ] Offsets are correct after markdown removals
- [ ] Update allowed scheme rules if native schemes should be blocked.

## 4) Apple Clients (iOS/macOS)
- [ ] Disable native data detectors where they would interfere:
  - [ ] iOS compose `UITextView.dataDetectorTypes = []`
  - [ ] macOS: strip unwanted link attributes in `ComposeTextView` if AppKit inserts them
- [ ] Message views: handle tap/click for the entity:
  - [ ] iOS: in `UIMessageView.handleTextViewTap`, check the custom attribute first
  - [ ] macOS: add click handler in `MessageViewAppKit` to read custom attribute
- [ ] Implement action (e.g. copy to clipboard, show toast, or open in-app view).

## 5) Web Client (if message rendering exists)
- [ ] Update any message rendering pipeline to style the entity.
- [ ] Ensure clicks perform the correct action (copy, open, etc.) and suppress native link behavior if needed.

## 6) Tests
- [ ] InlineUI tests in `apple/InlineUI/Tests/InlineUITests/ProcessEntitiesTests.swift`:
  - [ ] Rendering attributes
  - [ ] Extraction from attributes
  - [ ] Detection from plain text if applicable
- [ ] Server tests (see step 2).
- [ ] Optional: add UI-level tests if a framework exists.

## 7) Sanity Checks
- [ ] Verify offsets are in UTF-16 indices (same as existing entities).
- [ ] Ensure entity does not overlap code/pre blocks.
- [ ] Ensure custom attribute is not treated as a native `.link` unless intended.
- [ ] Confirm entity is preserved through compose -> send -> render -> copy.
