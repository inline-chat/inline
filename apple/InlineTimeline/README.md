# InlineTimeline

The engine behind the message lists: a custom list for chat timelines, without NSTableView, NSScrollView or
UICollectionView. It places rows around a reading row, applies every change (rows, heights, insets, scroll) as one
transaction, and animates on its own clock.

## Layers

- `TimelineCore` (no UIKit or AppKit): the state and solver (`TimelineState`, `TimelineSolver`: placement around the
  reading row, insets, coverage of loaded history), scroll physics and NSScrollView's fling curve, the row index,
  sticky pins and the floating header's geometry, timings. Shared by both platforms.
- `TimelineAppKit`: `TimelineListView` for macOS (the new Mac list): input, the fling (its whole path is baked at the
  finger's lift and runs on the render server), pins, the floating date, the scroll indicator, accessibility.
- `TimelineUIKit`: the iOS list.

The Mac host is `apple/InlineMac/Views/MessageList/Timeline/TimelineMessageListAppKit.swift` (behind the
`experimental.macTimelineList` setting).

## Host contract (`TimelineRows`, macOS)

The engine knows nothing about messages; the host answers (the iOS list's contract is a subset):

- `height(id, width)`: the row's height at a list width (plan it; it's asked often, so cache).
- `make(id, width)` / `update(id, view, width, timing)` / `recycle(id, view)`: row views. An animated `update`
  should move the row's insides on `timing` (the Mac host tracks the cell and its subviews).
- `pin(id, view)`: a sticky view the row holds (an avatar), kept to the bottom edge (bubble style) or the top edge
  (`TimelinePin(view:top:…)`, minimal style); `spanTop`, `spanEnd`, `spanStart` describe its group.
- `passage(id, offset, from, to)`: where content inside a tall row moves between widths, so a resize keeps the
  passage being read (not just the row's offset).
- `floatingHeader` (optional): one view for the title of the section at the top (the day). With `ownInset` and
  `hidesOwnRow`, it carries on the section row's own title: it takes the title over where it reaches the header's
  place, the row hides meanwhile (on the same path as the header, flights included), and the next section's row pushes
  it off (Telegram macOS's sticky date).

Everything else goes through `apply(TimelineTransaction(…))`: rows, coverage, scroll (`.preserve`, `.latest`,
`.to(id, alignment)`), insets, changed rows, timing. Call `invalidate()` when the host goes away: the view can
outlive it (a chat switch keeps it on screen for a frame or more) and must stop its motion and delayed work.

## Rules it keeps (each measured; reasons in the lab cases)

- The reading row is the lowest one showing at least min(its height, 44 pt) on the Mac (`readingAnchor`); slivers
  don't anchor. The default is the lowest visible row (iOS).
- Updates while the reader scrolls land without animation (Telegram's rule); otherwise on the transaction's timing.
- A moved row is a delete plus an insert: a fading picture at its old place, a fade-in at the new one.
- Every track an animated change adds starts on one clock, pins included.
- A touch mid-fling stops the content where it will show when the stop reaches the screen (the display's next
  refresh): the render server plays the fling until the commit lands, and a stop where the content was at the touch
  stepped back 2–38 pt on screen (`TimelineScrollLab --compare catch`, ScreenCaptureKit frames).
- At the newest end the list stays pinned; arrivals rise from under the composer.

## Testing

- `swift test --package-path apple/InlineTimeline`: core and AppKit unit tests.
- `apple/TimelineMacLab`: the engine in a lab window with timed rows and a frame probe.
  `swift run -c release TimelineMacLab --suite [id prefixes…] --origin x,y` runs the behaviour and performance
  suite (153 cases: positions, flings, updates under motion, pins, resize, streaming); keep it frontmost or on a quiet
  machine for the performance cases.
- `apple/TimelineScrollLab`: an NSScrollView prototype and gesture replays (`--play nsscroll --log <file>` records a
  real trackpad's gestures; `--compare` replays them into both lists).
- `scripts/macos/timeline-journey/run.sh <label>`: the Mac app's list on real message rows, signed out, 30 scripted
  scenarios with numbers and captures (see its README).
