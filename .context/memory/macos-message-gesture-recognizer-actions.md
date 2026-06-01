# macOS Message Gesture Recognizer Lesson

Date: 2026-06-02

## What Went Wrong

I treated `NSGestureRecognizerDelegate.shouldAttemptToRecognizeWith` returning `true` as evidence that the recognizer would complete and call its target action. That was the bad assumption.

For message clicks, the logs showed the important pattern:

```text
MinimalMessageView.shouldHandleGesture recognizer=entity allow=true
MinimalMessageView.delegate.shouldAttempt recognizer=entity allow=true
MessageTextView.mouseDown forwardingToSuper
```

and for ACK double-click:

```text
MinimalMessageView.shouldHandleGesture recognizer=doubleClick clicks=2 allow=true
MinimalMessageView.delegate.shouldAttempt recognizer=doubleClick clicks=2 allow=true
```

but there was no `handleEntityClick` or `handleDoubleClick` log after that. The recognizers were being admitted, but their action callbacks were not reliably firing. The real failure was AppKit event delivery/recognizer completion around `NSTextView` and nested message subviews, not just hit-test filtering.

## Lesson

When debugging AppKit gestures, verify the whole path:

1. hit-test target
2. delegate admission
3. recognizer state transition
4. target action callback
5. business action

Do not stop at delegate admission. `allow=true` only means the recognizer may try; it does not prove the action will run.

If logs show delegate admission but no action callback, move critical behavior to the deterministic event boundary:

- For text entity clicks, handle on `MessageTextView.mouseDown` before `super.mouseDown`, then return only when the entity action was handled.
- For message ACK double-click, handle on the second left mouse-down in `shouldAttemptToRecognizeWith`, guard by `eventNumber`, and return `false` to avoid duplicate recognizer action.
- Keep the recognizer action as fallback only.
- Block long press when `event.clickCount > 1` so it cannot compete with double-click.

## Current Fix Shape

Files:

- `apple/InlineMac/Views/Message/MessageTextView.swift`
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MinimalMessageView.swift`

Expected logs after the fix:

```text
MessageTextView.mouseDown entityClickAttempt ... handled=true
MessageView.handleTextEntityClick ... action=copyEmail/copyInlineCode/copyCodeBlock/openURL/openMention
MessageView.delegate.shouldAttempt recognizer=doubleClick ... action=handleDoubleClickInDelegate
MessageView.performDoubleClickAck ... action=addAckReaction/deleteAckReaction
```

## Review Rule For Future Changes

For macOS message click/gesture regressions, never rely on `NSClickGestureRecognizer` attached to `NSTextView` or parent message views as the only execution path for critical actions. Add logs that prove the target action ran, not just that the recognizer was allowed.
