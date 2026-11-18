# @inline/timeline

The framework-free controller for the message list: our own list, a bounded window of real rows in normal document flow inside one scroll container, one owner for scroll correction, no virtualizer library.

`web/docs/architecture.md` places the timeline inside `view`. It is its own package for now so parallel work does not share a package; it can move into `view/timeline` unchanged (it depends only on `@inline/core-protocol`, `@inline/ids` and `@inline/reactive`).

The specification is `web/docs/timeline-and-composer.md` (Timeline). The behavioral reference is the Mac client: `apple/InlineMac/Views/MessageList/MessageListAppKit.swift`, `MessageListViewport.swift`, `ChatRowListViewModel.swift`, and in `apple/InlineKit/Sources/InlineKit/ViewModels/`: `ChatUnreadOpening.swift`, `UnreadLineGeometry.swift`, `ChatUnreadBadgeCount.swift`, `UnreadManager.swift`.

Not in this package yet: the view, message rendering, text selection across rows.

## Public API

| Export | What it is |
| --- | --- |
| `timelineItems(input, previous?)` | Pure: ordered `MessageRow`s, viewer, time zone, unread boundary → items (messages with `firstInGroup`/`lastInGroup`, day separators, the unread line) and `unreadLineAbove` to pass back so the line stays fixed for the visit. Reuses unchanged item objects from `previous`. |
| `resolveUnreadLine`, `canGroup`, `dayKeyOf`, `messageItemKey`, `daySeparatorKey`, `UNREAD_LINE_KEY` | The rules behind it. |
| `createTimelineController(options)` | The controller. Signals: `mode`, `items`, `range`, `rendered`, `latestButton` (`{ visible, count }`), `hidden`, `spinner`, `highlight`. Methods: `attach(host)`, `detach()`, `open({ target, items, window })`, `setItems(items, window)`, `setReadState`, `jumpToMessage`, `jumpToLatest`, `userSent`, `connectionLost`, `leave`, `dispose`, `debug`. Callbacks: `request(range)` (forward as `ensure`), `markRead(decision)` (forward as a `markRead` intent), `savePlace(place \| null)`. |
| `createDomHost(container, options)` | The host over a real scroll container. |
| `TimelineHost`, `HostEvent`, `Clock`, `FrameSource` | The host contract. |
| `decideRead`, `jumpToLatestCount`, `planEdges`, `planTrim`, `planJump`, `planLanding`, `landingOffset`, `heldOffset`, `centeredOffset`, `withinFollowZone`, `initialWindowSize` | The pure decisions, for the overlay and other packages' tests. |
| `resizeDelta`, `structuralDelta` | The compensation sums. |
| `@inline/timeline/testing`: `createFakeHost`, `SCROLL_ROUNDINGS` | A deterministic layout model with virtual time and frames for other packages' tests. `scrollRounding` (`round`, `floor`, `ceil`, `none`, `deferred`) and `devicePixelRatio` model how engines snap `scrollTop`. |

Callbacks (`request`, `markRead`, `savePlace`) are delivered after the controller's call has finished, never from inside it, so a core that answers synchronously re-enters `setItems` with the controller's state complete.

One controller per chat view model. `open` may be called again to reopen the same chat; `detach`/`attach` move it between elements, so a resident chat puts its reader back where they were.

### Wiring

```
rows + WindowResource (core) ──► timelineItems() ──► controller.setItems(items, window)
controller.rendered ──► view renders rows keyed by item.key, with data-timeline-key
container element ──► createDomHost(container) ──► controller.attach(host)
controller.request(range) ──► { kind: "ensure", sub, range }
controller.markRead({ maxId }) ──► markRead intent
dialog row ──► controller.setReadState({ unreadCount, readMaxId })
```

## Model

**Modes.** `following` (at the bottom; new rows keep it there), `reading` (somewhere in history; nothing moves what the reader sees), `target` (a jump in progress), `restoring` (opened at a saved place or the unread line; that row is held until the user moves).

**Anchors.** Captured on user input, user scroll, placement and landing: every visible message row with its offset from the viewport top, in reading order, rows that start on screen before a row cut by the top edge (so a tall row cut at the top grows out of sight instead of pushing the text being read). Separators are never anchors: a day separator moves above older rows of its own day when they load. The first anchor still rendered is the reference row; deleting it falls back to the next.

**Compensation, one owner.** Only the controller writes the scroll offset. It corrects by the sum of height changes above the reference row:

- a resize batch: each row above contributes its new height minus its cached height;
- a structural change (from the host's `rows` event, delivered in the microtask after the commit, before paint and before any later scroll event): rows that are now above and were not add their height, rows that were above and are not subtract their cached height (insert, remove, move).

The correction is applied as one write. Working from heights rather than from the reference row's measured position is deliberate: a scroll event can land between layout and the resize observer, and anchors captured then would already include the shift; a height delta is right regardless, and every change is counted exactly once through the size cache. Anchors are therefore not re-captured after corrections, only on user movement, placement and landing.

**No accumulation.** Engines snap a written `scrollTop` to device pixels: some round, floor or ceil at once, some keep the fraction when read back and snap when they commit the scroll. The controller keeps the offset it intends unrounded, reads back what landed after every write, and keeps the difference (the remainder), including when an engine snaps later (its scroll event is recognized as the controller's own, even mid-gesture). User moves carry the remainder, so corrections before and after a reader's scroll still add up exactly. The last absolute write (a placement, a landing, the bottom) sets the sub-pixel phase the reader sees; every correction aims at the offset that keeps that phase rather than at the nearest pixel, and an engine that floors or ceils at 1x gets a second write of the nearest whole pixel. So every remainder stays within half a device pixel of the phase and a run of corrections never adds up to more than that. The cost: one correction at 1x can move up to just under a pixel (still inside the budget). Writes under 0.5 px are skipped, with the remainder kept. The controller also starts from its intended offset when the browser clamped a list that shrank under a reader near the bottom.

**Holds and pins are absolute.** A held row (unread line, saved place) is re-placed from its measured position on every layout change, clamped to the scroll range, never dropped by clamping (Mac `UnreadLineGeometry.heldOrigin`). A list resting within 1 px of the bottom is re-pinned to the bottom.

**Follow rules.** Pinned only at the exact bottom (1 px). Within the 44 px follow zone a reader coming back down reattaches; one upward input detaches at once, from the input event, before its scroll. A new message follows only when the list is in the zone, the user is not scrolling, no jump runs and nothing is held. Rows arriving below a reader never move, detach or reattach them; the mode changes only on user movement, explicit navigation, or a scroll the controller did not cause (find in page, focus, the browser clamping a shorter list).

**The user wins.** Any wheel, touch, key or scrollbar input cancels an animation and a pending jump and releases a hold in the same event. Scroll events alone are never taken as intent; the scroll event of the controller's own write is ignored by comparing with the offset it read back after writing.

**Window.** The core holds the loaded window; the controller renders a range of it. The first range is `viewport / 24 + 30` rows. After user movement within one viewport of an edge, it first widens the range over loaded rows, then asks the core for `older`/`newer` (once until that edge changes). When scrolling goes idle and more than 300 rows are rendered, it trims to 200 around the viewport (the newest 200 when pinned); the structural compensation keeps the reader still.

**Opening.** Latest: placed at the bottom in the first commit. Unread, cached: the line held at the top (under the top inset), or the bottom when the rows from the line down fit. Unread, not cached: hidden, `ensure { around: boundary }`, spinner only after 250 ms, placed once when the line arrives, revealed on the next frame; falls back to latest on `connectionLost`, `userSent`, `jumpToLatest`, or when the fetch settles without the line. Saved place: held at its offset. A message: centered and highlighted; not loaded, hidden until it lands.

**Jumps.** In the rendered range: one 0.4 s ease-in-out, or more than two viewports away 0.3 s ease-in to half a viewport short and 0.4 s ease-out onto it. Loaded but not rendered, or not loaded (`ensure { around }`): render the rows around it, start half a viewport short on the side the reader comes from, ease 0.4 s onto it. A missing target lands on the nearest message without a highlight. A layout change mid-jump re-aims at the target. `jumpToLatest` does the same towards the bottom and does not save the place it leaves.

**Saved place.** Captured when scrolling goes idle and on `leave`/`dispose`: the first message on screen with a server ID and its top's distance below the uncovered top. Cleared (null) when the newest message is on screen, so a chat left a few lines up reopens at the bottom.

**Read marking (rule 4).** Only when the app is active, the window visible and the list landed (not hidden, placing or jumping). At the live end inside the follow zone, read all (newest message); otherwise up to the highest visible incoming message, capped at the window's contiguous history, never backwards. Evaluated on landing, scroll idle, reattaching, new messages while following, and becoming active. Retries and their 0.5 s to 8 s backoff belong to the core's `markRead` intent.

**Jump to latest count (rule 5).** The dialog's unread count minus the incoming messages between the server's read marker and the local frontier (capped at contiguous history) that the server has not caught up with.

## Constants

All in `src/constants.ts`, each with its source comment.

| Constant | Value | Source |
| --- | --- | --- |
| `FOLLOW_ZONE_PX` | 44 | Mac `bottomFollowZone` |
| `EXACT_BOTTOM_PX` | 1 | Mac `exactBottomTolerance` |
| `MIN_CORRECTION_PX` | 0.5 | Mac `UnreadLineGeometry.tolerance`, `MessageListViewport.restore` |
| `OFFSET_ROUNDING_TOLERANCE_PX` | 1 | Web only: engines round `scrollTop` |
| `SCROLL_IDLE_MS` | 150 | noor0 rail scroll-end debounce (Mac uses live-scroll end notifications) |
| `INITIAL_ROWS_PX_PER_ROW`, `INITIAL_ROWS_BASE`, `INITIAL_ROWS_FALLBACK` | 24, 30, 60 | Mac `defaultInitialLimit` (screen height there, viewport here) |
| `LOAD_MORE_VIEWPORTS` | 1 | Mac `handleBoundsChange` |
| `TRIM_ABOVE_ROWS`, `TRIM_TO_ROWS` | 300, 200 | Guide start values; the Mac table does not trim |
| `UNREAD_WINDOW_SIDE_ROWS` | 44 | Mac `ChatUnreadOpening.windowLimit` = 88 |
| `UNREAD_SPINNER_DELAY_MS` | 250 | Mac `beginUnreadFetchIfNeeded` |
| `REVEAL_FADE_MS` | 200 | Mac `revealListAfterLayout` (for the view's fade) |
| `FAR_JUMP_VIEWPORTS` | 2 | Mac `scrollToMessage` |
| `FAR_JUMP_PHASE1_MS`, `FAR_JUMP_PHASE2_MS`, `NEAR_JUMP_MS` | 300, 400, 400 | Mac `scrollToMessage` (easeIn, easeOut, easeInEaseOut) |
| `GROUP_MAX_GAP_SECONDS` | 300 | Mac `canGroup` |

## Host contract

`src/host.ts`. Coordinates are top-down; row rectangles are relative to the scroll container's visible top edge.

- Rows are direct children of one content element, in reading order, each with `data-timeline-key` set to the item key. Rows have **no vertical margins** (spacing goes inside the row); the content's top padding does not change while reading. Compensation relies on content height being the sum of row heights plus fixed padding.
- Insets are the parts of the viewport covered by overlays (a translucent header, an overlaid composer); call `domHost.notifyInsets()` when they change. If the composer overlays the list, give the content matching bottom padding.
- Reads: viewport height, content height, scroll offset, insets, all row keys, a row's rectangle, the keys of rows intersecting the viewport, activity (visible, active).
- Commands: set the offset; animate it with a duration and easing, cancellable.
- Events: `input` (wheel, touch, key, scrollbar; with direction; `held` for gestures until `inputEnd`) before the scroll it causes; `scroll`; `scrollEnd`; `rows` (new order and the new rows' heights, in the microtask after the commit); `resize` (per frame; zero sizes allowed, ignored); `viewport`; `activity`.
- In one observer callback the DOM host emits row sizes before the viewport change.

The DOM host sets `overflow-anchor: none`, measures new rows in its mutation observer, batches sizes through one `ResizeObserver`, classifies input (Ctrl+wheel is pinch zoom and ignored; only unmodified scroll keys and Shift+Space count, so Alt+Up and other shortcuts never detach the list; keys typed into editable elements are ignored; a scroll during a pointer press counts as scrollbar input, which also covers overlay scrollbars and drag-selection auto-scroll), forwards `scrollend` where it exists and otherwise ends scrolling 150 ms after the last scroll event.

## Tests

`bun run test` from this folder. Unit tests run in Node against the fake host with virtual time; `dom-host.test.ts` runs in happy-dom.

- `items.test.ts`: grouping (300 s, sender, calendar day in the time zone, the hook), separators (half-hour and 45-minute offsets, DST), the unread line (own messages, before the separator, not reaching the boundary, fixed for the visit), key and identity stability.
- `policy.test.ts`: window sizes and edges, trimming, the follow zone table, landings, jump plans and easing, the read-marking decision table, the count, the compensation sums.
- `controller.follow.test.ts`: exact bottom and the follow zone, detaching on one upward input, reattaching, arrivals below a reader, ignoring the correction's own scroll event, no following during a gesture, external scrolls and clamps.
- `controller.anchor.test.ts`: capture order, deleted anchors, zero drift on prepend, resize above, viewport resize, width change, streaming below and of the anchored row, zero-size entries, the scroll-before-observer race, 100 repeated prepends, 100 sub-pixel resizes and 100 mixed operations at 1x and 2x, re-attaching a resident chat.
- `controller.open.test.ts`: unread cached (line at the top, under an inset, fits, fixed, held through media, width, composer and inset changes), uncached (hidden, request, spinner timing, reveal, every fallback), saved places, opening at a message.
- `controller.jump.test.ts`: near and far jumps with timing, cancellation by input, re-aiming, out-of-window landings, missing targets, jump to latest in and out of the window, every mode transition.
- `controller.rounding.test.ts`: the browser lab's operations (resize above, late media, prepend with the reader scrolling between pages, mixed) 100 times each with text-like fractional heights, under every `scrollTop` rounding policy (`round`, `floor`, `ceil`, `none`, `deferred`) at 1x and 2x: accumulated drift under 0.5 px, every operation under 1 px.
- `controller.window.test.ts`: growth only after user movement, local widening, newer at the bottom, trimming while idle and never while scrolling, read marking integration.
- `dom-host.test.ts`, `testing/fake-host.test.ts`: the hosts' contracts.

### Browser tests still to write

happy-dom has no layout, so none of the following has been measured. Write them in the browser suite (Chromium, WebKit, Firefox), asserting the anchored row's `getBoundingClientRect().top` before and after, under 1 px per operation and none accumulating over 100:

1. **Prepend drift**: scroll up into history with real rows of mixed heights; load older pages repeatedly during momentum scrolling. In WebKit check that writing `scrollTop` mid-momentum does not stop the fling (a known WebKit behavior; if it does, defer corrections to `scrollend` there and measure).
2. **Resize**: pane width changes (text re-wraps above the anchor), composer growth, a header appearing (insets), window height changes, including near the bottom where the browser clamps.
3. **Delayed media**: an image or embed above the anchor that loads late, with and without a reserved box.
4. **Streaming above the reader**: a row below the anchor growing 30 to 60 times a second; the reader must not move. And streaming at the bottom while following: stays pinned with no visible jitter.
5. **Event ordering**: that the `rows` event arrives before any later scroll event, and that `ResizeObserver` entries for a commit arrive before paint, in all three engines; that sub-pixel `scrollTop` writes round as assumed (fractional in Chromium, whole pixels in WebKit).
6. **Opening**: open at unread (cached) paints the line at the top in the first frame; uncached shows no list until placed, then fades in; jump to an uncached message.
7. **Input classification**: trackpad momentum, mouse wheel ticks, overlay scrollbar drag (macOS), classic scrollbar gutter (Windows), keyboard paging with the container focused, touch on iPad.

Selection across rows (and across trimmed rows) is out of scope here; it is its own piece of work.
