# Inline Code Background (macOS)

Goal: add a 2px padded, 3px radius background behind inline code in the macOS message view (TextKit 2).

Attempts:
- Custom `NSTextLayoutFragment` drawing via `NSTextLayoutManagerDelegate` (InlineCodeTextLayoutFragment). Initial render worked, but backgrounds disappeared after text selection/click.
- View-level drawing in `MessageTextView.draw(_:)` using `enumerateTextSegments` and `.destinationOver` to paint behind text. Rendering was unreliable and still vanished on interaction.
- Added debug overlays/logging to confirm draw paths; fragment draw ran (green overlay) but still got cleared on selection.

Outcome: reverted changes; no reliable background rendering in the current TextKit 2 setup.

Possible next steps:
- Use TextKit 1 with a custom `NSLayoutManager.drawBackground(...)`.
- Maintain a separate overlay layer/view driven by layout manager segment enumeration, updated on selection/layout changes.
