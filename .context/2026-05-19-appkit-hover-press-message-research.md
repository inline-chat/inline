# AppKit Hover And Press Notes For Message Views

## Sources

- Apple `NSTrackingArea` docs via sosumi.ai: tracking areas belong to the view, can emit enter, exit, moved, and cursor events, and `updateTrackingAreas()` is the intended place to recompute them when visible geometry changes.
- Telegram macOS local source:
  - `/Users/mo/dev/telegram/TelegramSwift/packages/TGUIKit/Sources/Control.swift`
  - `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/AvatarLayer.swift`
  - `/Users/mo/dev/telegram/TelegramSwift/packages/TGUIKit/Sources/TableRowView.swift`

## Findings

- For hover, prefer one stable tracking area on the interactive view using `.mouseEnteredAndExited`, `.mouseMoved`, an active mode, and `.inVisibleRect`. Telegram's reusable `Control` uses that shape and updates state from `mouseMoved`, `mouseEntered`, and `mouseExited`.
- Avoid tracking an animating or constraint-driven subrect directly. A subrect tracking area can become stale during reuse/layout, and AppKit does not necessarily synthesize a fresh enter event when the rect moves under the cursor.
- If the visual hover target is smaller than the row, track the row's visible rect but compute hover state from the actual target frame on every mouse event. This keeps the hit area exact without re-registering tracking areas for every constraint change.
- For press/click, the pressed state should be owned by the clickable control. Telegram's controls keep hover/highlight/down/up state inside the control rather than combining a gesture recognizer with a separate view's mouse handling.
- Gesture recognizers layered on simple `NSView` avatars can conflict with `mouseDown`-based press feedback. A small manual AppKit control loop is more predictable: set pressed on mouse down, update pressed while dragging in/out, and fire the action on mouse up only when still inside.
- For `NSButton`-backed reaction pills, use AppKit's control highlight lifecycle instead of wrapping `mouseDown`; `NSButton` already tracks the down/up/cancel path and calls highlight transitions during tracking.

## Chosen Approach

- Minimal message rows will keep a single visible-rect tracking area and derive row hover from `hoverBackgroundView.frame.contains(point)`.
- Avatar clicks will move into `UserAvatarView` as a narrow `onClick` callback with local press tracking, so both bubble and minimal callers stop layering a click recognizer on top of avatar mouse handling.
- Reaction pills will use `highlight(_:)` for the scale effect, leaving the button's own event tracking intact.
