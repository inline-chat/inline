# iOS Keyboard Polish Follow-Up

Date: 2026-06-10

## Context

The current iOS chat keyboard/compose work is intentionally parked at a safer midpoint. The bounce during some interactive/back-swipe dismiss paths is not the priority right now; keeping chat scroll, compose placement, tap dismissal, and keyboard open/close stable is more important.

Current touched areas:

- `apple/InlineIOS/Features/Chat/ChatViewUIKit.swift`
- `apple/InlineIOS/Features/Chat/MessagesCollectionView.swift`
- `apple/InlineIOS/Features/Compose/ComposeTextView.swift`
- `apple/InlineIOS/Features/Chat/KeyboardTrace.swift`

## Current Stable Direction

- `ChatContainerView` is the single owner of keyboard frame notifications.
- `MessagesCollectionView` no longer observes keyboard show/hide directly.
- A minimal collection-view pan bridge is active so compose follows interactive dismiss.
- No keyboard-path `contentOffset` compensation should be added without strong device evidence.
- No forced first-responder/editability hacks should be added for swipe-back or interactive dismiss unless they are proven necessary.
- `KeyboardTrace` exists for debug investigation and is guarded to no-op outside `DEBUG`.

## Known Symptoms

- During some interactive/back-swipe dismiss paths, UIKit can send an accessory-only terminal frame while the text view is still first responder, followed by zero-duration keyboard frame changes that look like a bounce.
- The bounce is acceptable for now if normal scrolling, tap dismissal, keyboard open, and list positioning remain stable.
- Earlier attempts to suppress these frames or force resigning first responder were too risky and should not be restored casually.

## Telegram Reference Points

Use local Telegram sources before guessing:

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramUI/Sources/ChatControllerNode.swift`
- `ChatControllerNodeView` implements `WindowInputAccessoryHeightProvider` and exposes `getWindowInputAccessoryHeight()`.
- `ChatControllerNode` keeps explicit keyboard gesture state:
  - `upperInputPositionBound`
  - `keyboardGestureBeginLocation`
  - `keyboardGestureAccessoryHeight`
- Telegram's pan handling starts only when the gesture begins above the input area, moves input via `upperInputPositionBound`, and dismisses input only after end-state checks.

Important methods to review:

- `panGestureBegan(location:)`
- `panGestureMoved(location:)`
- `panGestureEnded(location:velocity:)`
- `cancelInteractiveKeyboardGestures()`

## Follow-Up Plan

1. Collect clean device traces for these flows:
   - tap compose, keyboard opens
   - tap outside compose, keyboard closes
   - scroll down normally without intending keyboard dismiss
   - interactive keyboard dismiss from the threshold area
   - slight swipe-back cancel while keyboard is open
   - successful swipe-back while keyboard is open

2. Compare geometry against Telegram:
   - input top edge
   - keyboard top edge
   - accessory height
   - finger start threshold
   - point where compose starts moving
   - point where keyboard starts dismissing

3. Decide between two stable designs:
   - Conservative: keep notification-driven layout only and accept less perfect interactive tracking.
   - Telegram-style: introduce one explicit input-position model similar to `upperInputPositionBound`, with thresholds above compose and end-state-only dismissal.

4. If taking the Telegram-style path:
   - keep one geometry owner in `ChatContainerView`
   - make thresholds above compose for both keyboard and finger tracking
   - avoid direct scroll offset mutation during gesture
   - keep dismissal decisions at gesture end, not mid-frame
   - include a clear cancel path that restores layout without changing first responder unless UIKit already did

## Review Guardrails

- Do not reintroduce broad logging; keep logs concise and prefixed.
- Do not add release logging.
- Do not use `UIScreen.main` / global screen assumptions for geometry.
- Do not make `MessagesCollectionView` and `ChatContainerView` both own keyboard state.
- Do not let the pan bridge mutate scroll offset, force dismissal, or suppress UIKit keyboard notifications.
- Do not add a fix that only works on one iPhone size without checking safe-area and accessory geometry.
- Do not run device/build unless explicitly requested.
