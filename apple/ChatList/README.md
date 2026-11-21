# ChatList

Experimental, upright, bottom-anchored chat lists with a shared Swift geometry
and transaction core and separate native AppKit and UIKit hosts. There are no
Inline, database, networking, view-model, or message-renderer dependencies.

## Boundary and complexity budget

- One presentation owner (`ChatListSession`) per list, one installed snapshot,
  one active/newest-pending preparation queue, and one native display clock.
- Two native hosts implement scrolling, reuse, focus, accessibility retention,
  clipping, and cell lifetime. Both consume the same core contracts.
- No durable fields, RPCs, migrations, background services, or built-in message
  cell types. Preparation providers may dispatch expensive work to their actor.
- Applications own history, source models, exact cell measurement, content,
  actions, and rendering. Labs supply ordinary structs and native fixture cells.

## Public API

Import `ChatListCore` and either `ChatListAppKit` or `ChatListUIKit`. Each native
module exports `ChatListView<ID, Content>`, backed by `NSView` or `UIView`.

```swift
let session = ChatListSession<Int64, CellPlan>()
let list = ChatListView(session: session) { item, reused in
  reused ?? MyCell()
}
list.bindCell = { cell, item, context in
  (cell as! MyCell).bind(item.content, width: context.width)
}
list.presentCell = { cell, placement in
  (cell as! MyCell).present(elements: placement.row.elements)
}
session.onNeedsSnapshot = { context in
  // Return an immutable, exactly measured plan for this context.
  session.requestPreparation(identities: models.map(\.stableID)) { context in
    try await preparationWorker.prepare(models, context: context)
  }
}
```

`ChatListSnapshot` supplies ordered items, layout context, history availability,
and optional sticky decoration descriptors. Each item has a stable row occurrence
ID, content revision, reuse identifier, payload, exact height, and optional named
child frames. A message shown in two roles needs two row occurrence IDs. Increment
the revision whenever content or prepared geometry changes. The bind callback
runs only when identity, reuse kind, revision, or installed context changes.

```swift
try session.apply(snapshot,
  intent: .reading(.init(id: rowID, localY: 180, viewportY: 40)),
  animation: .animated, at: time, viewport: viewport)
session.navigate(to: .latest, animation: .animated, at: time)
session.updateViewport(viewport, displayScale: scale,
  environmentRevision: fontRevision, animation: .animated, at: time)
```

The optional viewport on `apply` couples data, dimensions, logical occlusions,
and intent in one observable transaction. `updateViewport` alone supports
interactive composer/toolbar changes. Top and bottom insets belong to the core;
native content insets stay zero. Short content aligns above the bottom inset.
Reading coordinates measure inward from an explicit usable viewport edge
(`TimelineAnchor.edge`, top by default). Changing the bottom inset captures the
bottommost visible row/point and keeps its distance above the moving bottom
edge. Keyboard and composer growth/shrink therefore carry that content with
them, including simultaneous row-height changes and interactive retargeting.
Bottom takes precedence when both insets change; a top-only inset transition
captures from the top. Explicit navigation retains its requested edge.

For a system keyboard or an interactive inset driven by another animation,
submit its currently presented occlusion with `animation: .none` on the shared
frame clock. This follows the supplied motion directly; `.animated` selects the
list's spring for an ordinary target change. A keyboard adapter remains outside
the package. Native scrollbar tracks follow the presented logical insets while
native content insets remain zero.

During interactive dismissal, native scrolling may already move the content
with the keyboard. Submit those viewport samples with
`viewportAdjustment: .nativeInput`: this keeps the reached native origin and
installs the insets immediately, avoiding a second anchor correction. Use the
default `.preserveAnchor` for passive keyboard animation and settling after
native input ends. This is a per-transaction ownership decision, not a blanket
rule for every inset change while touching the list. Independent data/height
changes still receive their own anchor compensation, including an atomic
`apply(..., viewport: ..., viewportAdjustment: .nativeInput)` transaction.

Width, display scale, and `environmentRevision` form the exact layout context.
Increment the latter for font, layout-policy, or other external changes. During
replacement preparation, native cells retain their installed width; they are
clipped by the changing viewport. No estimated geometry or intermediate text
width is bound. The first committed snapshot is exact and unanimated.

## Arbitrary cells and content anchors

The list never measures or inspects text. It preserves a row/local coordinate
by default, with a surviving-neighbor fallback if that row disappears. A tall
cell can optionally preserve a meaningful internal point across reflow:

```swift
list.captureCellAnchor = { cell, item, localVisibleRect in
  // Token is opaque: a paragraph/character address, media marker, etc.
  (cell as! MyCell).captureAnchor(in: localVisibleRect)
}
list.resolveCellAnchor = { cell, item, previous in
  // Validate correspondence once against the replacement payload.
  (cell as! MyCell).resolve(previous) // element name + local offset
}
```

Resolution runs after binding the replacement. Each subsequent frame follows
the named child's animated frame without repeating native glyph layout. Return
nil when correspondence is unavailable; the row/neighbor policy remains valid.
Preserving the same passage through arbitrary content edits requires the cell's
semantic mapping. A list cannot infer that mapping from an opaque view.

Native input and explicit navigation override content anchors. Native bounce
defers content replacement and navigation until legal bounds return, while
viewport height and inset motion remain live on the installed exact-width canvas.
The native rubber-band displacement stays relative to its moving legal edge;
row and child animation resumes after settlement without consuming the paused time.
In-range gestures still receive geometry compensation when rows or insets change. Focused cells and
`pinCell(for:)` interactions stay resident outside overscan; logical removal
ends native focus before recycling. Balance explicit pins with `unpinCell`.

`ChatListDecoration` computes sticky top/bottom positions within an animated row
span for badges, avatars, or arbitrary views. Use `session.decorationPlacements`
inside `presentOverlays` to install viewport-coordinate frames and opacity on
the same presentation sample. The package owns geometry, not decoration views.

## Preparation, history, and lifecycle

Compatible preparation retains one active request and the newest pending one,
so streaming does not repeatedly cancel all useful work. Context/order changes
fence incompatible results. Pass `superseding: true` for non-monotonic edits,
redaction, or corrections whose older payload must never publish after the
request; ordinary streaming may publish active work before the newest pending plan. Direct `apply` supersedes outstanding preparation.
User input revokes an old prepared navigation without discarding valid content.
Providers must cooperate with task cancellation and keep expensive work off the
main actor; the package cannot bound an arbitrary renderer's internal work.

`onHistoryDemand` reports an eligible edge once per boundary. The adapter owns
fetching, cursors, ordering, deduplication, errors, and live-end certification.
After coverage-only progress or explicit retry, call `rearmHistoryDemand(at:)`
before publishing the resulting snapshot. Repeated content revisions alone do
not restart paging. `onPresentation` reports a native installation, not proof
that a frame reached the display. Do not replace the native scroll delegate or
its document view, mutate native insets, or drive a second animation clock.

One session has one attached host. Replacing a host detaches by owner identity;
application callbacks cannot overwrite the host hooks. `setActive` pauses clock
progress and preparation; `dispose` releases content, callbacks, and native cells.
Callbacks execute on the main actor. Snapshot publication from a publication
callback is rejected as reentrant; schedule the next transaction after it ends.

## Telegram parity: motion, navigation, events, reordering

These match Telegram iOS's `ListView` (`submodules/Display/Source`).

- **Motion.** `ChatListAnimation.motion(_:)` takes a `ChatListMotion`: a
  physical spring (any damping, evaluated analytically and velocity-preserving)
  or timed motion on a bezier curve. `.animated` is `.system`, the iOS 26
  system spring (stiffness 555.027, damping 47.118), which is Telegram's list
  and keyboard curve and `MessageMotion.standard`.
- **Keyboard.** Set `tracksKeyboard` on the UIKit host and pass the composer
  height with `setInsets(top:bottomAccessory:)`. The host lays a probe on
  `keyboardLayoutGuide`. During open and close, each frame reads the keyboard's
  presented edge and looks ahead to `CADisplayLink.targetTimestamp`: along the
  system spring on iOS 26 at 0.3832 s (Telegram makes the same check), and by
  measured velocity otherwise. The list therefore stays pinned to the edge, holds
  still until the keyboard starts, and stops at its own bottom. Interactive
  dismissal arrives synchronously in layout and is installed as `.nativeInput`.
  Both hosts present the state for `targetTimestamp` at up to 120 Hz.
- **Navigation.** `scroll(to: ChatListScrollRequest(id:position:direction:))`
  with `.top(offset)`, `.bottom(offset)`, `.center` or `.visible`. A nearby
  target scrolls there. Farther than one screen, the rows on screen stay and
  slide out together with the new screen touching them (Telegram's
  `temporaryPreviousNodes`); a direction picks the side. `apply(_:scrollTo:)`
  does the same when replacing the window. A retargeted scroll keeps its
  velocity. `.navigationFinished` reports arrival.
- **Row transitions.** `apply(_:transitions:)` picks `ChatListInsertion`
  (`grow`, `reveal`, `fade`, `none`) and `ChatListRemoval` (`collapse`,
  `collapseOpaque`, `none`) per row, and `animatesMoves` slides reordered rows
  from their old positions. `Placement.phase` carries entering/exiting progress
  on the list clock. Hosts call `didInsertCell`, `willRemoveCell` (with the
  presented frame, for dust-style effects) and `setCellHidden` (send transitions).
- **Visibility and events.** `onVisibleRangeChanged`, per-cell
  `updateCellVisibility` (fraction and viewport rect), `onScrollEvent`
  (began, dragging ended, ended, direction, navigation finished, released past
  an edge by 48 pt on iOS) and
  `onContentOffsetChanged` (distance from top and bottom, on-screen delta for
  views that follow the content). `frame(for:)` gives a row's viewport frame.
- **Sticky headers.** Decorations can pin to the viewport edge instead of the
  usable edge and can fade while stuck and idle (`hidesWhenIdle`, with
  Telegram's timing: 0.3 s after scrolling stops, 0.4 s out, 0.3 s in). Placements report `isStuck` and `stickDistance`.
- **Reordering.** Set `canReorder` and `isReorderingEnabled`. A 0.25 s press
  lifts a row with a shadow; it follows the touch, neighbors slide out of the
  way, the row changes slot at most every 0.2 s, and with its center within
  10 pt of an edge the list scrolls 360 pt/s, 540 after 2 s. Moves
  stay within the contiguous run of movable rows. `onReorder` reports the drop
  (`fromIndex`, `toIndex`, neighbors); content published during a drag waits
  for the drop. Haptics on lift and on each slot change.
- **Staged preparation.** `requestStagedPreparation` publishes the rows around
  the focus (or the newest rows) first and adds the rest in chunks with the
  anchor preserved, so a large window opens at first-frame cost. History
  demand for an edge waits until that edge's rows are installed.
- **Overscroll.** `topOverscrollColor` and `bottomOverscrollColor` fill the
  area revealed by a bounce on both hosts. Hosts preload 500 pt beyond the
  screen, like Telegram.

The list stays upright. Telegram rotates its chat list 180° (and every
message back) because its generic `ListView` lays out top-down; this core
derives the scroll origin from a bottom-or-row anchor every frame, so the
flip's benefits come without counter-rotating cells, selection, menus,
accessibility order, or effects.

## Tests and limits

Run `swift test --package-path apple/ChatList --jobs 2` from the repository root.
The standalone AppKit/UIKit lab uses these products and no Inline dependencies.
Set `usesAutomaticDisplayClock: false`, inject the session clock, and call
`advance(to:)` for deterministic experiments. Native frame-delivery tests must
also run with the automatic clock and real gestures on target hardware.

Geometry work during an animated transaction is linear in the installed row
window. Scroll lookup is indexed and native cells are bounded by the visible
range plus overscan and explicit/focus pins. One huge cell can still be expensive;
its renderer must bound its own layout and drawing. This package does not claim
unlimited history, universally zero pixel drift, or qualified 120 Hz delivery.

`InlineMacMessageList` is temporarily a compatibility facade for the existing
off-by-default macOS V2 adapter. Its engine/document types refer to this package,
with no second geometry implementation. The standalone hosts are qualified
independently before replacing all application controller lifecycle code.

## Successor lifecycle repair (October 2026)

This standalone package was exported from the parked experiment without adopting
its app controllers. Inline's feature gates and project targets are unchanged.

A session's current native host is its only native-input/viewport/clock owner.
`isCurrentHost(_:)` exposes that existing identity boundary to the platform
adapters. Replacing or explicitly detaching a host revokes its callbacks and
settles its outgoing drag/bounce before deferred content/navigation is admitted.
The old host may remain mounted, but cannot resize, scroll, pause, advance, or
report a presentation for the replacement. Application-owned session calls remain
available. A revocation calls the old presentation callback once so its native
clock stops; callback implementations must check current ownership before work.

`setActive(false, at:)` stops the attached host's actual automatic display link,
even when its native view remains mounted and its springs are unfinished.
Reactivation resumes from the frozen presentation. Snapshot installation validates
its prepared context and host identity again after both host and application
will-apply callbacks. A callback's width/context change rejects the outer snapshot
with `staleContext` before replacing installed rows; ownership changes reject it
with `reentrantTransaction`. The callback's own viewport change remains valid,
and a fresh snapshot can be prepared for it.

Focused regressions live in `ChatListPublicationTests` and the AppKit/UIKit
`ChatListOwnershipTests` suites. The native pause cases observe real display-link
callbacks before the activity guard, so a busy no-op clock cannot pass. UIKit
requires a physical-device test runner; a macOS package test does not execute it.

These repairs do not establish app integration, keyboard reversal/perceived-lag
acceptance, accessibility parity, or production readiness.
