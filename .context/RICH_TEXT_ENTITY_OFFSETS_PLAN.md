# Rich Text Markdown Stripping: Entity Offset Fix Plan (Apple compose)

## Context

Apple compose (iOS/macOS) calls `ProcessEntities.fromAttributedString(...)` in `apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift` to:

1) extract entities from attributed text (mentions, bold/italic font runs, code attrs), then
2) parse and strip markdown markers (`**`, `_`, `` ` ``, ``` ``` ```), while "compensating" entity `offset`/`length`.

## Problem Summary

Current "compensation" records the *total* number of removed marker characters at the *start* of each markdown match and subtracts it from every entity whose `offset` is after that start.

This is wrong for entities that start inside the match content (they should only shift by the opening marker length, not opening+closing). The same pattern exists for bold, italic, inline code, and pre blocks.

There is also inconsistent unit usage: `NSRange` is UTF-16 based, but parts of the code use Swift `String.count` (graphemes) when computing removed lengths and entity lengths.

## Desired Behavior

- Entity `offset`/`length` stays correct after markdown markers are removed.
- Entities that start inside a markdown span shift only by markers that are strictly before them.
- All entity math uses one unit consistently (decide and enforce; expected is UTF-16 code units to match `NSAttributedString` and `text.utf16.count` checks).

## Plan

### 1) Lock down index units (UTF-16)

- Confirm the canonical unit for `MessageEntity.offset`/`length` (expected UTF-16 code units).
- Update `ProcessEntities.fromAttributedString` enumeration ranges to use `attributedString.length` (UTF-16), not `text.count`.
- Replace any `String.count` usage in offset/length calculations with UTF-16 equivalents:
  - Prefer `NSRange.length` / `contentRange.length` when derived from regex matches.
  - Otherwise use `text.utf16.count`.

### 2) Replace "one adjustment per match" with "one adjustment per marker"

For each markdown match, record separate removals for the opening and closing markers (and any additional removed prefix such as ``` + optional language + newline):

- Bold `**content**`:
  - removal at `openPos = fullRange.location`, length 2
  - removal at `closePos = fullRange.location + fullRange.length - 2`, length 2
- Inline code `` `content` ``:
  - open at `fullRange.location`, length 1
  - close at `fullRange.location + fullRange.length - 1`, length 1
- Italic `_content_` (with whitespace capture groups):
  - open marker position computed relative to `contentRange.location - 1`, length 1
  - close marker at `contentRange.location + contentRange.length`, length 1
  - keep existing "leading whitespace preserved" behavior, but compute entity offsets using UTF-16 locations.
- Pre blocks ``` ```:
  - compute removed prefix length as `contentRange.location - fullRange.location`
  - compute removed suffix length as `(fullRange.location + fullRange.length) - (contentRange.location + contentRange.length)`
  - record two removals (prefix at `fullRange.location`, suffix at `contentRange.location + contentRange.length`).

Apply offset correction as:

- For each existing entity:
  - `offset -= sum(removal.length where removal.position < entity.offset)`

This naturally yields:

- entity inside span: subtract opening only
- entity after span: subtract opening + closing

### 3) Keep markdown-created entities correct

When creating new entities from markdown matches:

- Use UTF-16-based locations and lengths:
  - `offset = fullRange.location` (or content start, depending on type)
  - `length = contentRange.length`
- Ensure offsets are in the post-replacement coordinate system (processing matches in reverse still helps for string mutation).

### 4) Add regression tests (InlineUI)

Add targeted tests in `apple/InlineUI/Tests/InlineUITests/` to cover the failures seen in compose:

- Mention inside bold markers: `**@bob**` where mention is an attribute-based entity; after stripping, mention offset should shift by 2, not 4.
- Mention after a bold span: `**bold** @bob` where mention shifts by 4.
- Bold markers earlier should not corrupt later entities: `**a** b **c**` with an entity on `c`.
- Emoji + markdown (non-BMP) to enforce UTF-16 correctness.
- Nested exclusions: markdown inside code/pre should remain untouched except for the code/pre markers themselves.

### 5) Validate on Apple clients

- Run `cd apple/InlineUI && swift test` (fast, package-only).
- Smoke-test compose on iOS/macOS:
  - type `**bold @mention**` and ensure outgoing entities line up with rendered text after send
  - verify drafts save/restore keeps entity alignment.

## Notes / Non-goals (unless needed)

- De-duplicating "font-based bold entity" vs "markdown-parsed bold entity" is likely separate from the offset bug; only change if it is required to prevent incorrect rendering/sending.

