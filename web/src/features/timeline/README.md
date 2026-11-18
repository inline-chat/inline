# Timeline view

The message list: `TimelineView` renders the timeline controller of `@inline/timeline` (`web/packages/timeline`) in one scroll container holding a bounded window of real rows in normal document flow. All scroll logic (anchoring, compensation, following, jumps, holds, opening, trimming, read marking) is the controller's; this feature binds it to the DOM and renders. Specification: `web/docs/timeline-and-composer.md` (Timeline).

## Use

```tsx
const controller = createTimelineController({ viewerId, clock: browserClock, frames: browserFrames, request, markRead, savePlace })
const surface = createTimelineSurface({ controller, window }) // window: ReadSignal<TimelineWindow>
controller.open({ target, items, window: window.peek() })      // before the first render: first frame from local data

<TimelineView surface={surface} renderItem={renderItem} label="Messages" />

surface.focus()                         // the app's "focus the message list" command
surface.setInsets({ top: 0, bottom: composerHeight })
```

Create both in the chat's view model (or a `useModel` factory) and dispose them with it: `surface.dispose()` stops the flash timer, `controller.dispose()` saves the reading place. `useModel` calls `dispose()` on what its factory returns.

### `createTimelineSurface(options)` (`surface.ts`, framework-free)

| Option | |
| --- | --- |
| `controller` | The `TimelineController`. |
| `window?` | `ReadSignal<TimelineWindow>`: the same window given to `controller.setItems`. Drives the "loading older/newer" placeholders and the empty state. |
| `insets?` | Overlays at start (`{ top, bottom }`). |
| `clock?`, `frames?` | For the DOM host and the flash timer; the browser's by default. |

The surface exposes `keys` (rendered keys, identity-stable while membership is unchanged), `item(key)` and `flash(key)` (one signal per row), `olderEdge`, `newerEdge`, `empty`, the `root` and `container` parts the view attaches with `useElement`, `element()`, `focus()`, `insets()`, `setInsets()`, `dispose()`. The `container` part creates the DOM host (`createDomHost(container, { content })`) and calls `controller.attach`; its cleanup detaches and disposes the host.

### `TimelineView` props

| Prop | |
| --- | --- |
| `surface` | From `createTimelineSurface`. |
| `renderItem(item)` | Renders a message, day separator or unread line. |
| `label?` | Accessible name of the list (default "Messages"). |
| `empty?` | Shown for a chat with no messages (default "No messages yet"). |
| `style?` | StyleX styles for the root. The root fills its parent (`block-size: 100%`), so give the parent a definite height. |

## Rules a caller must keep

1. **`renderItem` is stable**: a module-level function, or one memoized by its owner. A new function renders every row.
2. **Rows have no vertical margins** and read their own data. A message row takes the item and reads anything that changes often (reactions, streamed text, media state) through its own signals by ID. Spacing goes inside the row (padding). The wrapper is `display: flow-root`, so a stray child margin stays inside the row's box, but it still counts towards that row's height, never between rows.
3. **Media reserves its box** from metadata. A late box is compensated (the lab measures it), but the guide's rule stands.
4. **Nothing else writes `scrollTop`** on the container, and nothing calls `scrollIntoView` on rows. Navigation goes through `controller.jumpToMessage` and `jumpToLatest`.
5. **Insets go through `surface.setInsets`**, never through the caller's own padding on the list: the surface writes `--timeline-inset-top` and `--timeline-inset-bottom` on the root and container, then tells the host, so the controller reads the new layout when it reconciles. The content's bottom padding is 10 px (Mac `messageListBottomInset`) plus the bottom inset. The top inset is not added as padding: the host contract wants the content's top padding fixed while reading, so a translucent header covers the oldest rows at the very start of history.
6. **`controller.open` before the first render** of a chat, so the rows paint placed in the first frame.

## What the view guarantees

- **Renders.** The list component reads `keys`; each row wrapper (`memo`) reads `item(key)` and `flash(key)`. A change to one row's content renders that row's wrapper and the caller's row, and nothing else; appending or prepending renders the new rows only (plus any existing item whose group edge or day-separator date changed, which is correct). A change inside a row that reads its own signal (streaming, a reaction, media) renders no timeline component. The components call `countRender` (`timeline:view`, `timeline:scroller`, `timeline:list`, `timeline:row`) for render budget tests.
- **No scroll writes and no measuring** here. The container has `overflow-anchor: none` (in its styles, and set again by the DOM host).
- **Rows** are the direct, keyed (`data-timeline-key`) children of `[data-timeline-content]`. Non-keyed children of that element are the edges: the older reserve (40 px, always present above the first row, a spinner inside while loading) and the newer placeholder (40 px below the last row while the rendered rows stop short of the live end). Neither changes height while present, so pages arriving move nothing beyond the controller's compensation. Known limit: when the window reaches latest with no new rows (no rows event), removing the newer placeholder shortens the content by 40 px under a reader resting at the very bottom, and the browser clamps; the controller treats that as an external scroll.
- **Opening hidden.** While `controller.hidden` is true the container is laid out but `visibility: hidden` (the controller places rows while hidden) and `aria-busy`; the spinner overlay shows when `controller.spinner` turns true (after the controller's 250 ms); on reveal the list fades in over 200 ms (`REVEAL_FADE_MS`), instantly under reduced motion.
- **Highlight flash.** A `highlight` change flashes that row for 850 ms (Mac: 0.2 s in, 0.4 s held, 0.25 s out) behind its content, without affecting layout. The surface clears the flash afterwards, so a row trimmed and rendered again later does not replay it. A highlight for a row that is not in the rendered range yet stays pending and its 850 ms start when the row renders (the controller only highlights rendered rows on landing; this guards any other order). Under reduced motion the tint appears and disappears without a fade.
- **Jump to latest.** Placed like the Mac's: a 34 px circle centered 32 px from the trailing edge, 10 px above the bottom inset, with the count badge (Mac `ChatUnreadBadgeCount.format`: 999, 1.2K, 12K) at its top trailing corner. Always mounted and absolutely positioned (no layout shift); hidden it is `inert`, transparent and scaled to 0.8. Clicking it does not take focus (as on the Mac, focus stays in the composer); it is not in the tab order, since End and the app's command do the same from the keyboard. Its accessible name carries the count.
- **Keyboard and focus.** The container is focusable (`tabIndex=0`) and a labelled region. Page Up and Down, Home and End, the arrows and Space scroll it natively, and its keydown reaches the DOM host, which reports the key to the controller as user input before the scroll. A click in the list focuses the container (the nearest focusable ancestor), so keys work after clicking a message. `surface.focus()` focuses it without scrolling. The focus ring shows for keyboard focus only.
- **Styling.** StyleX with the kit's tokens, logical properties only (correct in right to left: the button moves to the left edge, the scrollbar follows the direction), light and dark through the tokens, and no motion under `prefers-reduced-motion`.

## The lab

`web/lab-timeline.html` (source `web/src/lab/timeline/`) runs `TimelineView` over the real controller and DOM host, on a seeded history of 6,000 messages with variable heights: text from a few words to 200, some right-to-left lines, media boxes (half of them late: no box until resolved), a spacer per row for resizing, and streamed text. A stand-in core (`lab-core.ts`) holds the window, the read state and the controller's requests.

Open it with the dev server: `http://localhost:8001/lab-timeline.html` (query: `seed=`, `theme=light|dark`, `dir=rtl`, `run=all`). Keep the window in front: a hidden or occluded window gets no animation frames, and the lab stops with an error saying so rather than measuring frames that never happened.

**Run all** performs every operation in sequence and writes the table on the page and to `globalThis.__timelineLab` (plain data: `status`, `message`, `seed`, `devicePixelRatio`, `userAgent`, `passed`, `failed`, `results`, and `table` as tab-separated text). `globalThis.__timelineLabControl` has one function per operation, each returning a promise of its result row once the operation and its frames are done; they run one at a time. For example:

```js
const snapshot = await __timelineLabControl.runAll()
snapshot.results.filter((r) => !r.pass)
await __timelineLabControl.prepend(100)
```

Operations: `appendFollowing`, `streamBottom`, `heightFollowing`, `insetFollowing`, `keyboard`, `appendReading`, `resizeAbove`, `lateMedia`, `streamAbove`, `streamBelow`, `widthReading`, `heightReading`, `insetReading`, `prepend`, `trim`, `jumpNear`, `jumpFar`, `jumpUnloaded`, `jumpLatest`, `openUnreadCached`, `openUnreadUncached`; and `runAll`, `reset`, `startStream(where)`, `stopStream`, `results`.

### Reading the table

One row per operation:

| Column | Meaning |
| --- | --- |
| Metric | `anchor`: the controller's reference row (its first anchor still in the DOM), its offset from the container's top read with `getBoundingClientRect` before and after. `bottom`: distance from the bottom while following (must stay 0). `landing`: after a jump, distance between the scroll offset and the one that centers the target (`centeredOffset`), or the bottom for latest. `line`: the unread line's distance from the uncovered top after opening. `none`: a behavior check. |
| Reps | Repetitions (100 for prepend and resize; frames for streaming count as one). |
| Max \|drift\| px | The largest absolute drift in any sampled frame of any repetition, in CSS pixels. Samples are taken at the start of every frame after the operation, so a wrong position that was painted for one frame counts even when the next corrects it. |
| Accumulated px | The sum of the repetitions' final signed drifts: where the reader ends up after all of them. |
| List, Rows, Lab rows | Renders of the timeline's list component, its row wrappers, and the lab's row content, over the whole operation. Streaming, resizes and media loads must render no list and no wrapper; appends and prepends render only new (or legitimately changed) rows. |
| Mode | The controller's mode before → after. |
| Result | Pass when max drift and accumulated drift are both under 1 px and every check holds; otherwise the failures, and notes (rows trimmed, spinner seen, counts). |

The lab measures; the view never does. The lab's only scroll writes stand in for the user: each follows a synthetic wheel event on the container, so the host reports user input first. Everything is seeded, so two runs do the same operations on the same rows (text wrapping still depends on the machine's fonts).

### First real-browser baseline

Chromium 156, device pixel ratio 1, production build of the labs, `runAll` through `__timelineLabControl`, animation frames throttled to a few per second (17 November 2026, run by the coordinator). 18 of 21 operations passed.

| Operation | Max \|drift\| px | Accumulated px | Result |
| --- | --- | --- | --- |
| append one (following) | 0 | 0 | pass |
| stream at the bottom (following) | 0 | 0 | pass |
| container height, composer inset (reading and following) | 0 | 0 | pass |
| resize a row above ×100 | 0.75 | 0.484 | pass |
| late media above ×20 | 0.5 | 1.5 | fail: accumulation (timeline package) |
| stream a row above the reader | 0.5 | | pass |
| container width (reading) | 0.313 | | pass |
| prepend a page ×100 | 0.484 | 1.016 | fail: accumulation (timeline package) |
| trim | 0.906 | | pass |
| jump to a near message | 0.43 | | pass |
| jump to an uncached message | 0.367 | | pass |
| open at unread, cached | 0.266 | | pass |
| open at unread, not cached | 0.172 | | pass |

Renders: one append renders one row; a streaming row renders no list and no other row.

Two failures of that run were the lab's and are fixed: the far jump's flash was checked a frame or two after landing, which in a throttled window can be after the 850 ms flash ended (the lab now watches the DOM for the flash from before the jump; the controller and surface flash correctly, `surface.test.ts` shows both far-jump paths); and the prepend run scrolled the reader back by the content's growth, which a trim of rows below in the same frames understated, so the reader sometimes went down far enough for the controller to widen the range again and remount trimmed rows (those renders were counted as unexplained; the lab now scrolls back by the controller's correction and expects exactly the rows mounted plus the items that changed).

A second run (the package's rounding fixes and the lab fixes above) passed 20 of 21: prepend ×100 max 0.844, accumulated 0.016, 260 row renders for what it mounted; the far jump flashed. Late media ×20 still read max 0.5 and accumulated 1.5, unchanged by the package fix. The cause was the lab again: to arm a late box it could pick a row above that already showed a media box (a reserved one, or one resolved earlier in the same run), and arming set that box to 0, shrinking the row; the controller corrected that shrink before the lab read "before", so the shrink's rounding was outside the measurement and the regrowth's showed up as +0.5 px (three such repetitions: 1.5 px, all one way, while the reader's real net position was unchanged). The lab now arms only rows with no media box, reads "before" before arming, and fails the run if arming changes a row's height. Nothing in the view reacts to a row's size (the edges follow the window and the range, the reveal follows the controller).

### Traces

`lab-timeline.html?trace=1` records, for every repetition of the resize and late media runs, on `__timelineLab.trace.resizeAbove` and `.lateMedia`: the measured row and the changed row's keys, the drift, whether the controller's reference row is the same before and after (`sameAnchor`), and at each point (`before`, `armed` for a box the lab armed, `after`) the reference row, the measured row's offset, the changed row's top and height, its media box's height, `scrollTop`, `scrollHeight` and the controller's `debug().offsets` (`intended`, `last`, `phase`). Without the parameter, `trace` is null and nothing is recorded.

### Which of the package's browser tests the lab covers

The timeline package README lists seven browser tests still to write.

| # | Test | Lab |
| --- | --- | --- |
| 1 | Prepend drift | Covered: `prepend` (100 pages of 10 to 40 rows, the reader scrolling up between pages, the controller trimming when scrolling goes idle) and `trim` (rows removed above the reader). Not covered: prepends during real momentum scrolling and the WebKit fling check; synthetic scrolls have no momentum. |
| 2 | Resize | Covered: width (re-wrapping above the anchor), height while reading and while following (the bottom clamp), the composer inset while reading and following. Not covered: a top inset (header appearing). |
| 3 | Delayed media | Covered without a reserved box (`lateMedia`); reserved boxes do not change height. |
| 4 | Streaming | Covered: a row above the reader, a row below the reader's anchor, and the bottom while following, one update per frame for 60 frames. |
| 5 | Event ordering | Indirectly: per-frame sampling would show any painted drift from a rows event or resize arriving late. It does not assert the order of events or how `scrollTop` rounds. |
| 6 | Opening | Covered: unread cached (line at the top from the first frame, never hidden), unread not cached (hidden and busy, spinner after 250 ms of a 400 ms load, revealed with the line at the top), and a jump to an uncached message. |
| 7 | Input classification | Only the keyboard path: `focus()` puts focus on the list and a Page Up there detaches from latest. Real wheel, trackpad momentum, scrollbar drag and touch need real input. |

## Files

| File | |
| --- | --- |
| `TimelineView.tsx` | The view. |
| `surface.ts` | The DOM surface: host and controller wiring, per-row signals, flash timing, insets, focus. |
| `chrome.ts` | Pure: the edge placeholders and the empty state. |
| `format.ts` | Pure: the badge count and the button's accessible name. |

Tests: `bunx vitest run src/features/timeline src/lab/timeline` from `web/` (format, chrome, the surface's signals and flash timing against the package's fake host, and the lab's generator, results and frame waiter).
