# Core Text Message Renderer Feasibility

Date: 2026-03-08

## Question

How hard would it be to replace Inline bubble message text rendering with a custom Core Text renderer similar to Telegram's macOS client, instead of relying on TextKit-backed text views?

## Short Answer

For Inline as it exists today:

- iOS: medium
- macOS: hard

This is not a small swap. The shared attributed-string pipeline can stay, but the rendering, hit-testing, selection, and sizing layers would need real work.

## Current Inline Rendering Stack

### Shared attributed-string generation

We already have a reusable entity-to-attributed-string pipeline:

- `apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift`

`ProcessEntities.toAttributedString(...)` already applies fonts, colors, links, mentions, inline code, code blocks, and related attributes. That part is compatible with a future custom renderer.

### iOS bubble text

iOS bubble text currently uses a `UITextView` subclass:

- `apple/InlineIOS/Features/Message/UIMessageView+extensions.swift`
- `createMessageLabel() -> UITextView`
- concrete type: `CodeBlockTextView`

`CodeBlockTextView` already custom-draws code block backgrounds, but still depends on TextKit geometry:

- `apple/InlineIOS/Features/Message/CodeBlockTextView.swift`
- uses `layoutManager`, `textContainer`, `glyphRange`, `boundingRect`, and `enumerateLineFragments`

Bubble interactions also depend on TextKit geometry:

- `apple/InlineIOS/Features/Message/UIMessageView.swift`
- link / mention / inline-code tap handling
- long-press link rect calculation
- character and glyph hit-testing through `layoutManager`

iOS sizing is also not unified around a custom renderer today:

- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- message height currently uses plain string `boundingRect(...)`

### macOS bubble text

macOS bubble text currently uses a selectable `NSTextView`, with TextKit 2 as the default path:

- `apple/InlineMac/Views/Message/MessageView.swift`
- `useTextKit2: Bool = true`
- `MessageTextView(usingTextLayoutManager: true)`

There is also a TextKit 1 fallback path in the same file.

macOS relies on native text view behavior for:

- selection
- native copy behavior
- context menus
- look up / translate menu items
- viewport layout behavior

Relevant files:

- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MessageTextView.swift`

macOS message sizing already uses Core Text:

- `apple/InlineMac/Views/MessageList/MessageSizeCalculator.swift`
- `CTFramesetterCreateWithAttributedString`
- `CTFramesetterSuggestFrameSizeWithConstraints`

That helps for layout parity, but rendering and interaction are still TextKit-backed.

## What a Core Text Renderer Would Need to Replace

### iOS

To replace the current `UITextView` bubble renderer, we would need to implement:

- line breaking and layout
- text measurement
- link hit-testing
- mention hit-testing
- inline code hit-testing
- code block rect calculation
- long-press target rects for menus
- caching and invalidation
- accessibility behavior

Important nuance: iOS bubble text is already non-editable and non-selectable, so we are not fighting the full native text-editor surface. That makes iOS materially easier than macOS.

### macOS

To replace the current `NSTextView` bubble renderer, we would need to implement:

- line breaking and layout
- text measurement
- selection
- copy selected text
- link hit-testing
- cursor and hover behavior
- context menus
- look up / translate behavior parity if desired
- accessibility
- scroll / viewport invalidation behavior

The macOS cost is much higher because the current implementation uses native selectable text behavior rather than just passive display.

## Rough Effort Estimate

### iOS

- prototype for message text only, non-selectable: a few days
- production-ready parity with current links / mentions / code-block behavior: about 1 to 2 weeks

### macOS

- full parity replacement for current selectable message text: about 2 to 4 weeks

### Both platforms together

- likely several weeks once edge cases, regressions, and polish are included

## Recommendation

Do not replace TextKit wholesale unless we have a measured problem that justifies it.

The current codebase already uses a hybrid model:

- shared attributed-string generation
- TextKit-backed text views for layout / geometry
- custom drawing for code backgrounds and related decorations

That is much cheaper to evolve than a full Telegram-style custom Core Text renderer.

If we want to explore this anyway, the best order is:

1. Prototype it on iOS only.
2. Scope it to passive bubble text only.
3. Reuse `ProcessEntities.toAttributedString(...)`.
4. Keep macOS on `NSTextView` for now.

## Why This Is Still Interesting

Even if we do not fully replace TextKit, Telegram's approach is useful as a design reference for:

- tighter renderer control
- custom block / spoiler / embedded item drawing
- avoiding text view overhead in long message lists
- shared layout and draw caches

That makes it a good direction only if profiling shows message-list text rendering is a real hotspot or TextKit keeps blocking a needed feature.
