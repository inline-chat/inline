#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

/// How the list gets its rows. Heights are exact and synchronous; the list asks only for rows near the viewport.
@MainActor
public struct TimelineRows<ID: Hashable & Sendable> {
  /// The row's height at this width.
  public var height: (ID, CGFloat) -> CGFloat
  /// A view showing the row at this width. The list sizes and places it.
  public var make: (ID, CGFloat) -> NSView
  /// The row's content or width changed while it is placed; animate inside with this timing.
  public var update: (ID, NSView, CGFloat, TimelineTiming) -> Void
  /// The row left the placed window.
  public var recycle: (ID, NSView) -> Void
  /// The view in a placed row that stays in sight while its span does (a sender's avatar); nil for most rows.
  /// Asked after every change, so a row can gain or lose it with its content. Also asked just before an animated
  /// update of a row that has none, with the row still laid out as before: a pin given then says where it would have
  /// rested, so one the change hands to the row (a regroup) starts there and moves with the row's insides.
  public var pin: (ID, NSView) -> TimelinePin<ID>?
  /// Where a pin's span starting at this row begins, in the row's coordinates.
  public var spanTop: (ID, NSView) -> CGFloat
  /// The last row of the span this row belongs to (a sender's group), when that row holds the span's pin: the
  /// list keeps it placed while any of the span shows.
  public var spanEnd: ((ID) -> ID?)?
  /// The first row of the span this row belongs to, when that row holds a top-edge pin (minimal style): the list keeps
  /// it placed while any of the span shows.
  public var spanStart: ((ID) -> ID?)?
  /// Where the content at `offsetInRow` (from the row's top, laid out at width `from`) sits at width `to`, in the
  /// row's coordinates: on a width change inside a message taller than the screen, the passage at the usable top stays
  /// there (nil: the row's top offset is kept, as for any row).
  public var passage: ((_ row: ID, _ offsetInRow: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat)?
  /// Where a deleted row shrinks to, in its own coordinates. Nil fades it without shrinking.
  public var removalFocus: ((ID, NSView) -> CGPoint?)?

  public init(
    height: @escaping (ID, CGFloat) -> CGFloat,
    make: @escaping (ID, CGFloat) -> NSView,
    update: @escaping (ID, NSView, CGFloat, TimelineTiming) -> Void = { _, _, _, _ in },
    recycle: @escaping (ID, NSView) -> Void = { _, _ in },
    pin: @escaping (ID, NSView) -> TimelinePin<ID>? = { _, _ in nil },
    spanTop: @escaping (ID, NSView) -> CGFloat = { _, _ in 0 },
    spanEnd: ((ID) -> ID?)? = nil,
    spanStart: ((ID) -> ID?)? = nil,
    passage: ((_ row: ID, _ offsetInRow: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat)? = nil,
    removalFocus: ((ID, NSView) -> CGPoint?)? = nil
  ) {
    self.height = height
    self.make = make
    self.update = update
    self.recycle = recycle
    self.pin = pin
    self.spanTop = spanTop
    self.spanEnd = spanEnd
    self.spanStart = spanStart
    self.passage = passage
    self.removalFocus = removalFocus
  }
}

/// A view inside a row that stays in sight while its span does: the sender's avatar beside a group of messages.
/// It rests at its place in the row; while that place is below the visible bottom edge the list lifts it to keep
/// its bottom on that edge, never above the top of its span. It moves with the list on every path the list moves
/// by: the trackpad, a fling (baked into the same render-server path), and the tracks of an animated change.
@MainActor
public struct TimelinePin<ID: Hashable & Sendable> {
  /// A descendant of the row view, laid out with `frame` (not constraints). The host sizes it and places it
  /// horizontally; the list owns its vertical place while the row is placed (the lift moves the frame) and puts it
  /// back at rest when the row leaves or no longer has the pin.
  public var view: NSView
  /// The view's bottom (from the row's top) and height at rest, in the row's coordinates: from the host's own
  /// layout, not read back from the view's frame, which the list moves.
  public var bottom: CGFloat
  public var height: CGFloat
  /// The row the span starts in, this row or an older one; `TimelineRows.spanTop` says where.
  public var spanStart: ID
  /// Which edge the pin keeps to. `.bottom` (bubble style): it rests at its row's bottom (the span's last row) and is
  /// lifted to keep its bottom on the visible bottom edge, never above its span's top. `.top` (minimal style, like
  /// section headers): it rests at its row's top (the span's first row) and is pushed down to keep its top on the
  /// visible top edge (plus `edgeGap`), never below its span's bottom.
  public var edge: TimelinePinEdge = .bottom
  /// For a top pin: the span's last row, and how far above that row's bottom the span ends.
  public var spanEnd: ID?
  public var spanBottomInset: CGFloat = 0
  /// For a top pin: how far below the usable top it sticks.
  public var edgeGap: CGFloat = 0

  public init(view: NSView, bottom: CGFloat, height: CGFloat, spanStart: ID) {
    self.view = view
    self.bottom = bottom
    self.height = height
    self.spanStart = spanStart
  }

  /// A pin that keeps to the top edge, held by the span's first row (`spanStart`, the row it is in), at `top` in that
  /// row; the span ends `spanBottomInset` above the bottom of `spanEnd`.
  public init(view: NSView, top: CGFloat, height: CGFloat, spanStart: ID, spanEnd: ID, spanBottomInset: CGFloat = 0, edgeGap: CGFloat = 0) {
    self.view = view
    bottom = top + height
    self.height = height
    self.spanStart = spanStart
    edge = .top
    self.spanEnd = spanEnd
    self.spanBottomInset = spanBottomInset
    self.edgeGap = edgeGap
  }
}

public enum TimelinePinEdge: Sendable { case bottom, top }

/// The section title floating at the top while the reader scrolls (the day of the topmost row). The list owns its
/// place; the host owns the view and its content.
@MainActor
public struct TimelineFloatingHeader<ID: Hashable & Sendable> {
  /// The view that floats. The list sizes it to its width and `height` and moves it.
  public var view: NSView
  public var height: CGFloat
  /// How far below the usable top it rests.
  public var gap: CGFloat
  /// The row that opens the section a row belongs to (that row itself for a section's own row); nil before any.
  public var section: (ID) -> ID?
  /// Shows the section's title in `view`; called when the section shown changes.
  public var configure: (NSView, ID) -> Void
  /// Shown only while the list moves and for `idleDelay` after (Telegram macOS: 2 s); false keeps it shown while it
  /// has a place.
  public var hidesWhenIdle: Bool
  public var idleDelay: TimeInterval
  /// Where the title sits in a section's own row, from its top: the header takes the title over when it reaches the
  /// header's place, so a row that draws the same title meets it exactly.
  public var ownInset: CGFloat
  /// The header carries on its section's own row's title (Telegram macOS: one pill that sticks, then is pushed off): a
  /// section's own row hides while its title is above the header's place, on the same path as the header.
  public var hidesOwnRow: Bool

  public init(
    view: NSView, height: CGFloat, gap: CGFloat = 0, section: @escaping (ID) -> ID?,
    configure: @escaping (NSView, ID) -> Void, hidesWhenIdle: Bool = true, idleDelay: TimeInterval = 2,
    ownInset: CGFloat = 0, hidesOwnRow: Bool = false
  ) {
    self.view = view
    self.height = height
    self.gap = gap
    self.section = section
    self.configure = configure
    self.hidesWhenIdle = hidesWhenIdle
    self.idleDelay = idleDelay
    self.ownInset = ownInset
    self.hidesOwnRow = hidesOwnRow
  }
}

/// One change to the list. Everything given here is resolved in one pass and moves with one timing.
/// Engine-wide switches, for labs that compare behaviours.
@MainActor
public enum TimelineListOptions {
  /// Row updates (heights, deletes, moves, pages, arrivals) that land while the user scrolls, with fingers down or a
  /// fling running short of an end, apply without animation, as Telegram's do (TableView.swift:4067). Measured in the
  /// update lab (2026-11-27, `update.*` drag and fling, animated → still): a deleted row's closing gap shown under the
  /// moving list 28–72 pt → 0; avatar errors 10–47 pt → 0; the floating date 3 pt off for 11 frames → 0; no speed
  /// spike on the reader either way (its place is kept). Still animated: inset changes (the composer animates, the list
  /// follows it on the same timing: unanimated, avatars missed the edge by 33–50 pt), arrivals at the newest end and
  /// updates during a bounce past an end (unanimated, rows a reorder brought in jumped 2,700 pt/s). True animates them
  /// all as at rest
  /// (TL_ANIMATE_UPDATES_WHILE_SCROLLING=1 in the lab).
  public static var animatesUpdatesWhileScrolling = false
  /// A row that changes place among the others (a reorder) lands at its new place fading in, as Telegram's moves do (a
  /// delete and an insert), while its neighbours close and open on the row spring. Measured in the update lab
  /// (2026-11-27, slide → fade): a pinned swap's gap at the bottom 11.9 → 0 pt, a reopening gap 7.6 → 3.5 pt, an avatar
  /// mid-jump 30 → 0 pt, the fuzz's worst blank 43 → 0 pt. False slides it there past its neighbours
  /// (TL_SLIDE_MOVES=1 in the lab).
  public static var fadesMoves = true
}

public struct TimelineTransaction<ID: Hashable & Sendable> {
  public var rows: [ID]?
  public var coverage: TimelineCoverage?
  public var scroll: TimelineScroll<ID>
  public var topInset: CGFloat?
  public var bottomInset: CGFloat?
  /// Rows whose content (and maybe height) changed.
  public var changed: Set<ID>
  public var timing: TimelineTiming
  /// Rows new to the data arrive as new messages do: rising from below and fading in. Off for rows that were
  /// history all along (a page, a jump), which come in with the scroll.
  public var arrives: Bool
  /// A jump to rows that are not near: the side they lie on when the rows cannot tell.
  public var towards: TimelineEdge?

  public init(
    rows: [ID]? = nil, coverage: TimelineCoverage? = nil, scroll: TimelineScroll<ID> = .preserve,
    topInset: CGFloat? = nil, bottomInset: CGFloat? = nil, changed: Set<ID> = [], timing: TimelineTiming = .none,
    arrives: Bool = true, towards: TimelineEdge? = nil
  ) {
    self.rows = rows
    self.coverage = coverage
    self.scroll = scroll
    self.topInset = topInset
    self.bottomInset = bottomInset
    self.changed = changed
    self.timing = timing
    self.arrives = arrives
    self.towards = towards
  }
}

/// One trackpad gesture as the list played it, next to the system's momentum events for the same gesture (which the
/// list does not apply): the reference for how far and how fast a fling should go on a real device.
public struct TimelineGestureRecord: Sendable, Encodable {
  /// Content travel while the fingers were down, and for how long.
  public var trackedTravel: Double = 0
  public var trackedDuration: Double = 0
  public var trackedEvents = 0
  /// The release velocity estimated from the last events (pt/s, positive: content moves down), and the gain on it.
  public var releaseVelocity: Double = 0
  public var gain: Double = 1
  /// The fling the list played: its travel and duration (nil: no fling).
  public var flingTravel: Double?
  public var flingDuration: Double?
  /// The system's momentum events after the lift: how many, their total travel, the first one's delta and its
  /// delay after the lift, and their span.
  public var momentumEvents = 0
  public var momentumTravel: Double = 0
  public var momentumFirstDelta: Double = 0
  public var momentumFirstDelay: Double = 0
  public var momentumDuration: Double = 0
  /// The first momentum events (seconds after the first one, delta), to fit the system's decay.
  public var momentumSamples: [[Double]] = []
  /// The tracked events before the lift, up to 64 (seconds before the lift, delta): enough to replay the gesture.
  public var lastTracked: [[Double]] = []
  /// Each frame of the coast after the lift, up to 400: seconds after the lift, the step shown (pt), seconds since
  /// the previous frame's tick (a missed frame shows as a long one), the frame's own work (ms), 1 when momentum
  /// events drove it.
  public var coastFrames: [[Double]] = []
  var lastCoastTick: CFTimeInterval = 0

  var began: CFTimeInterval = 0
  /// When the fingers lifted (event time, the media clock's base).
  public internal(set) var released: CFTimeInterval = 0
  var firstMomentum: CFTimeInterval = 0
  var tracked: [(time: CFTimeInterval, delta: Double)] = []

  enum CodingKeys: String, CodingKey {
    case trackedTravel, trackedDuration, trackedEvents, releaseVelocity, gain, flingTravel, flingDuration
    case momentumEvents, momentumTravel, momentumFirstDelta, momentumFirstDelay, momentumDuration, momentumSamples
    case lastTracked, coastFrames
  }
}

/// Which fling the list plays after the fingers lift.
public enum TimelineFling {
  /// NSScrollView's: AppKit's calculator from 0.9 × the fingers' speed, baked once at the lift (within 2–8% of
  /// NSScrollView's travel on Mo's recorded gestures, NSScrollView lane phase 5). Off: the system's momentum shape,
  /// re-baked at its first event (about twice NSScrollView's travel), kept for Mo's comparison.
  nonisolated(unsafe) public static var followsNSScrollView = true
}

public struct TimelineDiagnostics: Sendable {
  /// The scroll position the settled layout is at, and the one on screen.
  public var scrollPosition: CGFloat
  public var presentedScrollPosition: CGFloat
  public var placedCount: Int
  public var lingeringCount: Int
  public var pooledCount: Int
  public var isFlinging: Bool
  public var isTracking: Bool
  /// Time spent in the last `perform` (solver, realisation, commit), in seconds.
  public var lastPerformDuration: CFTimeInterval
  /// Rows made since the list was created.
  public var makes: Int
  /// Every `perform` so far: how many, and the time they took in all (seconds).
  public var performCount: Int
  public var totalPerformDuration: CFTimeInterval
  /// Time spent putting rows into the window (seconds, in all): a slot view for each new row (~20 µs) and AppKit
  /// attaching the row's view tree (~60 µs for a lab row), which is the rows' cost of appearing more than the list's.
  public var totalAttachDuration: CFTimeInterval
  /// The frame rate the list's ticks ask for while they run (nil when paused): a coast moves the content from them.
  public var tickRate: CAFrameRateRange?
  /// AppKit layout passes so far.
  public var layoutPasses = 0
  /// A far jump's slide is running (the floating date is hidden by design).
  public var isSliding = false
}

/// The macOS message list. No NSScrollView and no global content height: the solver places the rows near the
/// viewport, this view realises them, and every movement is the trackpad (applied as it comes), a fling baked once
/// and played by the render server, or an additive track.
///
/// Coordinates: rows live in `content`, a flipped view whose bounds origin is the scroll position; a row keeps its
/// content coordinate while the list scrolls, so scrolling moves one layer.
@MainActor
public final class TimelineListView<ID: Hashable & Sendable>: NSView {
  public var rows: TimelineRows<ID>

  /// Loaded ends the window is near that are not real ends.
  public var onDemand: ((Set<TimelineEdge>) -> Void)?
  /// After every change, with the settled layout.
  public var onLayout: ((TimelineLayout<ID>) -> Void)?
  /// The reader took hold of the list (a trackpad touch, a wheel notch, a key).
  public var onScrollBegan: (() -> Void)?
  /// The list came to rest after the reader moved it.
  public var onScrollEnded: (() -> Void)?
  /// A gesture that is mostly horizontal, from its first event to its last, with the row it started on. Return
  /// true to take it (swipe to reply); false sends it up the responder chain.
  public var onHorizontalScroll: ((NSEvent, ID?) -> Bool)?
  /// Each trackpad gesture once its momentum events end (diagnostics: real-device fling calibration).
  public var onGestureRecord: ((TimelineGestureRecord) -> Void)?
  var gestureRecord: TimelineGestureRecord?
  public var showsScrollIndicator = true {
    didSet { if !showsScrollIndicator { indicatorView.alphaValue = 0 } }
  }

  /// The floating section header, when the host has one.
  public var floatingHeader: TimelineFloatingHeader<ID>? {
    didSet {
      oldValue?.view.removeFromSuperview()
      headerShown = nil
      headerTitle = nil
      headerBakedSection = nil
      if let header = floatingHeader {
        headerContainer.addSubview(header.view)
        header.view.wantsLayer = true
        headerContainer.alphaValue = header.hidesWhenIdle && !isMoving ? 0 : 1
      }
      updateFloatingHeader(timing: .none)
    }
  }

  public internal(set) var isTracking = false
  public var isFlinging: Bool { flight != nil || coast != nil }
  /// The list is moving: the trackpad holds it, a fling runs, or a wheel scroll has not settled.
  public var isMoving: Bool { isTracking || flight != nil || coast != nil || restWork != nil }
  public var timelineLayout: TimelineLayout<ID> { state.layout }
  /// The row layouts anchor on when not pinned (`TimelineReadingAnchor`).
  public var readingAnchor: TimelineReadingAnchor {
    get { state.readingAnchor }
    set { state.readingAnchor = newValue }
  }
  public var position: TimelinePosition<ID> { state.position }
  public var topInset: CGFloat { insets.top }
  public var bottomInset: CGFloat { insets.bottom }
  public var rowIDs: [ID] { state.rows }

  nonisolated override public var isFlipped: Bool { true }
  override public var acceptsFirstResponder: Bool { true }
  /// AppKit's own scroll-related machinery stays out: this view is not a scroll view.
  override public class var isCompatibleWithResponsiveScrolling: Bool { false }

  var state: TimelineState<ID>
  /// The rows' parent. Flipped; its bounds origin is the scroll position.
  public let content = TimelineContentView()
  var slots: [ID: Slot] = [:]
  /// Rows no longer in the placed window that an animation still shows.
  var lingering: [ID: (slot: Slot, expiry: CFTimeInterval)] = [:]
  /// Pictures of moved rows at their old places, fading out (`leaveGhost`).
  var ghosts: [(id: ID, view: NSView)] = []
  var slotPool: [Slot] = []
  static var slotPoolLimit: Int { 32 }
  /// The scroll position the state's layout is expressed against: content y = viewport y + origin.
  var origin: CGFloat = 0
  /// The content's own scroll tracks (an animated change, a far jump's slide), for the model to follow while they run.
  var contentTracks: [ContentTrack] = []
  /// The time the content's model follows while a tick prepares its frame (the frame's display time).
  var followTime: CFTimeInterval?
  /// How far the content's model is from where it settles: nonzero while it follows a motion.
  var followOffset: CGFloat = 0
  var insets: (top: CGFloat, bottom: CGFloat) = (0, 0)
  var isApplying = false
  var queued: [() -> Void] = []
  var beforeFirstLayout: [TimelineTransaction<ID>] = []
  var lastPerformDuration: CFTimeInterval = 0
  var totalPerformDuration: CFTimeInterval = 0
  var totalAttachDuration: CFTimeInterval = 0
  var performCount = 0
  var makes = 0

  // Input
  var flight: Flight?
  /// The motion after a lift, driven on the main thread (`TimelineListView+Coast`).
  var coast: Coast?
  /// Lifts coast on the main thread (rows ready on every frame) rather than baking a render-server fling. Off: in the
  /// app a frame's work while flinging was 6–26 ms (85 ms at worst), so main-thread motion dropped frames ("frame loss,
  /// not smooth"); the render server keeps the motion at the display's rate whatever the main thread does.
  public var coastsOnMainThread = false
  /// The momentum events of the gesture whose lift started the running fling: when the last came, and whether one has.
  var momentumSteer: (last: CFTimeInterval, started: Bool)?
  /// How far ahead of what is shown the content's model is put while it follows a motion: AppKit draws the rows the
  /// next frame brings in before it shows them (without it, a row or two at the leading edge showed undrawn).
  static var followLead: CFTimeInterval { 1.0 / 60 }
  /// The first momentum event of a lift re-bakes its fling once, at the system's speed (our estimate from the finger
  /// events was 0.95–2.4× off it in real gestures). Only once: re-baking on every event committed late in the app and
  /// the content jumped.
  static var steersByMomentum: Bool { true }
  /// Rows from a loaded end at which the host is asked for more history. Far enough that a page from the
  /// database lands before a fast fling reaches the edge (12 rows were about 150 ms at 8,000 pt/s).
  public var demandThreshold: Int {
    get { state.demandThreshold }
    set { state.demandThreshold = newValue }
  }
  var link: CADisplayLink?
  var velocity = WheelVelocity()
  /// The fingers' speed as NSScrollView reads it for its fling.
  var finger = FingerVelocity()
  /// How far the trackpad has pulled past an end, before the rubber band.
  var pulled: CGFloat = 0
  /// A touch stopped a fling; if it lifts without moving, the content rests (or returns from past an end).
  var caughtFlight = false
  /// A gesture that is mostly horizontal is not the list's: it goes to `onHorizontalScroll` or up the chain.
  var gestureIsHorizontal = false
  var horizontalTaken = false
  var restWork: DispatchWorkItem?

  // Sticky
  /// Rows new to the data that take over a pin shown on screen, from this change: the old pin's centre on screen
  /// (in this view) and how far the row starts from its place.
  var avatarArrivals: [ID: (from: CGFloat, offset: CGFloat)] = [:]
  /// For an animated change: how far each placed row starts on screen from where it settles (all of it moving on the
  /// change's timing), and the same for the visible bottom edge. Pins follow from these.
  var rowStarts: [ID: CGFloat] = [:]
  /// Rows the change being committed reordered: they land at their new place fading in, as if new there.
  var landedMoves: Set<ID> = []
  var edgeStart: CGFloat = 0
  /// As `edgeStart`, for the usable top (top pins).
  var topEdgeStart: CGFloat = 0
  /// AppKit layout passes so far (diagnostics: a layout every frame with nothing changing is a loop).
  var layoutPasses = 0
  /// When the change being committed started: its row tracks, scroll motion and pin changes share it.
  var commitTime: CFTimeInterval = 0
  /// Rows whose content the change being committed changed (the host animates their insides), with how much their
  /// height changed: a pin new to such a row rests on its bubble's bottom, which grows from where it was.
  var contentResized: [ID: CGFloat] = [:]
  /// Where a pin rested in its row before the change being committed, for rows the change updates that had no pin:
  /// the host's own answer from the row's old layout (`rows.pin` asked before the row's update).
  var pinRestBefore: [ID: (view: NSView, top: CGFloat)] = [:]
  /// Reduce Motion (System Settings > Accessibility > Display): jumps and pages land at once, and new messages fade in
  /// without rising. Follows the system; a host or a test may set it.
  public var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  var reduceMotionObserver: NSObjectProtocol?
  /// Animated scrolls still running (jumps, animated pages): a touch or a wheel stops them where they show.
  var scrollMotions: [ScrollMotion] = []
  /// The row an animated jump is taking to a place, until the jump's motion ends. The solver anchors every layout on
  /// the lowest visible row, so an update during the jump (a row between the two growing, a delete, a composer change)
  /// moved the target off the place the jump was asked for (48–164 pt in the update lab); updates during the jump keep
  /// the target there instead. A touch, a wheel, a drag or another scroll ends it.
  var jumpTarget: (id: ID, alignment: TimelineAlignment, until: CFTimeInterval)?
  /// The running fling bounced on the newest end (or is returning to it): growth of the newest or arrivals during the
  /// bounce move that end away (the solver keeps the newest's top while bounced), and the fling came to rest short of
  /// it, unpinned (63–76 pt in the update lab, the stream then growing below the screen). Its rest glides on to the
  /// end, pinned.
  var flightBouncedOnNewest = false
  /// A far jump's slide is running until then: its two strips (the screen sliding out, the destination in) are joined
  /// across rows that are not in the layout, so an update moving rows mid-slide pulled the destination away from the
  /// strip still on screen, and rows placed above the destination landed on it (78 pt overlap in the update lab). Row
  /// updates wait for the slide to end (its timing, 0.38 s at most) and land then, in order; inset changes do not wait.
  var carouselUntil: CFTimeInterval = 0
  var deferredDuringCarousel: [TimelineTransaction<ID>] = []

  struct ScrollMotion {
    var start: CFTimeInterval
    var timing: TimelineTiming
    /// How far the content shows from where it settles when the motion starts (q = 1), on screen.
    var travel: CGFloat
    /// The key numbers of the tracks the change added: rows and content, pins, the floating header, the knob.
    var tracks: Range<Int>
    var pins: Range<Int>
    var header: Range<Int>
    var indicator: Range<Int>

    @MainActor func owns(_ key: String) -> Bool {
      func number(after prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
      }
      if let n = number(after: "timeline.track.") { return tracks.contains(n) }
      if let n = number(after: "\(TimelineListView.pinKey).") { return pins.contains(n) }
      if let n = number(after: "\(TimelineListView.headerKey).track.") { return header.contains(n) }
      if let n = number(after: "\(TimelineListView.indicatorTrackKey).") { return indicator.contains(n) }
      return false
    }
  }
  var pinTrackCount = 0
  let headerContainer = TimelinePassthroughView()
  /// The header as last placed: its section and its top (this view's coordinates) with the content where it
  /// settles; nil while hidden.
  var headerShown: TimelineFloatingHeaderPlace<ID>?
  var headerFlightStart: CFTimeInterval?
  /// The section the header view shows (its title), and the one the running flight's path was baked for: along a flight
  /// the section on screen now leads, which need not be where the flight ends (`headerShown`).
  var headerTitle: ID?
  var headerBakedSection: ID?
  var headerHide: DispatchWorkItem?
  var headerTrackCount = 0

  // Scroll indicator
  let indicatorView = TimelineScrollIndicatorView()
  var indicator = TimelineIndicator(progress: 1)
  var indicatorHide: DispatchWorkItem?
  var indicatorLength: CGFloat = 0
  var indicatorLengthKey: IndicatorLengthKey?
  var indicatorFlight: (start: CFTimeInterval, progress: CGFloat, extent: TimelineIndicator.Extent, applied: Double)?
  var indicatorTrackCount = 0
  /// Where a drag holds the knob, from its top.
  var indicatorGrab: CGFloat?

  public final class TimelineContentView: NSView {
    nonisolated override public var isFlipped: Bool { true }
  }

  @MainActor final class Slot {
    let view: SlotView
    var row: NSView
    var y: CGFloat = 0
    var height: CGFloat = 0
    var width: CGFloat = 0
    var pin: PinState?
    /// Animated height changes still running: the row's insides move on them (the host animates them on the change's
    /// timing), so what shows is the settled height plus what each still has to go.
    var heightTracks: [(start: CFTimeInterval, timing: TimelineTiming, from: CGFloat)] = []
    /// The animated changes its pin's lift still follows.
    var pinChanges: [PinChange] = []
    /// A section's own row hidden under the floating header (`hidesOwnRow`): the flight and the row's place there it
    /// was baked for.
    var sectionBake: (flightStart: CFTimeInterval, y: CGFloat)?

    /// The height as it shows at `now`.
    func presentedHeight(at now: CFTimeInterval) -> CGFloat {
      guard !heightTracks.isEmpty else { return height }
      heightTracks.removeAll { $0.timing.remaining(at: now - $0.start) <= 0 }
      return height + heightTracks.reduce(0) { $0 + $1.from * CGFloat($1.timing.remaining(at: now - $1.start)) }
    }

    init(row: NSView) {
      self.row = row
      view = SlotView(frame: .zero)
      view.addSubview(row)
    }
  }

  final class SlotView: NSView {
    /// Brings the row fully into view (accessibility's "scroll to visible", VoiceOver moving to a partly hidden row).
    var reveal: (() -> Void)?

    nonisolated override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // A row for accessibility: a group holding the host's row. Scroll to visible goes to the list, which is not a
    // scroll view (and does not take `scrollRectToVisible` from its rows: a text view inside a row calls that on
    // selection and hover, which is how the old list leapt).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    /// The row view's label (the host says what the row is: a message's sender and time), read before its contents.
    override func accessibilityLabel() -> String? { subviews.first?.accessibilityLabel() }
    nonisolated static var scrollToVisible: NSAccessibility.Action { NSAccessibility.Action(rawValue: "AXScrollToVisible") }

    // The older action methods are the only route for AXScrollToVisible (AppKit has no protocol method for it and
    // does nothing with it on a plain view; tested on macOS 27).
    @available(macOS, deprecated: 10.10, message: "The only route for AXScrollToVisible")
    override func accessibilityActionNames() -> [NSAccessibility.Action] {
      super.accessibilityActionNames() + [Self.scrollToVisible]
    }

    @available(macOS, deprecated: 10.10, message: "The only route for AXScrollToVisible")
    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
      guard action == Self.scrollToVisible else { return super.accessibilityPerformAction(action) }
      MainActor.assumeIsolated { reveal?() }
    }
  }

  /// A pin as last applied, with the content where it settles, and the flight its path was baked for.
  /// An animated change a pin's lift follows: it moves the pin's bottom less the edge by `overhangSlope × q(t)` and its
  /// span's top by what makes `maxLift` move `maxLiftSlope × q(t)` (q: how much of the change remains).
  struct PinChange {
    var start: CFTimeInterval
    var timing: TimelineTiming
    var overhangSlope: CGFloat
    var maxLiftSlope: CGFloat
    /// The change's tracks start when its transaction commits (no begin time of their own), a few milliseconds after
    /// `start`; once committed, `start` is read back from the pin's bake, which began with them.
    var resolved = false
  }

  struct PinState {
    let view: NSView
    /// The span it belongs to, as last applied (the host's data may already have moved on when a change reads it).
    let spanStart: ID
    /// Its resting place in the row, top-down: `minY` and `height`.
    let rest: CGRect
    /// The geometry, for a top pin in mirrored coordinates (y down becomes y up: its top edge, rest top and span
    /// bottom read as a bottom pin's edge, rest bottom and span top), so one set of bakes serves both edges.
    var geometry: TimelinePinGeometry
    var flightStart: CFTimeInterval?
    /// +1 for a bottom pin, −1 for a top pin: content shifts, row and edge offsets and the lift's direction on screen
    /// enter the mirrored geometry with this sign.
    var mirror: CGFloat = 1

    func matches(_ other: PinState) -> Bool {
      view === other.view && spanStart == other.spanStart && flightStart == other.flightStart
        && geometry.isClose(to: other.geometry)
    }
  }

  /// A fling being played by the render server.
  struct Flight {
    var path: ScrollPath
    /// Media time of the path's first sample.
    var start: CFTimeInterval
    /// The path displacement the state has been moved to so far.
    var applied: Double
    var lower: Double?
    var upper: Double?
    /// The momentum decay the fling was released with, kept when it is re-baked mid-way.
    var tau: Double?
    /// A fling on AppKit's calculator, as NSScrollView's (`TimelineFling.followsNSScrollView`): it stops only at real
    /// ends, as the system-shaped fling does, and a re-bake continues on the calculator.
    var appKitFling = false

    /// How far the content on screen is from the state's layout at `time` (positive: further down).
    func shift(at time: CFTimeInterval) -> CGFloat {
      CGFloat(path.position(at: min(max(0, time - start), path.duration)) - applied)
    }

    /// How far the model (the path's end) is from the state's layout.
    var ahead: CGFloat { CGFloat(path.end - applied) }
  }

  /// A scroll track on the content: from `from` (in its bounds origin) to zero, with `timing`, from `start`.
  struct ContentTrack {
    var serial: Int
    var start: CFTimeInterval
    var timing: TimelineTiming
    var from: CGFloat
  }

  struct IndicatorLengthKey: Equatable {
    var rows: Int
    var coverage: TimelineCoverage
    var track: CGFloat
  }

  static var flightKey: String { "timeline.flight" }
  /// The constant that keeps what is shown where the motions put it while the content's model follows them.
  static var followKey: String { "timeline.follow" }
  static var pinKey: String { "timeline.pin" }
  static var headerKey: String { "timeline.header" }
  static var sectionRowKey: String { "timeline.section-row" }
  static var indicatorFlightKey: String { "timeline.indicator.flight" }
  static var indicatorTrackKey: String { "timeline.indicator.track" }
  /// Seconds of travel realised beyond the standard margins while flinging.
  static var lookahead: CGFloat { 0.1 }
  /// Points the realised margin may grow by per tick beyond the tick's own travel.
  static var lookaheadGrowth: CGFloat { 48 }

  public init(rows: TimelineRows<ID>) {
    self.rows = rows
    state = TimelineState(viewport: TimelineViewport(width: 0, height: 0))
    // Slivers don't anchor: the row being read holds when one below it grows (see `TimelineState.readingAnchor`).
    state.readingAnchor = .lowestShowing(44)
    super.init(frame: .zero)
    reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
    state.demandThreshold = 40
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.masksToBounds = true
    content.wantsLayer = true
    content.layerContentsRedrawPolicy = .never
    addSubview(content)
    headerContainer.wantsLayer = true
    addSubview(headerContainer)
    addSubview(indicatorView)
    indicatorView.alphaValue = 0
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  isolated deinit {
    if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    link?.invalidate()
  }

  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard !isInvalidated else { return }
    if window == nil, flight != nil { endFlight(settle: true) }
    if window == nil, coast != nil { stopCoast() }
    // A link belongs to the window's display: a new one for a new window.
    stopTicking()
    if window != nil { updateTicking() }
  }

  // MARK: - Teardown

  /// Set by `invalidate()`.
  public private(set) var isInvalidated = false

  /// The host is going away. Its view can stay in the window after the host is gone (a chat switch keeps the old chat
  /// until the next chat's first frame) while motion and delayed work still run: with the host's rows gone they laid
  /// out every row at 0 pt, up to the ends of the chat (review, 2026-11-27). From here the list stops its motion and
  /// pending work and ignores changes, layout and input; what it shows stays as it is.
  public func invalidate() {
    guard !isInvalidated else { return }
    if flight != nil { endFlight(settle: false) }
    if coast != nil { stopCoast() }
    stopTicking()
    for work in [restWork, lingerSweep, headerHide, indicatorHide] { work?.cancel() }
    restWork = nil
    lingerSweep = nil
    headerHide = nil
    indicatorHide = nil
    deferredDuringCarousel = []
    beforeFirstLayout = []
    isInvalidated = true
  }

  // MARK: - Changes

  /// The single way the list changes.
  public func apply(_ transaction: TimelineTransaction<ID>) {
    guard !isInvalidated else { return }
    if transaction.scroll == .preserve, transaction.topInset == nil, transaction.bottomInset == nil,
       CACurrentMediaTime() < carouselUntil, window != nil
    {
      deferredDuringCarousel.append(transaction)
      if deferredDuringCarousel.count == 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, carouselUntil - CACurrentMediaTime()) + 0.01) { [weak self] in
          MainActor.assumeIsolated { self?.flushDeferredUpdates() }
        }
      }
      return
    }
    // Anything else (a scroll, an inset) lands after what waited, in order.
    if !deferredDuringCarousel.isEmpty, transaction.scroll != .preserve || transaction.topInset != nil || transaction.bottomInset != nil {
      flushDeferredUpdates()
    }
    if let top = transaction.topInset { insets.top = top }
    if let bottom = transaction.bottomInset { insets.bottom = bottom }
    guard bounds.width > 0, bounds.height > 0 else {
      var waiting = transaction
      waiting.timing = .none
      beforeFirstLayout.append(waiting)
      return
    }
    // Sized before its first layout (a host placing rows from its own layout pass): the content takes the size now,
    // or the rows would be realised in an empty content view, where AppKit does not draw them.
    if content.frame != bounds {
      content.frame = bounds
      headerContainer.frame = bounds
    }
    followSizeChange()
    var update = TimelineUpdate<ID>(
      rows: transaction.rows, coverage: transaction.coverage, viewport: viewport(), scroll: transaction.scroll
    )
    // A reorder that moves the reading row itself (a pending message confirmed past its neighbour): the place goes to
    // the nearest row that kept its order, newer first, as a deleted reading row's does (Telegram's moves are a delete
    // and an insert). Anchored on the moved row, everything else shifted by the row it passed: 42 pt in one frame
    // mid-bounce (`update.reorderPending`).
    var reorders = false
    if transaction.scroll == .preserve, jumpTarget == nil, let newRows = transaction.rows {
      var newIndex: [ID: Int] = [:]
      newIndex.reserveCapacity(newRows.count)
      for (i, id) in newRows.enumerated() where newIndex[id] == nil { newIndex[id] = i }
      let placed = state.layout.placements.filter { newIndex[$0.id] != nil }
      let moved = Self.outOfOrder(placed.map { newIndex[$0.id]! }, weights: placed.map(\.height))
      reorders = !moved.isEmpty
      if case let .row(anchor, _) = state.position, let at = placed.firstIndex(where: { $0.id == anchor }), moved.contains(at) {
        let newer = placed[(at + 1)...].enumerated().first { !moved.contains(at + 1 + $0.offset) }?.element
        let older = placed[..<at].enumerated().reversed().first { !moved.contains($0.offset) }?.element
        if let neighbour = newer ?? older {
          update.scroll = .to(neighbour.id, .top(neighbour.y - state.viewport.usableTop))
        }
      }
    }
    // An update during an animated jump keeps the jump's target where it was asked to be (the state only: this is
    // not a new jump, so no carousel, no takeover, its own timing).
    if transaction.scroll == .preserve, let target = jumpTarget {
      let survives = transaction.rows.map { $0.contains(target.id) } ?? (state.index[target.id] != nil)
      if CACurrentMediaTime() < target.until, survives, !isTracking, flight == nil, coast == nil {
        update.scroll = .to(target.id, target.alignment)
      } else {
        jumpTarget = nil
      }
    } else if transaction.scroll != .preserve {
      jumpTarget = nil
    }
    if isTracking {
      update.followsBottomInset = false
      update.pinsWhenAtBottom = false
      update.allowsOverscroll = true
    } else if flight != nil || coast != nil {
      update.allowsOverscroll = true
    }
    let takesOverFlight = transaction.scroll != .preserve && (flight != nil || coast != nil) && !isTracking
    if takesOverFlight {
      stopCoast()
      endFlight(settle: false)
    }
    var jump: TimelineEdge??
    switch transaction.scroll {
      case .latest, .to: jump = .some(transaction.towards)
      case .preserve, .by: jump = nil
    }
    var timing = reducesMotion && transaction.scroll != .preserve ? .none : transaction.timing
    // Arrivals at the newest end keep their rise: a fling heading there shows them (unanimated, the rows a reorder
    // brought in jumped 2,700 pt/s mid-fling in the update lab).
    let arrivesAtNewest = transaction.rows.map { rows in rows.last.map { state.index[$0] == nil } ?? false } ?? false
    // Reorders too: a row changing place is something to follow, not a height to absorb (unanimated mid-fling, the rows
    // around it jumped by the height of the row it passed, 42 pt).
    if !TimelineListOptions.animatesUpdatesWhileScrolling, transaction.scroll == .preserve,
       transaction.topInset == nil, transaction.bottomInset == nil, !arrivesAtNewest, !reorders,
       isTracking || ((flight != nil || coast != nil) && abs(state.layout.restShift) <= 0.25)
    {
      timing = .none
    }
    perform(update, timing: timing, changed: transaction.changed, jump: jump, arrives: transaction.arrives)
    if takesOverFlight { onScrollEnded?() }
    if case let .to(id, alignment) = transaction.scroll, timing.isAnimated {
      jumpTarget = (id, alignment, CACurrentMediaTime() + timing.duration)
    }
  }

  public func setInsets(top: CGFloat? = nil, bottom: CGFloat? = nil, timing: TimelineTiming = .none) {
    apply(TimelineTransaction(topInset: top, bottomInset: bottom, timing: timing))
  }

  /// The row's settled frame in this view's coordinates, when it is placed.
  public func frame(for id: ID) -> CGRect? {
    state.layout.placement(for: id).map { CGRect(x: 0, y: $0.y, width: bounds.width, height: $0.height) }
  }

  /// The view showing the row, when it is placed.
  public func view(for id: ID) -> NSView? {
    slots[id]?.row
  }

  /// Every placed row view, by id.
  public var placedViews: [(ID, NSView)] {
    slots.map { ($0.key, $0.value.row) }
  }

  /// Every row view on screen, placed or lingering after an animated change, by id.
  public var shownViews: [(ID, NSView)] {
    slots.map { ($0.key, $0.value.row) } + lingering.map { ($0.key, $0.value.slot.row) }
  }

  /// Where the row is on screen right now, in this view's coordinates: its presented top and its presented height (an
  /// animated height change is still under way: the settled height alone put a growing row's bottom up to 34 pt past
  /// what showed, and a shrinking one's short of it).
  public func presentedFrame(for id: ID) -> CGRect? {
    guard let slot = slots[id] ?? lingering[id]?.slot, let layer = slot.view.layer else { return nil }
    let row = layer.presentation() ?? layer
    return CGRect(
      x: row.frame.minX, y: row.frame.minY - presentedOrigin, width: slot.width,
      height: slot.presentedHeight(at: CACurrentMediaTime())
    )
  }

  /// Where a view inside a row (or the floating header) is on screen right now, in this view's coordinates,
  /// with every animation on the way (content scroll, row tracks, a pin's lift) as presented.
  public func presentedFrame(of view: NSView) -> CGRect? {
    // A row itself: its presented height (its layer's bounds are the settled ones).
    if let id = slots.first(where: { $0.value.row === view })?.key ?? lingering.first(where: { $0.value.slot.row === view })?.key {
      return presentedFrame(for: id)
    }
    guard let target = view.layer, let mine = layer else { return nil }
    let from = target.presentation() ?? target
    let to = mine.presentation() ?? mine
    return from.convert(from.bounds, to: to)
  }

  /// The row on screen at a point in this view's coordinates, as presented now.
  public func row(atPresented point: NSPoint) -> ID? {
    for id in slots.keys {
      guard let frame = presentedFrame(for: id) else { continue }
      if point.y >= frame.minY, point.y < frame.maxY { return id }
    }
    return nil
  }

  /// Stops a fling where it is on screen.
  public func stopScrolling() {
    catchFlight()
    caughtFlight = false
  }

  /// Starts a fling as if a trackpad let go at this velocity (points per second, positive: content moves down).
  public func fling(velocity: CGFloat) {
    catchFlight()
    caughtFlight = false
    release(velocity: velocity)
  }

  var presentedOrigin: CGFloat {
    let contentLayer = content.layer!
    return (contentLayer.presentation() ?? contentLayer).bounds.origin.y
  }

  public var diagnostics: TimelineDiagnostics {
    TimelineDiagnostics(
      scrollPosition: origin, presentedScrollPosition: presentedOrigin, placedCount: slots.count,
      lingeringCount: lingering.count, pooledCount: slotPool.count, isFlinging: flight != nil || coast != nil, isTracking: isTracking,
      lastPerformDuration: lastPerformDuration, makes: makes, performCount: performCount,
      totalPerformDuration: totalPerformDuration, totalAttachDuration: totalAttachDuration,
      tickRate: link.flatMap { $0.isPaused ? nil : $0.preferredFrameRateRange }, layoutPasses: layoutPasses,
      isSliding: CACurrentMediaTime() < carouselUntil
    )
  }

  override public func layout() {
    super.layout()
    guard !isInvalidated else { return }
    layoutPasses &+= 1
    content.frame = bounds
    headerContainer.frame = bounds
    syncOrigin()
    let viewport = viewport()
    guard viewport.width > 0, viewport.height > 0 else { return }
    if !beforeFirstLayout.isEmpty {
      let waiting = beforeFirstLayout
      beforeFirstLayout = []
      for transaction in waiting { apply(transaction) }
    }
    if viewport != state.viewport {
      perform(sizeUpdate(viewport), timing: .none, changed: [])
    }
    placeIndicator(timing: .none)
  }

  /// A size change, laid out as `apply` lays out under motion: past an end mid-bounce the content stays where the bounce
  /// has it (laid out without overscroll, it snapped inside its limits while the bounce played on: 42 pt in one frame,
  /// 3,000–4,000 pt/s, update lab `update.widthDuringGrow`).
  func sizeUpdate(_ viewport: TimelineViewport) -> TimelineUpdate<ID> {
    var update = TimelineUpdate<ID>(viewport: viewport)
    if isTracking {
      update.followsBottomInset = false
      update.pinsWhenAtBottom = false
      update.allowsOverscroll = true
    } else if flight != nil || coast != nil {
      update.allowsOverscroll = true
    }
    return update
  }

  override public func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // A live resize lays out every frame: rows rewrap at the new width in the same pass, keeping the reading row.
    needsLayout = true
  }

  func followSizeChange() {
    let old = state.viewport
    guard old.width > 0, old.height > 0,
          abs(bounds.width - old.width) > 0.01 || abs(bounds.height - old.height) > 0.01 else { return }
    content.frame = bounds
    headerContainer.frame = bounds
    var resized = old
    resized.width = bounds.width
    resized.height = bounds.height
    perform(sizeUpdate(resized), timing: .none, changed: [])
  }

  func viewport() -> TimelineViewport {
    TimelineViewport(width: bounds.width, height: bounds.height, topInset: insets.top, bottomInset: insets.bottom)
  }

  func perform(
    _ update: TimelineUpdate<ID>, timing: TimelineTiming, changed: Set<ID>, jump: TimelineEdge?? = nil,
    arrives: Bool = true
  ) {
    guard !isApplying else {
      queued.append { [weak self] in self?.perform(update, timing: timing, changed: changed, jump: jump, arrives: arrives) }
      return
    }
    isApplying = true
    let began = CACurrentMediaTime()
    let width = update.viewport?.width ?? state.viewport.width
    let extentBefore = indicatorExtent()
    let spanEnd = rows.spanEnd
    let spanStart = rows.spanStart
    let change = state.apply(update, spanEnd: { spanEnd?($0) }, spanStart: { spanStart?($0) }, passage: rows.passage) {
      rows.height($0, width)
    }
    var scrolled: CGFloat = 0
    if case let .by(delta) = update.scroll { scrolled = delta }
    commit(
      change, timing: timing, changed: changed, scrolled: scrolled, jump: jump, arrives: arrives,
      indicatorMoves: update.scroll != .preserve ? extentBefore : nil
    )
    lastPerformDuration = CACurrentMediaTime() - began
    totalPerformDuration += lastPerformDuration
    performCount += 1
    isApplying = false
    if !queued.isEmpty {
      let next = queued.removeFirst()
      next()
    }
  }

  func commit(
    _ change: TimelineChange<ID>, timing: TimelineTiming, changed: Set<ID>, scrolled: CGFloat, jump: TimelineEdge??,
    arrives: Bool, indicatorMoves: TimelineIndicator.Extent?
  ) {
    let layout = change.layout
    let width = layout.viewport.width
    let animates = timing.isAnimated && window != nil
    let serials = (tracks: trackSerial, pins: pinTrackCount, header: headerTrackCount, indicator: indicatorTrackCount)
    // A jump that keeps no placed row: the screen slides out and the destination in next to it.
    let carousel: CGFloat? = animates && change.isDisjoint
      ? jump.flatMap {
        TimelineCarousel.travel(from: change.previous, to: layout, index: state.index, towards: $0)
      } : nil
    // Where each span's pin (a sender's avatar) is on screen before this change, so one that moves to a row new to
    // the data (the sender's next message) travels there instead of vanishing and fading in again.
    let pinsShown = animates && carousel == nil ? shownPins() : [:]
    avatarArrivals = [:]
    rowStarts = [:]
    landedMoves = []
    contentResized = [:]
    pinRestBefore = [:]
    edgeStart = animates ? change.previous.viewport.usableBottom - layout.viewport.usableBottom : 0
    topEdgeStart = animates ? change.previous.viewport.usableTop - layout.viewport.usableTop : 0
    let headerFrom = animates && carousel == nil ? presentedHeaderTop() : nil

    // Keep one surviving row's content coordinate, so a scroll moves `content` and nothing else.
    var previousY: [ID: CGFloat] = [:]
    previousY.reserveCapacity(change.previous.placements.count)
    for placement in change.previous.placements { previousY[placement.id] = placement.y }
    let oldOrigin = origin
    if let reference = layout.placements.last(where: { slots[$0.id] != nil && previousY[$0.id] != nil }),
       let slot = slots[reference.id]
    {
      origin = slot.y - reference.y
    } else {
      origin -= scrolled
    }
    let originDelta = oldOrigin - origin
    let now = CACurrentMediaTime()
    commitTime = now
    trackClock = animates ? now : nil
    defer { trackClock = nil }

    // New messages at the newest end rise together from below, as Telegram brings in a new message.
    var rising: Set<ID> = []
    var rise: CGFloat = 0
    if arrives, animates, carousel == nil, !reducesMotion {
      for placement in layout.placements.reversed() {
        guard change.inserted.contains(placement.id) else { break }
        rising.insert(placement.id)
        rise += placement.height * Self.insertionRise
      }
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // A carousel: what was on screen stays in its place on screen and slides out by the travel with the content's
    // track, joined to the destination strip. Anything still lingering from an earlier change goes now.
    if let carousel {
      for (id, entry) in lingering { retire(id, entry.slot) }
      lingering = [:]
      for ghost in ghosts { ghost.view.removeFromSuperview() }
      ghosts = []
      let keep = Set(layout.placements.map(\.id))
      let expiry = now + timing.duration
      let screen = change.previous.viewport.height
      // The top of what slides out (rows above the screen go at once), for the pins of spans that started above it.
      let stripTop = change.previous.placements
        .first { TimelineCarousel.slides($0.y, height: $0.height, screen: screen) && !keep.contains($0.id) }
        .flatMap { first in slots[first.id].map { first.y + rows.spanTop(first.id, $0.row) } }
      let oldEdge = change.previous.viewport.usableBottom
      carouselUntil = expiry
      for (id, slot) in slots where !keep.contains(id) {
        slots[id] = nil
        // Only what was on screen slides out; rows in the margins go now (the destination joins the screen's edge).
        guard let y = previousY[id], TimelineCarousel.slides(y, height: slot.height, screen: screen) else {
          retire(id, slot)
          continue
        }
        place(slot, y: slot.y - originDelta - carousel, width: slot.width, height: slot.height)
        slidePin(slot, travel: carousel, timing: timing, stripTop: stripTop, edge: oldEdge)
        lingering[id] = (slot, expiry)
      }
      scheduleLingerSweep(after: timing.duration)
    }

    // Rows that changed place among the placed rows (a reorder): those outside the heaviest run that kept its order.
    let movedRows = TimelineListOptions.fadesMoves && animates && carousel == nil ? Self.movedRows(change) : []
    var placed: Set<ID> = []
    placed.reserveCapacity(layout.placements.count)
    for placement in layout.placements {
      placed.insert(placement.id)
      let y = placement.y + origin
      if let kept = lingering.removeValue(forKey: placement.id) { slots[placement.id] = kept.slot }
      if let slot = slots[placement.id] {
        let moved = slot.y - y
        let resized = abs(slot.height - placement.height) > 0.01 || abs(slot.width - width) > 0.01
        // A reorder is a delete and an insert, as Telegram's are: the old place keeps a picture of the row, fading out as
        // its neighbours close over it, while the row lands at its new place fading in (without it, the old place
        // showed blank until they closed it: 50–81 pt in `update.reorderAdjacent`, 22–25 pt in `reorderPending`).
        if movedRows.contains(placement.id) {
          if let previous = previousY[placement.id] { leaveGhost(placement.id, of: slot, at: previous + origin, timing: timing) }
          // The row itself lands as a new one would: its running motion stays with the picture (a row still rising from
          // its arrival kept rising at its new place, a 7.5–21 pt gap above it in `update.reorderPending`), and its pin
          // starts fresh there.
          if let layer = slot.view.layer {
            for key in layer.animationKeys() ?? [] where key.hasPrefix("timeline.track.") { layer.removeAnimation(forKey: key) }
          }
          slot.pinChanges = []
          unpin(slot)
        }
        if animates, carousel == nil, abs(slot.height - placement.height) > 0.01 {
          slot.heightTracks.append((now, timing, slot.height - placement.height))
          if changed.contains(placement.id) { contentResized[placement.id] = placement.height - slot.height }
        }
        // A row about to be updated that has no pin may get one in this change (a regroup handing it the avatar): where
        // that pin rested in the row's old layout, asked of the host before the update (a guess from the row's height
        // was off by the bottom spacing the regroup changed: 5.8 pt in `update.batch` pinned).
        if animates, carousel == nil, slot.pin == nil, resized || changed.contains(placement.id),
           let before = rows.pin(placement.id, slot.row)
        {
          pinRestBefore[placement.id] = (before.view, before.bottom - before.height)
        }
        place(slot, y: y, width: width, height: placement.height)
        if resized || changed.contains(placement.id) {
          updateRow(placement.id, slot.row, width: width, timing: animates ? timing : .none)
        }
        if animates, carousel == nil, movedRows.contains(placement.id) {
          // A reorder, landed at its new place fading in: no slide past its neighbours. Joined to them as they show:
          // after this loop it takes a neighbour's tracks (`landMoves`).
          Self.fade(slot.view.layer, from: 0, to: 1, duration: Self.insertionFade)
          landedMoves.insert(placement.id)
        } else if animates, carousel == nil {
          slot.view.layer?.addTrack(timing, keyPath: "position.y", from: moved)
          rowStarts[placement.id] = moved - originDelta
        }
      } else {
        makes += 1
        let slot = self.slot(for: rows.make(placement.id, width))
        slots[placement.id] = slot
        place(slot, y: y, width: width, height: placement.height)
        slot.row.layoutSubtreeIfNeeded()
        if animates, carousel == nil {
          var offset = change.offsets[placement.id] ?? 0
          if arrives, change.inserted.contains(placement.id) {
            if rising.contains(placement.id) { offset += rise }
            if let arriving = rows.pin(placement.id, slot.row).flatMap({ pinsShown[$0.spanStart] }) {
              avatarArrivals[placement.id] = (from: arriving, offset: offset)
            } else {
              Self.fade(slot.view.layer, from: 0, to: 1, duration: Self.insertionFade)
            }
          }
          slot.view.layer?.addTrack(timing, keyPath: "position.y", from: offset + originDelta)
          rowStarts[placement.id] = offset
        }
      }
    }

    if !landedMoves.isEmpty { landMoves(layout, originDelta: originDelta, timing: timing) }

    // Rows that fell out of the placed window during an animated change are still on screen until the motion ends:
    // they stay, stacked beyond the window's ends, and travel with it.
    if animates, carousel == nil, let first = layout.placements.first, let last = layout.placements.last {
      var top = first.y + origin
      var bottom = last.maxY + origin
      let expiry = now + timing.duration
      for placement in change.previous.placements.reversed() {
        guard !placed.contains(placement.id), let index = state.index[placement.id], index < first.index,
              let slot = slots.removeValue(forKey: placement.id) else { continue }
        top -= slot.height
        slot.view.layer?.addTrack(timing, keyPath: "position.y", from: slot.y - top)
        slidePin(slot, travel: slot.y - top - originDelta, timing: timing, stripTop: nil, edge: 0)
        place(slot, y: top, width: width, height: slot.height)
        lingering[placement.id] = (slot, expiry)
      }
      for placement in change.previous.placements {
        guard !placed.contains(placement.id), let index = state.index[placement.id], index > last.index,
              let slot = slots.removeValue(forKey: placement.id) else { continue }
        slot.view.layer?.addTrack(timing, keyPath: "position.y", from: slot.y - bottom)
        slidePin(slot, travel: slot.y - bottom - originDelta, timing: timing, stripTop: nil, edge: 0)
        place(slot, y: bottom, width: width, height: slot.height)
        bottom += slot.height
        lingering[placement.id] = (slot, expiry)
      }
      scheduleLingerSweep(after: timing.duration)
    }

    let leaving = Set(change.removed.map(\.id))
    // Rows leaving the data animate out, unless a far jump's slide carries them (a jump that replaced the loaded window:
    // the old screen is no longer in the data, and still slides out).
    if carousel == nil {
      for id in leaving { if let entry = lingering.removeValue(forKey: id) { slots[id] = entry.slot } }
    }
    for (id, slot) in slots where !placed.contains(id) {
      slots[id] = nil
      unpin(slot)
      if animates, carousel == nil, leaving.contains(id) {
        removeAnimated(id, slot)
        let duration = max(timing.duration, Self.removalDuration)
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(duration))
          slot.view.layer?.removeAllAnimations()
          slot.view.alphaValue = 1
          if let self { self.retire(id, slot) } else { slot.view.removeFromSuperview() }
        }
      } else {
        retire(id, slot)
      }
    }

    syncOrigin()
    if let carousel {
      addContentTrack(timing, from: -carousel)
    } else if animates {
      addContentTrack(timing, from: originDelta)
    }
    // The destination strip slides in by the carousel's travel: its pins follow it like any animated change.
    if let carousel { for placement in layout.placements { rowStarts[placement.id] = carousel } }
    updatePins(timing: animates ? timing : .none)
    // An update during a flight (rows in or out, heights) changes the layout the header's path was baked on: bake it
    // again (a page landing mid-fling left the date wrong for 10 frames in the update lab). Scrolls alone keep it.
    if flight != nil, !change.previousHeights.isEmpty || !change.inserted.isEmpty || !change.removed.isEmpty {
      headerFlightStart = nil
    }
    updateFloatingHeader(timing: animates ? timing : .none, from: headerFrom, slides: carousel != nil)
    moveIndicator(change, scrolledBy: indicatorMoves.map { ($0, originDelta) }, timing: animates ? timing : .none)
    CATransaction.commit()

    // A jump or an animated `.by` can be stopped where it shows (not a far jump's slide: its two strips are joined
    // across rows that are not there, so no layout matches a screen mid-slide).
    if animates, carousel == nil, jump != nil || scrolled != 0, abs(originDelta) > 0.01 {
      scrollMotions.removeAll { $0.timing.remaining(at: now - $0.start) <= 0 }
      scrollMotions.append(ScrollMotion(
        start: now, timing: timing, travel: -originDelta,
        tracks: (serials.tracks + 1) ..< (trackSerial + 1), pins: (serials.pins + 1) ..< (pinTrackCount + 1),
        header: (serials.header + 1) ..< (headerTrackCount + 1),
        indicator: (serials.indicator + 1) ..< (indicatorTrackCount + 1)
      ))
    }

    if !change.demands.isEmpty { onDemand?(change.demands) }
    onLayout?(layout)
  }

  /// Placed rows, kept from the previous layout, that changed order among the kept ones: the ones outside the heaviest
  /// run whose old order still holds (a row moved past its neighbours; the neighbours did not move).
  static func movedRows(_ change: TimelineChange<ID>) -> Set<ID> {
    var oldRank: [ID: Int] = [:]
    for (rank, placement) in change.previous.placements.enumerated() { oldRank[placement.id] = rank }
    let kept = change.layout.placements.compactMap { p in oldRank[p.id].map { (p.id, $0, p.height) } }
    return Set(outOfOrder(kept.map(\.1), weights: kept.map(\.2)).map { kept[$0].0 })
  }

  /// The positions in `ranks` outside its heaviest increasing run, by `weights` (the rows' heights; 1 each when nil):
  /// what changed order. The rows that land elsewhere are the least height: the rows in the run slide by what they
  /// pass, and a moved row's new place shows empty until they make room. By count alone, a swap of a 212 pt row and a
  /// 36 pt one landed the tall one and slid the short one 199 pt past it, its new place a 36 pt blank for 0.4 s
  /// (`update.fuzz`, seed 1592598566 step 12). Ties go to the run ending latest, as the count-only version had it.
  static func outOfOrder(_ ranks: [Int], weights: [CGFloat]? = nil) -> Set<Int> {
    let count = ranks.count
    guard count > 1, !zip(ranks, ranks.dropFirst()).allSatisfy({ $0 < $1 }) else { return [] }
    let weight = weights?.count == count ? weights! : [CGFloat](repeating: 1, count: count)
    var best = [CGFloat](repeating: 0, count: count)
    var previous = [Int](repeating: -1, count: count)
    var end = 0
    for i in 0 ..< count {
      best[i] = weight[i]
      for j in 0 ..< i where ranks[j] < ranks[i] && best[j] + weight[i] >= best[i] {
        best[i] = best[j] + weight[i]
        previous[i] = j
      }
      if best[i] >= best[end] { end = i }
    }
    var inRun = Set<Int>()
    var at = end
    while at >= 0 {
      inRun.insert(at)
      at = previous[at]
    }
    return Set((0 ..< count).filter { !inRun.contains($0) })
  }

  static var insertionRise: CGFloat { 1.6 }
  static var insertionFade: CFTimeInterval { 0.2 }
  static var removalDuration: CFTimeInterval { 0.15 }
  static var removalScale: CGFloat { 0.1 }

  static func fade(_ layer: CALayer?, from: Float, to: Float, duration: CFTimeInterval) {
    guard let layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = from
    fade.toValue = to
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    fade.fillMode = .backwards
    layer.add(fade, forKey: "timeline.fade")
  }

  func removeAnimated(_ id: ID, _ slot: Slot) {
    guard let layer = slot.view.layer else { return }
    let shown = layer.presentation()?.opacity ?? layer.opacity
    // An arrival still fading in would win over the removal until it ends (of two non-additive animations on one key
    // path, the earlier one shows): the removal starts from what shows instead.
    layer.removeAnimation(forKey: "timeline.fade")
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = shown
    fade.toValue = 0
    fade.duration = Self.removalDuration
    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    fade.fillMode = .forwards
    fade.isRemovedOnCompletion = false
    layer.add(fade, forKey: "timeline.remove.opacity")
    content.addSubview(slot.view, positioned: .below, relativeTo: nil)
    guard let focus = rows.removalFocus?(id, slot.row), focus.x.isFinite, focus.y.isFinite else { return }
    let shrink = 1 - Self.removalScale
    let timing = CAMediaTimingFunction(name: .easeInEaseOut)
    for (keyPath, value) in [
      ("transform.scale", NSNumber(value: Double(Self.removalScale))),
      ("transform.translation", NSValue(size: CGSize(width: focus.x * shrink, height: focus.y * shrink))),
    ] as [(String, Any)] {
      let animation = CABasicAnimation(keyPath: keyPath)
      animation.toValue = value
      animation.duration = Self.removalDuration
      animation.timingFunction = timing
      animation.fillMode = .forwards
      animation.isRemovedOnCompletion = false
      layer.add(animation, forKey: "timeline.remove.\(keyPath)")
    }
  }

  /// Asks the host to update a row. An animated update gets implicit animations back for that call, so a row's
  /// insides can move with its height.
  func updateRow(_ id: ID, _ row: NSView, width: CGFloat, timing: TimelineTiming) {
    guard timing != .none else { return rows.update(id, row, width, timing) }
    CATransaction.begin()
    CATransaction.setDisableActions(false)
    rows.update(id, row, width, timing)
    CATransaction.commit()
  }

  func place(_ slot: Slot, y: CGFloat, width: CGFloat, height: CGFloat) {
    slot.y = y
    slot.height = height
    slot.width = width
    let frame = NSRect(x: 0, y: y, width: width, height: height)
    if slot.view.frame != frame { slot.view.frame = frame }
    let rowFrame = NSRect(x: 0, y: 0, width: width, height: height)
    if slot.row.frame != rowFrame { slot.row.frame = rowFrame }
  }

  func slot(for row: NSView) -> Slot {
    if let index = slotPool.firstIndex(where: { $0.row === row }) {
      let slot = slotPool.remove(at: index)
      slot.view.isHidden = false
      return slot
    }
    let began = CACurrentMediaTime()
    defer { totalAttachDuration += CACurrentMediaTime() - began }
    if let slot = slotPool.popLast() {
      slot.row.removeFromSuperview()
      slot.row = row
      slot.view.addSubview(row)
      slot.view.isHidden = false
      return slot
    }
    let slot = Slot(row: row)
    content.addSubview(slot.view)
    slot.view.reveal = { [weak self, weak slot] in
      guard let self, let slot else { return }
      self.reveal(slot)
    }
    return slot
  }

  func retire(_ id: ID, _ slot: Slot) {
    unpin(slot)
    slot.heightTracks = []
    slot.pinChanges = []
    slot.view.layer?.removeAllAnimations()
    if slot.sectionBake != nil || slot.row.isHidden {
      slot.sectionBake = nil
      slot.row.layer?.removeAnimation(forKey: Self.sectionRowKey)
      slot.row.isHidden = false
    }
    rows.recycle(id, slot.row)
    if slotPool.count < Self.slotPoolLimit {
      slot.view.isHidden = true
      slotPool.append(slot)
    } else {
      slot.view.removeFromSuperview()
    }
  }

  var lingerSweep: DispatchWorkItem?

  func flushDeferredUpdates() {
    carouselUntil = 0
    let pending = deferredDuringCarousel
    deferredDuringCarousel = []
    guard !pending.isEmpty else { return }
    // The jump just landed: what waited for its slide keeps the target where it landed.
    if var target = jumpTarget {
      target.until = max(target.until, CACurrentMediaTime() + 0.001)
      jumpTarget = target
    }
    for transaction in pending { apply(transaction) }
  }

  /// Moved rows land at their new places joined to the rows around them as those show: each takes the running tracks
  /// of its nearest neighbour that kept its order (the row above, else the one below), so it moves as that row does.
  /// Placed by the content alone, a moved row was off by whatever its neighbours still had to go: this reorder's own
  /// scroll compensation when the row the origin is kept by moved (the newest: up to 31 pt over its neighbour,
  /// `update.reorderPending`), or an earlier arrival's (40 pt below its neighbour mid-bounce).
  func landMoves(_ layout: TimelineLayout<ID>, originDelta: CGFloat, timing: TimelineTiming) {
    let placements = layout.placements
    for (i, placement) in placements.enumerated() where landedMoves.contains(placement.id) {
      guard let layer = slots[placement.id]?.view.layer else { continue }
      let above = placements[..<i].last { !landedMoves.contains($0.id) && slots[$0.id] != nil }
      let below = placements[(i + 1)...].first { !landedMoves.contains($0.id) && slots[$0.id] != nil }
      guard let neighbour = above ?? below, let from = slots[neighbour.id]?.view.layer else {
        // No neighbour kept its order: at its place in the content, the content's track cancelled.
        layer.addTrack(timing, keyPath: "position.y", from: originDelta)
        rowStarts[placement.id] = 0
        continue
      }
      for key in from.animationKeys() ?? [] where key.hasPrefix("timeline.track.") {
        if let track = from.animation(forKey: key) { layer.add(track, forKey: key) }
      }
      // Joined to the row above's presented bottom, which also moves with that row's height still animating (a regroup
      // grows it: 5.8 pt apart in `update.reorderAdjacent` pinned); to the row below's top, less its own.
      let now = CACurrentMediaTime()
      let heights = above != nil ? slots[neighbour.id]?.heightTracks ?? [] : (slots[placement.id]?.heightTracks ?? []).map { ($0.start, $0.timing, -$0.from) }
      var start = rowStarts[neighbour.id] ?? 0
      for (begin, curve, delta) in heights where curve.remaining(at: now - begin) > 0 {
        guard let track = curve.track(keyPath: "position.y", from: delta) else { continue }
        trackSerial &+= 1
        track.beginTime = begin
        layer.add(track, forKey: "timeline.track.\(trackSerial)")
        start += delta * CGFloat(curve.remaining(at: now - begin))
      }
      rowStarts[placement.id] = start
    }
  }

  /// A picture of a moved row left at its old place (`at`, in content coordinates): it moves as the row did (the
  /// row's running tracks, and from where it shows to `at`), and fades out over the change.
  func leaveGhost(_ id: ID, of slot: Slot, at y: CGFloat, timing: TimelineTiming) {
    guard let source = slot.view.layer, slot.width > 0, slot.height > 0 else { return }
    let scale = window?.backingScaleFactor ?? 2
    let width = Int((slot.width * scale).rounded(.up))
    let height = Int((slot.height * scale).rounded(.up))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }
    // The row's layers are laid out top-down (flipped views); the context is bottom-up.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    source.render(in: context)
    guard let image = context.makeImage() else { return }
    let ghost = GhostView(frame: NSRect(x: 0, y: y, width: slot.width, height: slot.height))
    ghost.layer?.contents = image
    ghost.layer?.contentsScale = scale
    content.addSubview(ghost, positioned: .below, relativeTo: nil)
    let duration = max(timing.duration, Self.removalDuration)
    let shown = source.presentation()?.opacity ?? source.opacity
    if let layer = ghost.layer {
      for key in source.animationKeys() ?? [] where key.hasPrefix("timeline.track.") {
        if let track = source.animation(forKey: key) { layer.add(track, forKey: key) }
      }
      layer.addTrack(timing, keyPath: "position.y", from: slot.y - y)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = shown
      fade.toValue = 0
      fade.duration = duration
      fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      fade.fillMode = .forwards
      fade.isRemovedOnCompletion = false
      layer.add(stamped(fade), forKey: "timeline.ghost.opacity")
    }
    ghosts.append((id, ghost))
    Task { @MainActor [weak self, weak ghost] in
      try? await Task.sleep(for: .seconds(duration))
      guard let ghost else { return }
      ghost.removeFromSuperview()
      self?.ghosts.removeAll { $0.view === ghost }
    }
  }

  /// Where each moved row's picture at its old place shows now, in this view's coordinates, by the row's id.
  public var ghostFrames: [(id: ID, frame: CGRect)] {
    ghosts.compactMap { ghost in
      guard let layer = ghost.view.layer else { return nil }
      let shown = layer.presentation() ?? layer
      guard shown.opacity > 0.001 else { return nil }
      return (ghost.id, CGRect(x: shown.frame.minX, y: shown.frame.minY - presentedOrigin, width: shown.frame.width, height: shown.frame.height))
    }
  }

  final class GhostView: NSView {
    nonisolated override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  func scheduleLingerSweep(after delay: CFTimeInterval) {
    lingerSweep?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.sweepLingering() }
    }
    lingerSweep = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: work)
  }

  func sweepLingering() {
    let now = CACurrentMediaTime()
    for (id, entry) in lingering where entry.expiry <= now {
      lingering[id] = nil
      retire(id, entry.slot)
    }
    if let next = lingering.values.map(\.expiry).min() { scheduleLingerSweep(after: max(0, next - now)) }
  }

  /// Puts the content view's bounds origin where the content shows.
  ///
  /// A motion's animations are expressed against where it settles (a fling's end, a change's destination), and the
  /// render server plays them whatever the main thread does. AppKit, though, lays out, draws and hit-tests by the model:
  /// it draws only the views inside the model's visible rect, so a model parked at a fling's end leaves every row the
  /// fling passes blank. While the content moves, its model follows what is shown at each frame (`followTime`, the
  /// frame's display time) and a constant additive animation holds the difference to where it settles: what the render
  /// server shows is exactly the motions' curves, and AppKit sees the rows where they are.
  func syncOrigin() {
    let settled = origin - (flight?.ahead ?? 0)
    var model = settled
    let time = (followTime ?? CACurrentMediaTime())
    contentTracks.removeAll { $0.timing.remaining(at: time - $0.start) <= 0 }
    if flight != nil || !contentTracks.isEmpty {
      let scale = max(1, window?.backingScaleFactor ?? 2)
      // A fling leads by a frame (its rows drawn before they show); an animated change's tracks are followed as shown.
      let lead = flight != nil ? Self.followLead : 0
      model = settled + (shownOffset(at: time + lead) * scale).rounded() / scale
    }
    followOffset = model - settled
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let bounds = NSRect(x: 0, y: model, width: content.frame.width, height: content.frame.height)
    if content.bounds != bounds { content.bounds = bounds }
    hold(-followOffset)
    CATransaction.commit()
  }

  /// How far the content shows from where it settles at `time`, by the motions on it.
  func shownOffset(at time: CFTimeInterval) -> CGFloat {
    var offset: CGFloat = 0
    if let flight {
      offset += CGFloat(flight.path.end - flight.path.position(at: min(max(0, time - flight.start), flight.path.duration)))
    }
    for track in contentTracks {
      offset += track.from * CGFloat(track.timing.remaining(at: time - track.start))
    }
    return offset
  }

  var heldOffset: CGFloat {
    (content.layer?.animation(forKey: Self.followKey) as? CABasicAnimation)?.fromValue as? CGFloat ?? 0
  }

  /// The constant additive offset on the content's bounds origin that keeps what is shown where the motions put it.
  func hold(_ value: CGFloat) {
    guard let layer = content.layer, abs(value - heldOffset) > 0.0001 else { return }
    guard abs(value) > 0.0001 else {
      layer.removeAnimation(forKey: Self.followKey)
      return
    }
    let constant = CABasicAnimation(keyPath: "bounds.origin.y")
    constant.fromValue = value
    constant.toValue = value
    constant.isAdditive = true
    constant.duration = 1
    constant.repeatCount = .infinity
    constant.isRemovedOnCompletion = false
    // Begun already: one added without a begin time counts only from its commit, so `presentation()` read before the
    // commit (a touch handled in the same pass as a tick) would see the model moved and not the offset that holds it.
    constant.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - 1
    constant.fillMode = .both
    layer.add(constant, forKey: Self.followKey)
  }

  /// A scroll track on the content, which the model follows while it runs.
  func addContentTrack(_ timing: TimelineTiming, from delta: CGFloat) {
    let before = trackSerial
    content.layer?.addTrack(timing, keyPath: "bounds.origin.y", from: delta)
    guard trackSerial != before else { return }
    contentTracks.append(ContentTrack(serial: trackSerial, start: trackClock ?? CACurrentMediaTime(), timing: timing, from: delta))
    startTicking()
  }

  // MARK: - AppKit overrides (forwarded: extensions of a generic class cannot override Objective-C methods)

  // For accessibility the list is a list of its placed rows, top to bottom (subview order is not).
  override public func isAccessibilityElement() -> Bool { true }
  override public func accessibilityRole() -> NSAccessibility.Role? { .list }
  override public func accessibilityChildren() -> [Any]? {
    state.layout.placements.compactMap { slots[$0.id]?.view }
  }

  override public func hitTest(_ point: NSPoint) -> NSView? { return timeline_hitTest(point) }
  @discardableResult
  override public func autoscroll(with event: NSEvent) -> Bool { return timeline_autoscroll(with: event) }
  override public func keyDown(with event: NSEvent) { timeline_keyDown(with: event) }
  override public func scrollPageUp(_ sender: Any?) { timeline_scrollPageUp(sender) }
  override public func scrollPageDown(_ sender: Any?) { timeline_scrollPageDown(sender) }
  override public func pageUp(_ sender: Any?) { timeline_pageUp(sender) }
  override public func pageDown(_ sender: Any?) { timeline_pageDown(sender) }
  override public func scrollLineUp(_ sender: Any?) { timeline_scrollLineUp(sender) }
  override public func scrollLineDown(_ sender: Any?) { timeline_scrollLineDown(sender) }
  override public func moveUp(_ sender: Any?) { timeline_moveUp(sender) }
  override public func moveDown(_ sender: Any?) { timeline_moveDown(sender) }
  override public func scrollToEndOfDocument(_ sender: Any?) { timeline_scrollToEndOfDocument(sender) }
  override public func scrollToBeginningOfDocument(_ sender: Any?) { timeline_scrollToBeginningOfDocument(sender) }
  override public func moveToBeginningOfDocument(_ sender: Any?) { timeline_moveToBeginningOfDocument(sender) }
  override public func moveToEndOfDocument(_ sender: Any?) { timeline_moveToEndOfDocument(sender) }
  override public func scrollWheel(with event: NSEvent) {
    guard !isInvalidated else { return }
    timeline_scrollWheel(with: event)
  }
  override public func mouseDown(with event: NSEvent) { timeline_mouseDown(with: event) }
  override public func mouseDragged(with event: NSEvent) { timeline_mouseDragged(with: event) }
  override public func mouseUp(with event: NSEvent) { timeline_mouseUp(with: event) }

  // MARK: - Display link

  /// A display link while the content moves, at the display's top rate. (Keeping one alive and paused between motions
  /// let a main-thread coast start in the frame after the lift, but broke interrupted animated jumps: a step of 3–9 pt
  /// in `anim.jump-undisturbed`, every run. Coasting is off, so the link is made and dropped again.)
  func startTicking() {
    guard link == nil else { return }
    let link = displayLink(target: self, selector: #selector(tick(_:)))
    link.preferredFrameRateRange = flightFrameRate
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stopTicking() {
    link?.invalidate()
    link = nil
  }

  /// Ticks while the content moves (a fling, or tracks its model follows).
  func updateTicking() {
    if flight != nil || coast != nil || !contentTracks.isEmpty { startTicking() } else { stopTicking() }
  }

  /// Each frame of a fling: move the state to where the path is at the frame's time, which realises the rows coming
  /// into view. The motion itself does not depend on this running on time.
  @objc func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    followTime = max(link.targetTimestamp, now)
    defer { followTime = nil }
    if coast != nil { tickCoast(at: followTime ?? now) }
    guard var flight else {
      // Tracks only: the model follows them, and settles with them.
      syncOrigin()
      if contentTracks.isEmpty, coast == nil { stopTicking() }
      return
    }
    let time = min(max(0, max(link.targetTimestamp, now) - flight.start), flight.path.duration)
    let position = flight.path.position(at: time)
    let moving = flight.path.velocity(at: time)
    let delta = position - flight.applied
    // Rows realised ahead of the travel, for main-thread stalls the render server plays through. The margin grows
    // towards its target a little each tick: all at once, a fast release would lay out a screen of rows in one frame.
    let standard = TimelineMargins.standard
    let target = min(CGFloat(abs(moving)) * Self.lookahead, state.viewport.height)
    let current = max(0, moving > 0 ? state.margins.above - standard.above : state.margins.below - standard.below)
    let ahead = min(target, current + max(Self.lookaheadGrowth, CGFloat(abs(delta))))
    state.margins = TimelineMargins(
      above: standard.above + (moving > 0 ? ahead : 0),
      below: standard.below + (moving < 0 ? ahead : 0)
    )
    flight.applied = position
    self.flight = flight
    scroll(by: CGFloat(delta))

    if now - flight.start >= flight.path.duration {
      endFlight(settle: true)
    } else {
      rebakeIfEndsChanged(now: now)
      followHeaderSection()
      syncOrigin()
    }
  }
}

/// A container that never takes the pointer itself: what it shows floats over the rows, which keep their clicks,
/// except where a subview takes it (the floating date's pill).
public final class TimelinePassthroughView: NSView {
  nonisolated override public var isFlipped: Bool { true }
  override public func hitTest(_ point: NSPoint) -> NSView? {
    guard alphaValue > 0.5 else { return nil }
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}
#endif
