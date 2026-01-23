# AppKit Button Notes (Sidebar Action)

## Learnings
- NSButton brings default chrome (bezel/hover/pressed) that can fight custom styling; for minimal icon-only controls, a small NSView with an image subview is often cleaner.
- Always set `imageScaling` for symbol-only views (e.g. `.scaleProportionallyDown`) to avoid stretched glyphs.
- Keep the hit target square and center the symbol; size the symbol independent of the hit target for clarity.
- Drive hover/pressed state from a single tracking source (the row or container) to avoid flicker and double-tracking.
- Add accessibility explicitly when you build a custom control (role + label), since you do not get it for free.

## Pros / Cons

### NSButton
- Pros: built-in accessibility, focus/keyboard handling, standard pressed/highlight behavior.
- Cons: default bezel and state transitions can bleed through; image scaling and insets are harder to tame; can feel inconsistent with custom layouts.

### Custom NSView + NSImageView
- Pros: full visual control; predictable sizing; easier to match bespoke hover/pressed surfaces.
- Cons: you must implement accessibility and interaction states; no built-in keyboard activation unless you add it.
