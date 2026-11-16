#if canImport(UIKit)
import QuartzCore
import TimelineCore
import UIKit

/// How the list gets its rows. Heights are exact and synchronous; the list asks only for rows near
/// the viewport.
@MainActor
public struct TimelineRows<ID: Hashable & Sendable> {
  /// The row's height at this width.
  public var height: (ID, CGFloat) -> CGFloat
  /// A view showing the row at this width. The list sizes and places it.
  public var make: (ID, CGFloat) -> UIView
  /// The row's content or width changed while it is on screen; animate inside with this timing.
  public var update: (ID, UIView, CGFloat, TimelineTiming) -> Void
  /// The row left the placed window.
  public var recycle: (ID, UIView) -> Void
  /// The view in a placed row that stays in sight while its span does; nil for most rows. Asked
  /// after every change, so a row can gain or lose it with its content.
  public var pin: (ID, UIView) -> TimelinePin<ID>?
  /// Where a pin's span starting at this row begins, in the row's coordinates.
  public var spanTop: (ID, UIView) -> CGFloat
  /// The last row of the span this row belongs to (a sender's group), when that row holds the span's
  /// pin: the list keeps it placed while any of the span is in sight. Nil costs nothing.
  public var spanEnd: ((ID) -> ID?)?
  /// Where a placed row is on screen, for what in it follows the screen rather than the row. Called
  /// for every placed row when that changes, and when a fling starts or stops. Nil costs nothing.
  public var screen: ((ID, UIView, TimelineRowScreen) -> Void)?

  public init(
    height: @escaping (ID, CGFloat) -> CGFloat,
    make: @escaping (ID, CGFloat) -> UIView,
    update: @escaping (ID, UIView, CGFloat, TimelineTiming) -> Void = { _, _, _, _ in },
    recycle: @escaping (ID, UIView) -> Void = { _, _ in },
    pin: @escaping (ID, UIView) -> TimelinePin<ID>? = { _, _ in nil },
    spanTop: @escaping (ID, UIView) -> CGFloat = { _, _ in 0 },
    spanEnd: ((ID) -> ID?)? = nil,
    screen: ((ID, UIView, TimelineRowScreen) -> Void)? = nil
  ) {
    self.height = height
    self.make = make
    self.update = update
    self.recycle = recycle
    self.pin = pin
    self.spanTop = spanTop
    self.spanEnd = spanEnd
    self.screen = screen
  }
}

/// Where a placed row is on screen, and how it is moving there, for content that follows the screen
/// rather than the row: a gradient laid over the whole viewport and cut out by each bubble.
@MainActor
public struct TimelineRowScreen {
  /// The row's top in the list's coordinates once the motion running now settles (a fling's end).
  public let y: CGFloat
  /// The list's height.
  public let height: CGFloat
  /// A running fling: the row is `path.end - position` above `y` at each of the path's samples.
  let flight: (path: ScrollPath, start: CFTimeInterval, frameRate: CAFrameRateRange)?
  /// An animated change: the row starts `from` away from `y` on screen and settles on this timing.
  let transition: (timing: TimelineTiming, from: CGFloat)?

  /// Moves a property of `layer` with the row while it moves on the render server. The caller sets
  /// the property's value for `y`; `offset` gives what to add to it while the row is that many points
  /// below `y` (negative: above). The property must take additive animations of those values.
  public func follow(_ layer: CALayer, keyPath: String, offset: (CGFloat) -> Any) {
    let key = "timeline.screen.\(keyPath)"
    if let flight {
      // What one point of travel adds identifies the bake: a recycled row or a resized bubble on the
      // same fling needs a new one.
      let signature = String(describing: offset(1))
      let current = layer.animation(forKey: key)
      if (current?.value(forKey: "timelineFlight") as? CFTimeInterval) != flight.start
        || (current?.value(forKey: "timelineSignature") as? String) != signature
      {
        let path = flight.path
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = path.positions.map { offset(CGFloat($0 - path.end)) }
        animation.duration = path.duration
        animation.calculationMode = .linear
        animation.isAdditive = true
        animation.beginTime = layer.convertTime(flight.start, from: nil)
        animation.isRemovedOnCompletion = true
        animation.fillMode = .backwards
        animation.preferredFrameRateRange = flight.frameRate
        animation.setValue(flight.start, forKey: "timelineFlight")
        animation.setValue(signature, forKey: "timelineSignature")
        layer.add(animation, forKey: key)
      }
    } else if layer.animation(forKey: key) != nil {
      layer.removeAnimation(forKey: key)
    }
    if let transition, abs(transition.from) > 0.01,
       let track = transition.timing.track(keyPath: keyPath, from: offset(transition.from), to: offset(0))
    {
      TimelineRowScreen.trackCount &+= 1
      layer.add(track, forKey: "\(key).\(TimelineRowScreen.trackCount)")
    }
  }

  private static var trackCount = 0
}

/// A view inside a row that stays in sight while its span does: the sender's avatar beside a group
/// of messages. It rests at its place in the row; while that place is below the visible area the
/// list lifts it to keep its bottom on the visible area's bottom edge, but never above the top of
/// its span. The lift is the y translation of the view's transform, and it moves with the list on
/// every path the list moves by: the finger, a fling (baked into the same render-server path), and
/// the tracks of an animated change.
@MainActor
public struct TimelinePin<ID: Hashable & Sendable> {
  /// A descendant of the row view, placed through bounds and center (never `frame`, which would
  /// read the lift back as position).
  public var view: UIView
  /// The view's bottom and height at rest, in the row's coordinates.
  public var bottom: CGFloat
  public var height: CGFloat
  /// The row the span starts in, this row or an older one; `TimelineRows.spanTop` says where.
  public var spanStart: ID

  public init(view: UIView, bottom: CGFloat, height: CGFloat, spanStart: ID) {
    self.view = view
    self.bottom = bottom
    self.height = height
    self.spanStart = spanStart
  }
}

/// One change to the list. Everything given here is resolved in one pass and moves with one timing.
public struct TimelineTransaction<ID: Hashable & Sendable> {
  public var rows: [ID]?
  public var coverage: TimelineCoverage?
  public var scroll: TimelineScroll<ID>
  public var topInset: CGFloat?
  public var bottomInset: CGFloat?
  /// Rows whose content (and maybe height) changed.
  public var changed: Set<ID>
  public var timing: TimelineTiming
  /// For a jump whose destination shares no placed row with what is on screen: the side it lies on.
  /// Such a jump slides the screen out and the destination in next to it, on one track. When the rows
  /// on screen are still in the list, their order decides and this is not read; nil means newer.
  public var towards: TimelineEdge?

  public init(
    rows: [ID]? = nil, coverage: TimelineCoverage? = nil, scroll: TimelineScroll<ID> = .preserve,
    topInset: CGFloat? = nil, bottomInset: CGFloat? = nil, changed: Set<ID> = [], timing: TimelineTiming = .none,
    towards: TimelineEdge? = nil
  ) {
    self.rows = rows
    self.coverage = coverage
    self.scroll = scroll
    self.topInset = topInset
    self.bottomInset = bottomInset
    self.changed = changed
    self.timing = timing
    self.towards = towards
  }
}

public struct TimelineDiagnostics: Sendable {
  /// The scroll position the settled layout is at, and the one on screen.
  public var scrollPosition: CGFloat
  public var presentedScrollPosition: CGFloat
  /// The extent of the realised rows, in the same coordinates.
  public var placedTop: CGFloat
  public var placedBottom: CGFloat
  public var placedCount: Int
}

/// The message list. No scroll view and no global content height: the solver places the rows near
/// the viewport, this view realises them, and every movement is either the finger, a baked path
/// played by the render server, or an additive track.
///
/// Coordinates: rows live in `content`, whose `bounds.origin.y` is the scroll position. A row keeps
/// its content coordinate while the list scrolls, so scrolling touches one layer.
@MainActor
public final class TimelineListView<ID: Hashable & Sendable>: UIView {
  public var rows: TimelineRows<ID>
  public var physics = ScrollPhysics()

  /// Loaded ends the window is near that are not real ends.
  public var onDemand: ((Set<TimelineEdge>) -> Void)?
  /// After every change, with the settled layout.
  public var onLayout: ((TimelineLayout<ID>) -> Void)?
  /// A finger took hold of the list.
  public var onDragBegan: (() -> Void)?
  /// The list came to rest after a drag or a fling.
  public var onScrollEnded: (() -> Void)?
  /// The finger's release velocity can be replaced (zero when another gesture consumed the drag).
  public var releaseVelocityFilter: ((CGFloat) -> CGFloat)?
  /// The status bar was tapped. Setting it makes the list take the tap, as a scroll view with
  /// `scrollsToTop` would; the host decides where that goes.
  public var onScrollToTop: (() -> Void)? {
    didSet { scrollToTopProxy.action = onScrollToTop }
  }
  /// A thin indicator at the trailing edge of the usable area while the list moves.
  public var showsScrollIndicator = true {
    didSet { if !showsScrollIndicator { hideIndicator(animated: false) } }
  }
  /// What VoiceOver says after it paged the list towards this edge; nil says the list's own words.
  public var accessibilityPageDescription: ((TimelineEdge) -> String?)?

  public private(set) var isTracking = false
  /// When a finger last caught a fling. A touch that stops a moving list is not a press on a row.
  public private(set) var lastFlightCatch: CFTimeInterval = 0
  /// The finger now down stopped a fling; if it lifts without dragging, the scroll ends there.
  private var caughtFlight = false
  public var isDecelerating: Bool { flight != nil }
  public var layout: TimelineLayout<ID> { state.layout }
  public var position: TimelinePosition<ID> { state.position }
  public var panGestureRecognizer: UIPanGestureRecognizer { input.pan }

  private var state: TimelineState<ID>
  private let content = UIView()
  private var slots: [ID: Slot] = [:]
  /// Rows no longer in the placed window that an animation still shows.
  private var lingering: [ID: (slot: Slot, expiry: CFTimeInterval)] = [:]
  /// Retired slots, hidden but still in the hierarchy with the row view they last held. Adding a view
  /// to a window walks its whole subtree, so a row the host hands back again comes back here.
  private var slotPool: [Slot] = []
  private static var slotPoolLimit: Int { 32 }
  /// The scroll position the state's layout is expressed against: content y = viewport y + origin.
  private var origin: CGFloat = 0
  private let input = TimelineInput()
  private var flight: Flight?
  /// The display link's latest frame: when it will be shown, and the frame length. It runs while a
  /// finger is down too, so a release knows when the finger's last movement reached the screen.
  private var frameClock: (target: CFTimeInterval, duration: CFTimeInterval)?
  /// When the content the finger last moved is on screen.
  private var lastDragShown: CFTimeInterval?
  private var lastTranslation: CGFloat = 0
  /// How far the finger has pulled past an end, before the rubber band.
  private var pulled: CGFloat = 0
  private var isApplying = false
  private var queued: [() -> Void] = []
  private var beforeFirstLayout: [TimelineTransaction<ID>] = []
  private var topInset: CGFloat = 0
  private var bottomInset: CGFloat = 0
  /// The screen a far jump left, sliding out while the destination slides in ("carousel"). In
  /// viewport space, under the content, so a finger on the new rows does not drag it.
  private var carouselExit: UIView?

  // Scroll indicator, status bar, accessibility
  private let indicatorView = TimelineScrollIndicatorView()
  private var indicator = TimelineIndicator(progress: 1)
  /// The thumb's length, kept while the row count, coverage and track stay, so it does not
  /// twitch as rows are measured.
  private var indicatorLength: CGFloat = 0
  private var indicatorLengthKey: IndicatorLengthKey?
  /// The thumb's path during the running flight: its place `progress` at the flight displacement
  /// `applied`, moved from there by the rule of `TimelineIndicator` with `extent` as measured then.
  private var indicatorFlight: (start: CFTimeInterval, progress: CGFloat, extent: TimelineIndicator.Extent, applied: Double)?
  private var indicatorHide: DispatchWorkItem?
  private let scrollToTopProxy = TimelineScrollToTopProxy()

  private final class Slot {
    let view: UIView
    let row: UIView
    var y: CGFloat = 0
    var height: CGFloat = 0
    var width: CGFloat = 0
    var pin: PinState?
    /// The screen place last reported to the row; nil when it has to be reported again.
    var screen: (y: CGFloat, height: CGFloat, flight: CFTimeInterval?)?

    init(row: UIView) {
      self.row = row
      view = UIView()
      view.layer.anchorPoint = .zero
      view.addSubview(row)
    }
  }

  /// A pin as last applied. Its lift is a function of the scroll position, so this keeps the two
  /// numbers that function needs, taken with the content at its layer's model value (the end of a
  /// running flight), and the flight its path was baked for.
  private struct PinState {
    let view: UIView
    /// How far the pin's resting bottom is below the visible area's bottom edge.
    var overhang: CGFloat
    /// How far it can be lifted before its top meets its span's top.
    var maxLift: CGFloat
    var flightStart: CFTimeInterval?

    /// The lift its layer holds.
    var lift: CGFloat { pinLift(overhang: overhang, maxLift: maxLift) }

    func matches(_ other: PinState) -> Bool {
      view === other.view && flightStart == other.flightStart && abs(overhang - other.overhang) < 0.01
        && (maxLift == other.maxLift || abs(maxLift - other.maxLift) < 0.01)
    }
  }

  /// A fling being played by the render server.
  private struct Flight {
    var path: ScrollPath
    /// Media time of the path's first sample.
    var start: CFTimeInterval
    /// The path displacement the state has been moved to so far.
    var applied: Double
    /// The ends the path was baked with, as path displacements.
    var lower: Double?
    var upper: Double?
  }

  private static var flightKey: String { "timeline.flight" }
  private static var pinKey: String { "timeline.pin" }
  private static var indicatorFlightKey: String { "timeline.indicator.flight" }
  private static var indicatorTrackKey: String { "timeline.indicator.track" }
  private var pinTrackCount = 0
  /// Seconds of travel realised beyond the standard margins while flinging.
  private static var lookahead: CGFloat { 0.1 }

  public init(rows: TimelineRows<ID>) {
    self.rows = rows
    state = TimelineState(viewport: TimelineViewport(width: 0, height: 0))
    super.init(frame: .zero)
    clipsToBounds = true
    // Under the content, which takes every touch in its place.
    addSubview(scrollToTopProxy)
    addSubview(content)
    addSubview(indicatorView)
    addGestureRecognizer(input.pan)
    input.pan.onTouchDown = { [weak self] in self?.catchFlight() }
    input.pan.onTouchUpWithoutPan = { [weak self] in self?.tapEnded() }
    input.onPan = { [weak self] pan in self?.handlePan(pan) }
    input.onTick = { [weak self] link in self?.tick(link) }
    NotificationCenter.default.addObserver(
      self, selector: #selector(accessibilityFocusChanged(_:)), name: UIAccessibility.elementFocusedNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The display link holds the input, not the list: stop it, or it ticks for good.
  isolated deinit {
    input.stopTicking()
  }

  /// Off screen (the chat popped or covered) a fling finishes where it was going.
  override public func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil, flight != nil { endFlight(settle: true) }
  }

  // MARK: - Changes

  /// The single way the list changes.
  public func apply(_ transaction: TimelineTransaction<ID>) {
    if let topInset = transaction.topInset { self.topInset = topInset }
    if let bottomInset = transaction.bottomInset { self.bottomInset = bottomInset }
    guard bounds.width > 0, bounds.height > 0 else {
      // No size yet, so no row can be measured: the change is applied with the first layout.
      var waiting = transaction
      waiting.timing = .none
      beforeFirstLayout.append(waiting)
      return
    }
    var update = TimelineUpdate<ID>(
      rows: transaction.rows, coverage: transaction.coverage, viewport: viewport(), scroll: transaction.scroll
    )
    if isTracking {
      update.followsBottomInset = false
      update.pinsWhenAtBottom = false
      update.allowsOverscroll = true
    } else if flight != nil {
      update.allowsOverscroll = true
    }
    let takesOverFlight = transaction.scroll != .preserve && flight != nil && !isTracking
    if takesOverFlight { endFlight(settle: false) }
    var jump: TimelineEdge??
    switch transaction.scroll {
      case .latest, .to: jump = .some(transaction.towards)
      case .preserve, .by: jump = nil
    }
    perform(update, timing: transaction.timing, changed: transaction.changed, jump: jump)
    // The fling's scroll ends here; the change that took over moves the content on.
    if takesOverFlight { onScrollEnded?() }
  }

  public func setInsets(top: CGFloat? = nil, bottom: CGFloat? = nil, timing: TimelineTiming = .none) {
    apply(TimelineTransaction(topInset: top, bottomInset: bottom, timing: timing))
  }

  /// The row's settled frame in this view's coordinates, when it is placed.
  public func frame(for id: ID) -> CGRect? {
    state.layout.placement(for: id).map { CGRect(x: 0, y: $0.y, width: bounds.width, height: $0.height) }
  }

  /// The view showing the row, when it is placed.
  public func view(for id: ID) -> UIView? {
    slots[id]?.row
  }

  /// Where the row is on screen right now, in this view's coordinates (its settled frame while
  /// nothing is moving).
  public func presentedFrame(for id: ID) -> CGRect? {
    guard let slot = slots[id] else { return nil }
    let row = slot.view.layer.presentation() ?? slot.view.layer
    let scroll = (content.layer.presentation() ?? content.layer).bounds.origin.y
    return CGRect(x: 0, y: row.position.y - scroll, width: slot.width, height: slot.height)
  }

  /// Starts a fling as if a finger had released at this velocity (points per second, positive:
  /// the content moves down).
  public func fling(velocity: CGFloat) {
    catchFlight()
    release(velocity: velocity)
  }

  /// Stops a fling where it is on screen, as a finger landing does.
  public func stopScrolling() {
    catchFlight()
  }

  /// Numbers for probes and tests.
  public var diagnostics: TimelineDiagnostics {
    let presented = (content.layer.presentation() ?? content.layer).bounds.origin.y
    var top = CGFloat.infinity
    var bottom = -CGFloat.infinity
    for slot in slots.values {
      top = min(top, slot.y)
      bottom = max(bottom, slot.y + slot.height)
    }
    for entry in lingering.values {
      top = min(top, entry.slot.y)
      bottom = max(bottom, entry.slot.y + entry.slot.height)
    }
    return TimelineDiagnostics(
      scrollPosition: origin, presentedScrollPosition: presented, placedTop: top, placedBottom: bottom,
      placedCount: slots.count
    )
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    content.frame = bounds
    scrollToTopProxy.frame = bounds
    syncOrigin()
    let viewport = viewport()
    guard viewport.width > 0, viewport.height > 0 else { return }
    if !beforeFirstLayout.isEmpty {
      let waiting = beforeFirstLayout
      beforeFirstLayout = []
      for transaction in waiting { apply(transaction) }
    }
    guard viewport != state.viewport else { return }
    // A size change inside an animation (rotation) moves with that animation.
    let inherited = UIView.inheritedAnimationDuration
    let timing: TimelineTiming = inherited > 0
      ? .curve(duration: inherited, c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1)
      : .none
    perform(TimelineUpdate(viewport: viewport), timing: timing, changed: [])
  }

  private func viewport() -> TimelineViewport {
    TimelineViewport(width: bounds.width, height: bounds.height, topInset: topInset, bottomInset: bottomInset)
  }

  /// `jump` is set for a change that scrolls to a target, with the side its destination lies on.
  private func perform(
    _ update: TimelineUpdate<ID>, timing: TimelineTiming, changed: Set<ID>, jump: TimelineEdge?? = nil
  ) {
    guard !isApplying else {
      // A change made while another is being applied (a row callback) runs right after it.
      queued.append { [weak self] in self?.perform(update, timing: timing, changed: changed, jump: jump) }
      return
    }
    isApplying = true
    let width = update.viewport?.width ?? state.viewport.width
    let extentBefore = indicatorExtent()
    let spanEnd = rows.spanEnd
    let change = state.apply(update, spanEnd: { spanEnd?($0) }) { rows.height($0, width) }
    var scrolled: CGFloat = 0
    if case let .by(delta) = update.scroll { scrolled = delta }
    commit(
      change, timing: timing, changed: changed, scrolled: scrolled, jump: jump,
      indicatorMoves: update.scroll != .preserve ? extentBefore : nil
    )
    isApplying = false
    if !queued.isEmpty {
      let next = queued.removeFirst()
      next()
    }
  }

  /// `indicatorMoves` is set for a change that scrolls, with the indicator's extent before it.
  private func commit(
    _ change: TimelineChange<ID>, timing: TimelineTiming, changed: Set<ID>, scrolled: CGFloat, jump: TimelineEdge??,
    indicatorMoves: TimelineIndicator.Extent? = nil
  ) {
    let layout = change.layout
    let width = layout.viewport.width
    let animates = timing.isAnimated && window != nil
    // A jump that keeps no placed row: the screen slides out and the destination in next to it.
    let carousel: CGFloat? = animates && change.isDisjoint ? jump.flatMap { carouselTravel(change, towards: $0) } : nil
    if let carousel { parkScreenForCarousel(travel: carousel, timing: timing) }

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
      // Nothing placed before is placed now. A scroll that far still moved by its distance.
      origin -= scrolled
    }
    let originDelta = oldOrigin - origin
    let now = CACurrentMediaTime()

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    var placed: Set<ID> = []
    placed.reserveCapacity(layout.placements.count)
    // How far each row starts from its new place on screen, for what follows the screen.
    var screenFrom: [ID: CGFloat] = [:]
    let tracksScreen = rows.screen != nil && animates
    for placement in layout.placements {
      placed.insert(placement.id)
      let y = placement.y + origin
      if let kept = lingering.removeValue(forKey: placement.id) { slots[placement.id] = kept.slot }
      if let slot = slots[placement.id] {
        let moved = slot.y - y
        let resized = abs(slot.height - placement.height) > 0.01 || abs(slot.width - width) > 0.01
        place(slot, y: y, width: width, height: placement.height)
        if resized || changed.contains(placement.id) {
          rows.update(placement.id, slot.row, width, animates ? timing : .none)
          slot.screen = nil
        }
        if animates, carousel == nil { slot.view.layer.addTrack(timing, keyPath: "position.y", from: moved) }
        if tracksScreen { screenFrom[placement.id] = carousel ?? (moved - originDelta) }
      } else {
        let slot = self.slot(for: rows.make(placement.id, width))
        slots[placement.id] = slot
        place(slot, y: y, width: width, height: placement.height)
        // A new row's first layout is its starting state: done now, outside any animation block the
        // caller (or a system transition running a layout pass) happens to be in.
        UIView.performWithoutAnimation { slot.row.layoutIfNeeded() }
        if animates, carousel == nil {
          // A row placed for the first time travels with its neighbours; one new to the data fades in.
          slot.view.layer.addTrack(timing, keyPath: "position.y", from: (change.offsets[placement.id] ?? 0) + originDelta)
          if change.inserted.contains(placement.id) {
            slot.view.layer.addTrack(timing, keyPath: "opacity", from: -1)
          }
        }
        if tracksScreen { screenFrom[placement.id] = carousel ?? (change.offsets[placement.id] ?? 0) }
      }
    }

    // Rows that fell out of the placed window during an animated change are still on screen until
    // the motion ends: they stay, stacked beyond the window's ends, and travel with it.
    if carousel != nil {
      // The parked screen shows them.
      for (id, entry) in lingering { retire(id, entry.slot) }
      lingering = [:]
    } else if animates, let first = layout.placements.first, let last = layout.placements.last {
      var top = first.y + origin
      var bottom = last.maxY + origin
      let expiry = now + timing.duration
      for placement in change.previous.placements.reversed() {
        guard !placed.contains(placement.id), let index = state.index[placement.id], index < first.index,
              let slot = slots.removeValue(forKey: placement.id) else { continue }
        top -= slot.height
        slot.view.layer.addTrack(timing, keyPath: "position.y", from: slot.y - top)
        place(slot, y: top, width: width, height: slot.height)
        lingering[placement.id] = (slot, expiry)
      }
      for placement in change.previous.placements {
        guard !placed.contains(placement.id), let index = state.index[placement.id], index > last.index,
              let slot = slots.removeValue(forKey: placement.id) else { continue }
        slot.view.layer.addTrack(timing, keyPath: "position.y", from: slot.y - bottom)
        place(slot, y: bottom, width: width, height: slot.height)
        bottom += slot.height
        lingering[placement.id] = (slot, expiry)
      }
      scheduleLingerSweep(after: timing.duration)
    }

    let leaving = Set(change.removed.map(\.id))
    for id in leaving { if let entry = lingering.removeValue(forKey: id) { slots[id] = entry.slot } }
    for (id, slot) in slots where !placed.contains(id) {
      slots[id] = nil
      if animates, carousel == nil, leaving.contains(id) {
        // A deleted row fades where it was while its neighbours close the gap.
        slot.view.layer.opacity = 0
        slot.view.layer.addTrack(timing, keyPath: "opacity", from: 1)
        content.sendSubviewToBack(slot.view)
        let duration = timing.duration
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(duration))
          slot.view.layer.opacity = 1
          if let self { retire(id, slot) } else { slot.view.removeFromSuperview() }
        }
      } else {
        retire(id, slot)
      }
    }

    syncOrigin()
    if let carousel {
      content.layer.addTrack(timing, keyPath: "bounds.origin.y", from: -carousel)
    } else if animates {
      content.layer.addTrack(timing, keyPath: "bounds.origin.y", from: originDelta)
    }
    updatePins(timing: animates && carousel == nil ? timing : .none)
    updateScreens(timing: animates ? timing : .none, from: screenFrom)
    moveIndicator(change, scrolledBy: indicatorMoves.map { ($0, originDelta) }, timing: animates ? timing : .none)
    CATransaction.commit()

    if !change.demands.isEmpty { onDemand?(change.demands) }
    onLayout?(layout)
  }

  // MARK: - Screen

  /// Tells each placed row whose place on screen changed where it is now, how far it starts from
  /// there (`from`, with `timing`), and the running fling's path.
  private func updateScreens(timing: TimelineTiming, from: [ID: CGFloat]) {
    guard let report = rows.screen else { return }
    let layout = state.layout
    let ahead = flight.map { CGFloat($0.path.end - $0.applied) } ?? 0
    let height = layout.viewport.height
    let frameRate = flightFrameRate
    for placement in layout.placements {
      guard let slot = slots[placement.id] else { continue }
      let y = placement.y + ahead
      let travel = from[placement.id] ?? 0
      if abs(travel) <= 0.01, let last = slot.screen, abs(last.y - y) < 0.01, last.height == height,
         last.flight == flight?.start { continue }
      slot.screen = (y, height, flight?.start)
      report(placement.id, slot.row, TimelineRowScreen(
        y: y, height: height,
        flight: flight.map { ($0.path, $0.start, frameRate) },
        transition: abs(travel) > 0.01 && timing.isAnimated ? (timing, travel) : nil
      ))
    }
  }

  private var flightFrameRate: CAFrameRateRange {
    let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
    return CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
  }

  // MARK: - Pins

  /// Brings every placed row's pin to the lift the current state asks for. With an animated timing
  /// a pin whose lift changed moves there on that timing from where it is on screen; while a flight
  /// runs, each pin also gets the flight's path, so it moves on the render server with the content.
  private func updatePins(timing: TimelineTiming) {
    let layout = state.layout
    guard let first = layout.placements.first else { return }
    let edge = layout.viewport.usableBottom
    // The layer's model scroll position is the end of a running flight; the state is where the
    // flight has been realised to.
    let ahead = flight.map { CGFloat($0.path.end - $0.applied) } ?? 0
    let now = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for placement in layout.placements {
      guard let slot = slots[placement.id] else { continue }
      let pin = rows.pin(placement.id, slot.row)
      if let old = slot.pin, old.view !== pin?.view { unpin(slot) }
      guard let pin else { continue }
      // A span starting above the placed rows starts above the screen too: it does not limit.
      var spanTop = -CGFloat.infinity
      if let index = state.index[pin.spanStart], index >= first.index, index - first.index < layout.placements.count {
        let start = layout.placements[index - first.index]
        if let startSlot = slots[start.id] { spanTop = start.y + rows.spanTop(start.id, startSlot.row) }
      }
      let bottom = placement.y + pin.bottom
      let next = PinState(
        view: pin.view, overhang: bottom - edge + ahead, maxLift: max(0, bottom - pin.height - spanTop),
        flightStart: flight?.start
      )
      if let old = slot.pin, old.matches(next) { continue }
      let layer = pin.view.layer
      // Where the pin is on screen now, before this change.
      let shown = slot.pin.map { presentedLift($0, now: now) }
      if slot.pin == nil { slot.view.layer.zPosition = 1 }
      if slot.pin?.lift != next.lift || slot.pin == nil {
        layer.setValue(-next.lift, forKeyPath: "transform.translation.y")
      }
      slot.pin = next
      if let flight {
        bake(layer, next, flight: flight)
      } else {
        layer.removeAnimation(forKey: Self.pinKey)
      }
      // Tracks stack: each is keyed apart, so the next change does not cut the last one short.
      if let shown {
        let delta = presentedLift(next, now: now) - shown
        if abs(delta) > 0.01, let track = timing.track(keyPath: "transform.translation.y", from: delta) {
          pinTrackCount &+= 1
          layer.add(track, forKey: "\(Self.pinKey).\(pinTrackCount)")
        }
      }
    }
  }

  /// The pin's lift on screen at `now`, from its model value and its flight path.
  private func presentedLift(_ pin: PinState, now: CFTimeInterval) -> CGFloat {
    guard let start = pin.flightStart, let flight, flight.start == start else { return pin.lift }
    let time = min(max(0, now - flight.start), flight.path.duration)
    let travel = CGFloat(flight.path.end - flight.path.position(at: time))
    return pinLift(overhang: pin.overhang - travel, maxLift: pin.maxLift)
  }

  /// The flight's path as the pin's lift: the same samples on the same clock as the content's.
  private func bake(_ layer: CALayer, _ pin: PinState, flight: Flight) {
    layer.removeAnimation(forKey: Self.pinKey)
    let path = flight.path
    let end = pin.lift
    var varies = false
    let values: [NSNumber] = path.positions.map { position in
      let lift = pinLift(overhang: pin.overhang - CGFloat(path.end - position), maxLift: pin.maxLift)
      if abs(lift - end) > 0.01 { varies = true }
      return NSNumber(value: Double(end - lift))
    }
    guard varies else { return }
    let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
    animation.values = values
    animation.duration = path.duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    animation.beginTime = layer.convertTime(flight.start, from: nil)
    animation.isRemovedOnCompletion = true
    animation.fillMode = .backwards
    let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
    layer.add(animation, forKey: Self.pinKey)
  }

  /// The pin goes back to rest: its row left, or no longer has it.
  private func unpin(_ slot: Slot) {
    guard let pin = slot.pin else { return }
    slot.pin = nil
    slot.view.layer.zPosition = 0
    let layer = pin.view.layer
    for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.pinKey) {
      layer.removeAnimation(forKey: key)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.setValue(0, forKeyPath: "transform.translation.y")
    CATransaction.commit()
  }

  /// A lifted pin hangs outside its row, where the row's own hit test does not look.
  override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) {
      for slot in slots.values {
        guard let pin = slot.pin, pin.lift > 0.5, !pin.view.isHidden, pin.view.alpha > 0.01,
              pin.view.isUserInteractionEnabled else { continue }
        let local = pin.view.convert(point, from: self)
        if pin.view.point(inside: local, with: event), let hit = pin.view.hitTest(local, with: event) { return hit }
      }
    }
    return super.hitTest(point, with: event)
  }

  // MARK: - Carousel

  /// How far the destination starts from where it settles, positive below: its strip of placed rows
  /// starts against the edge of what was on screen, on the side it lies on. Nil when there is nothing
  /// to slide.
  private func carouselTravel(_ change: TimelineChange<ID>, towards hint: TimelineEdge?) -> CGFloat? {
    let old = change.previous
    guard let oldFirst = old.placements.first, let oldLast = old.placements.last,
          let newFirst = change.layout.placements.first, let newLast = change.layout.placements.last
    else { return nil }
    let towards: TimelineEdge = state.index[oldFirst.id].map { $0 < newFirst.index ? .newer : .older } ?? hint ?? .newer
    let height = old.viewport.height
    let travel: CGFloat = switch towards {
      // Newer rows are below: the destination's top starts at the bottom of what was on screen.
      case .newer: min(height, oldLast.maxY) - newFirst.y
      // Older rows are above: the destination's bottom starts at the top of what was on screen.
      case .older: max(0, oldFirst.y) - newLast.maxY
    }
    // A strip already past the edge would overlap the screen: start a screen away instead.
    switch towards {
      case .newer: return travel > 0 ? travel : height
      case .older: return travel < 0 ? travel : -height
    }
  }

  /// Puts a picture of the screen under the content, to move by `-travel` with the same timing as
  /// the content's track, so the two strips stay joined.
  private func parkScreenForCarousel(travel: CGFloat, timing: TimelineTiming) {
    // What is on screen now, a carousel still running included; the new one starts from it.
    let picture = snapshotView(afterScreenUpdates: false)
    carouselExit?.removeFromSuperview()
    carouselExit = nil
    content.layer.removeAllAnimations()
    guard let picture else { return }
    picture.frame = bounds
    picture.isUserInteractionEnabled = false
    insertSubview(picture, belowSubview: content)
    carouselExit = picture
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    picture.layer.position.y -= travel
    picture.layer.addTrack(timing, keyPath: "position.y", from: travel)
    CATransaction.commit()
    Task { @MainActor [weak self, weak picture] in
      try? await Task.sleep(for: .seconds(timing.duration + 0.05))
      guard let picture else { return }
      picture.removeFromSuperview()
      if self?.carouselExit === picture { self?.carouselExit = nil }
    }
  }

  private func scheduleLingerSweep(after delay: CFTimeInterval) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay + 0.02))
      self?.sweepLingering()
    }
  }

  private func sweepLingering() {
    let now = CACurrentMediaTime()
    for (id, entry) in lingering where entry.expiry <= now {
      lingering[id] = nil
      retire(id, entry.slot)
    }
  }

  /// The slot for a row view the host made: the retired one still holding it, or a new one.
  private func slot(for row: UIView) -> Slot {
    if let index = slotPool.firstIndex(where: { $0.row === row }) {
      let pooled = slotPool.remove(at: index)
      if row.superview === pooled.view {
        pooled.view.isHidden = false
        return pooled
      }
      pooled.view.removeFromSuperview()
    }
    let slot = Slot(row: row)
    content.addSubview(slot.view)
    return slot
  }

  /// A slot leaves the list: its row goes back to the host, the slot is hidden for reuse.
  private func retire(_ id: ID, _ slot: Slot) {
    unpin(slot)
    slot.screen = nil
    slot.view.layer.removeAllAnimations()
    rows.recycle(id, slot.row)
    guard slotPool.count < Self.slotPoolLimit else {
      slot.view.removeFromSuperview()
      return
    }
    slot.view.isHidden = true
    slotPool.append(slot)
  }

  private func place(_ slot: Slot, y: CGFloat, width: CGFloat, height: CGFloat) {
    // While the list scrolls, rows keep their content coordinates: most frames change nothing here,
    // and setting the same geometry still costs a layer update.
    guard slot.y != y || slot.width != width || slot.height != height else { return }
    slot.y = y
    slot.width = width
    slot.height = height
    slot.view.layer.position = CGPoint(x: 0, y: y)
    slot.view.bounds = CGRect(x: 0, y: 0, width: width, height: height)
    slot.row.frame = slot.view.bounds
  }

  /// The layer's scroll position: the state's, plus what a running flight still has to travel
  /// (its animation is additive and ends at zero).
  private func syncOrigin() {
    var value = origin
    if let flight { value -= CGFloat(flight.path.end - flight.applied) }
    guard content.bounds.origin.y != value else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.bounds.origin.y = value
    CATransaction.commit()
  }

  // MARK: - Scroll indicator

  /// Seconds the indicator stays after the list stops, and its fade.
  private static var indicatorFadeDelay: TimeInterval { 0.5 }
  private static var indicatorFade: TimeInterval { 0.3 }
  private var indicatorShown = false
  private var indicatorTrackCount = 0

  private func indicatorExtent() -> TimelineIndicator.Extent {
    // Beyond a loaded end that is not a real end, two screens stand for the unknown rest.
    state.layout.indicatorExtent(
      rowCount: state.rows.count, coverage: state.coverage, unknown: 2 * state.viewport.usableHeight
    )
  }

  /// The thumb travels the usable area, inset at both ends.
  private func indicatorTrack() -> (top: CGFloat, length: CGFloat) {
    let viewport = state.viewport
    let inset = TimelineScrollIndicatorView.inset
    return (viewport.usableTop + inset, max(0, viewport.usableHeight - 2 * inset))
  }

  private func indicatorTop(_ progress: CGFloat, track: (top: CGFloat, length: CGFloat)) -> CGFloat {
    track.top + progress * max(0, track.length - indicatorLength)
  }

  /// The thumb's place after a change: on a flight's baked path while one runs, from the estimate
  /// when the list opens or jumps to rows it did not show, moved with the content when it scrolls,
  /// and left where it is otherwise (rows arriving, leaving, growing; insets).
  private func moveIndicator(
    _ change: TimelineChange<ID>, scrolledBy scroll: (extent: TimelineIndicator.Extent, delta: CGFloat)?,
    timing: TimelineTiming
  ) {
    let before = indicatorView.layer.position.y
    // A programmatic scroll shows the thumb travelling, as UIScrollView's animated scrolls do; a
    // hidden thumb counts as shown while it is placed, so it gets its track.
    let reveals = timing.isAnimated && (scroll != nil || change.isDisjoint) && showsScrollIndicator
    let wasShown = indicatorShown
    if reveals { indicatorShown = true }
    if let flight, let baked = indicatorFlight, baked.start == flight.start {
      indicator.progress = TimelineIndicator.progress(
        baked.progress, extent: baked.extent, moved: CGFloat(flight.applied - baked.applied)
      )
    } else if change.previous.placements.isEmpty || change.isDisjoint {
      indicator.progress = TimelineIndicator.estimate(indicatorExtent())
    } else if let scroll {
      indicator.move(by: scroll.delta, extent: scroll.extent)
    }
    placeIndicator(timing: timing)
    guard reveals else { return }
    if abs(indicatorView.layer.position.y - before) > 0.5 {
      showIndicator()
      scheduleIndicatorHide(after: timing.duration + Self.indicatorFadeDelay)
    } else {
      indicatorShown = wasShown
    }
  }

  /// Sets the thumb's model geometry: its place for the state, or a running flight's end. A change
  /// with an animated timing moves it there with an additive track, as rows move.
  private func placeIndicator(timing: TimelineTiming) {
    let extent = indicatorExtent()
    let track = indicatorTrack()
    guard showsScrollIndicator, extent.isScrollable, track.length > TimelineScrollIndicatorView.minimumLength else {
      indicatorView.isHidden = true
      return
    }
    indicatorView.isHidden = false
    let layer = indicatorView.layer
    let oldTop = layer.position.y
    let oldLength = layer.bounds.height
    var lengthMoves = false
    let key = IndicatorLengthKey(rows: state.rows.count, coverage: state.coverage, track: track.length)
    if indicatorFlight == nil, !indicatorShown || indicatorLengthKey != key {
      let length = TimelineIndicator.length(extent, track: track.length, minimum: TimelineScrollIndicatorView.minimumLength)
      lengthMoves = indicatorShown && abs(length - indicatorLength) > 0.5
      indicatorLength = length
      indicatorLengthKey = key
    }
    var progress = indicator.progress
    if let flight, let baked = indicatorFlight, baked.start == flight.start {
      progress = TimelineIndicator.progress(
        baked.progress, extent: baked.extent, moved: CGFloat(flight.path.end - baked.applied)
      )
    }
    let top = indicatorTop(progress, track: track)
    let x = bounds.width - TimelineScrollIndicatorView.inset - TimelineScrollIndicatorView.width
    let size = CGSize(width: TimelineScrollIndicatorView.width, height: indicatorLength)
    guard layer.position != CGPoint(x: x, y: top) || layer.bounds.size != size else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.bounds = CGRect(origin: .zero, size: size)
    layer.position = CGPoint(x: x, y: top)
    if indicatorShown {
      // Tracks stack (each from the old model value), as the rows' do.
      let timing = lengthMoves && !timing.isAnimated
        ? TimelineTiming.curve(duration: 0.2, c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1) : timing
      for (keyPath, delta) in [("position.y", oldTop - top), ("bounds.size.height", oldLength - indicatorLength)]
        where abs(delta) > 0.01 && (lengthMoves || keyPath == "position.y")
      {
        guard let track = timing.track(keyPath: keyPath, from: delta) else { continue }
        indicatorTrackCount &+= 1
        layer.add(track, forKey: "\(Self.indicatorTrackKey).\(indicatorTrackCount)")
      }
    }
    CATransaction.commit()
  }

  private struct IndicatorLengthKey: Equatable {
    var rows: Int
    var coverage: TimelineCoverage
    var track: CGFloat
  }

  /// A flight's thumb moves on the render server with the content: the flight's samples mapped to
  /// thumb places by the indicator's rule from where it is now, on the content's clock. Linear on
  /// each side of the start, so the thumb follows the content exactly whatever the main thread does.
  private func bakeIndicator(_ flight: Flight) {
    let layer = indicatorView.layer
    layer.removeAnimation(forKey: Self.indicatorFlightKey)
    let extent = indicatorExtent()
    guard extent.isScrollable else {
      indicatorFlight = nil
      return
    }
    let baked = (start: flight.start, progress: indicator.progress, extent: extent, applied: flight.applied)
    indicatorFlight = baked
    placeIndicator(timing: .none)
    let track = indicatorTrack()
    let path = flight.path
    func top(_ displacement: Double) -> CGFloat {
      indicatorTop(
        TimelineIndicator.progress(baked.progress, extent: extent, moved: CGFloat(displacement - baked.applied)),
        track: track
      )
    }
    let end = top(path.end)
    var varies = false
    let values: [NSNumber] = path.positions.map { position in
      let offset = top(position) - end
      if abs(offset) > 0.01 { varies = true }
      return NSNumber(value: Double(offset))
    }
    guard varies, !indicatorView.isHidden else { return }
    let animation = CAKeyframeAnimation(keyPath: "position.y")
    animation.values = values
    animation.duration = path.duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    animation.beginTime = layer.convertTime(flight.start, from: nil)
    animation.isRemovedOnCompletion = true
    animation.fillMode = .backwards
    animation.preferredFrameRateRange = flightFrameRate
    layer.add(animation, forKey: Self.indicatorFlightKey)
  }

  /// The flight stopped: the thumb leaves its path at the state's place. The scroll that brings the
  /// state to where the content stopped moves it on from there.
  private func endIndicatorFlight() {
    guard indicatorFlight != nil else { return }
    indicatorFlight = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    indicatorView.layer.removeAnimation(forKey: Self.indicatorFlightKey)
    placeIndicator(timing: .none)
    CATransaction.commit()
  }

  private func showIndicator() {
    indicatorHide?.cancel()
    indicatorHide = nil
    guard showsScrollIndicator else { return }
    if !indicatorShown {
      // Measured afresh while hidden: what it shows now is the current estimate's length.
      placeIndicator(timing: .none)
      indicatorShown = true
    }
    guard !indicatorView.isHidden else { return }
    indicatorView.layer.removeAnimation(forKey: "opacity")
    indicatorView.alpha = 1
  }

  private func scheduleIndicatorHide(after delay: TimeInterval = indicatorFadeDelay) {
    guard indicatorShown, !isTracking, flight == nil else { return }
    indicatorHide?.cancel()
    let hide = DispatchWorkItem { [weak self] in self?.hideIndicator(animated: true) }
    indicatorHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hide)
  }

  private func hideIndicator(animated: Bool) {
    indicatorHide?.cancel()
    indicatorHide = nil
    guard !animated || (!isTracking && flight == nil) else { return }
    indicatorShown = false
    guard animated else {
      indicatorView.layer.removeAnimation(forKey: "opacity")
      indicatorView.alpha = 0
      return
    }
    UIView.animate(withDuration: Self.indicatorFade, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.indicatorView.alpha = 0
    }
  }

  // MARK: - Accessibility

  /// The placed rows, top to bottom. Their views are made and recycled in any order.
  override public var accessibilityElements: [Any]? {
    get {
      var shown = Array(slots.values)
      shown.append(contentsOf: lingering.values.map(\.slot))
      shown.sort { $0.y < $1.y }
      return shown.map(\.row)
    }
    set {}
  }

  /// VoiceOver's three-finger swipes: about a screen at a time, with the list's row motion. A swipe
  /// up shows newer rows, as it shows what is below in a scroll view.
  override public func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    let edge: TimelineEdge
    switch direction {
      case .down, .previous: edge = .older
      case .up, .next: edge = .newer
      default: return false
    }
    guard !isTracking else { return false }
    let layout = state.layout
    let room = edge == .older ? layout.distanceToOldest : layout.distanceToNewest
    let isRealEnd = edge == .older ? state.coverage.reachesOldest : state.coverage.reachesNewest
    // At a real end there is nothing to page to; VoiceOver plays its boundary sound.
    if let room, room < 0.5, isRealEnd { return false }
    let page = max(44, layout.viewport.usableHeight - 44)
    apply(TimelineTransaction(scroll: .by(edge == .older ? page : -page), timing: .standard))
    let words = accessibilityPageDescription?(edge) ?? (edge == .older ? "Older" : "Newer")
    UIAccessibility.post(notification: .pageScrolled, argument: words)
    return true
  }

  /// VoiceOver moved to an element of a row that is not wholly in the usable area (rows beyond the
  /// screen are placed too): the list brings it in, as a scroll view does, which places the rows
  /// beyond it and asks for history at a loaded end.
  @objc private func accessibilityFocusChanged(_ note: Notification) {
    guard window != nil, !isTracking, flight == nil,
          let element = note.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject
    else { return }
    revealAccessibilityElement(element)
  }

  /// Scrolls the row holding `element` into the usable area; false when it is not in a placed row.
  @discardableResult
  public func revealAccessibilityElement(_ element: NSObject) -> Bool {
    var container: Any? = element
    var view: UIView?
    while let object = container {
      if let found = object as? UIView {
        view = found
        break
      }
      container = (object as? UIAccessibilityElement)?.accessibilityContainer
    }
    guard let view, let (id, _) = slots.first(where: { view.isDescendant(of: $0.value.view) }),
          var target = frame(for: id) else { return false }
    // The element itself when it is smaller than its row (a line of a long message).
    if let window {
      let shown = convert(window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace), from: window)
      if !shown.isEmpty, shown.height < target.height { target = shown }
    }
    let viewport = state.viewport
    var delta: CGFloat = 0
    if target.minY < viewport.usableTop {
      delta = viewport.usableTop - target.minY
    } else if target.maxY > viewport.usableBottom {
      delta = max(viewport.usableBottom - target.maxY, viewport.usableTop - target.minY)
    }
    if abs(delta) > 0.5 { apply(TimelineTransaction(scroll: .by(delta), timing: .standard)) }
    return true
  }

  // MARK: - Dragging

  private func handlePan(_ pan: TimelinePanGestureRecognizer) {
    switch pan.state {
      case .began:
        catchFlight()
        caughtFlight = false
        isTracking = true
        lastDragShown = nil
        input.startTicking(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond ?? 60)
        lastTranslation = pan.translation(in: self).y
        let shown = -state.layout.restShift
        let dimension = Double(max(1, state.viewport.usableHeight))
        pulled = shown == 0 ? 0 : (shown > 0 ? 1 : -1) * CGFloat(physics.rubberBandInverse(Double(abs(shown)), dimension: dimension))
        showIndicator()
        onDragBegan?()
      case .changed:
        let translation = pan.translation(in: self).y
        drag(by: translation - lastTranslation)
        lastTranslation = translation
      case .ended, .cancelled, .failed:
        guard isTracking else { return }
        isTracking = false
        var velocity = pan.state == .ended ? pan.releaseVelocity() : 0
        if let releaseVelocityFilter { velocity = releaseVelocityFilter(velocity) }
        release(velocity: velocity)
      default:
        break
    }
  }

  /// Moves the content with the finger. Past an end the finger's distance is rubber banded.
  private func drag(by delta: CGFloat) {
    guard delta != 0 else { return }
    let layout = state.layout
    let dimension = Double(max(1, layout.viewport.usableHeight))
    let shown = -layout.restShift
    var rest = delta
    var moved: CGFloat = 0

    if pulled != 0 {
      if (pulled > 0) == (rest > 0) {
        pulled += rest
        rest = 0
      } else {
        let taken = min(abs(rest), abs(pulled))
        pulled -= (pulled > 0 ? 1 : -1) * taken
        rest -= (rest > 0 ? 1 : -1) * taken
      }
    }
    if rest != 0 {
      let room = rest > 0 ? layout.distanceToOldest : layout.distanceToNewest
      let allowed = room.map { min(abs(rest), $0) } ?? abs(rest)
      moved = (rest > 0 ? 1 : -1) * allowed
      pulled += rest - moved
    }
    let nowShown = pulled == 0 ? 0 : (pulled > 0 ? 1 : -1) * CGFloat(physics.rubberBanded(Double(abs(pulled)), dimension: dimension))
    scroll(by: moved + (nowShown - shown))
    lastDragShown = nextFrameTime()
  }

  /// When a change made now reaches the screen: the frame being prepared, or a later one.
  private func nextFrameTime() -> CFTimeInterval {
    let now = CACurrentMediaTime()
    guard let clock = frameClock, clock.duration > 0 else { return now }
    var time = clock.target
    var steps = 0
    while time < now, steps < 8 {
      time += clock.duration
      steps += 1
    }
    return max(time, now)
  }

  private func scroll(by delta: CGFloat) {
    guard abs(delta) > 0.0001 else { return }
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    update.allowsOverscroll = true
    perform(update, timing: .none, changed: [])
  }

  // MARK: - Flings

  /// Bakes the whole path, hands it to the render server and starts realising rows along it.
  private func release(velocity: CGFloat) {
    pulled = 0
    let layout = state.layout
    let shown = Double(-layout.restShift)
    var lower = layout.distanceToNewest.map { -Double($0) }
    var upper = layout.distanceToOldest.map { Double($0) }
    if shown > 0.25 {
      // Pulled past the oldest end: the end is behind us.
      upper = -shown
      lower = lower.map { min($0, -shown) }
    } else if shown < -0.25 {
      lower = -shown
      upper = upper.map { max($0, -shown) }
    } else if abs(velocity) < physics.minimumFlingVelocity {
      rest()
      return
    }
    // The path continues the finger's motion from the frame that showed its last movement, not from
    // when the release is handled, which is often a frame later: starting then would hold the
    // content still for that frame. More than two frames back the finger had stopped anyway.
    // When the last movement and the lift share a frame, that frame is still to come.
    let now = CACurrentMediaTime()
    let frame = frameClock?.duration ?? 1.0 / 60
    let begin = lastDragShown.map { min(now + frame, max($0, now - 2 * frame)) } ?? now
    start(Flight(
      path: physics.path(velocity: Double(velocity), lower: lower, upper: upper), start: begin,
      applied: 0, lower: lower, upper: upper
    ))
  }

  private func start(_ flight: Flight) {
    guard flight.path.duration > 0.02 else {
      self.flight = nil
      content.layer.removeAnimation(forKey: Self.flightKey)
      scroll(by: CGFloat(flight.path.end - flight.applied))
      rest()
      return
    }
    let path = flight.path
    let animation = CAKeyframeAnimation(keyPath: "bounds.origin.y")
    // The layer's value is the path's end; the animation adds what is still to travel.
    animation.values = path.positions.map { NSNumber(value: path.end - $0) }
    animation.duration = path.duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    animation.beginTime = content.layer.convertTime(flight.start, from: nil)
    animation.isRemovedOnCompletion = true
    // A path that starts at a frame still to come holds its first position until then.
    animation.fillMode = .backwards
    let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.flight = flight
    syncOrigin()
    content.layer.add(animation, forKey: Self.flightKey)
    updatePins(timing: .none)
    updateScreens(timing: .none, from: [:])
    bakeIndicator(flight)
    CATransaction.commit()
    showIndicator()
    input.startTicking(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond ?? 60)
  }

  /// Each frame: move the state to where the path is at the frame's time, which realises the rows
  /// coming into view. The motion itself does not depend on this running on time.
  private func tick(_ link: CADisplayLink) {
    frameClock = (link.targetTimestamp, link.targetTimestamp - link.timestamp)
    guard var flight else {
      if !isTracking { input.stopTicking() }
      return
    }
    let now = CACurrentMediaTime()
    let time = min(max(0, max(link.targetTimestamp, now) - flight.start), flight.path.duration)
    let position = flight.path.position(at: time)
    // Realise further ahead the faster it goes, so a late frame still finds its rows there.
    let ahead = min(CGFloat(abs(flight.path.velocity(at: time))) * Self.lookahead, state.viewport.height)
    let moving = flight.path.velocity(at: time)
    state.margins = TimelineMargins(
      above: TimelineMargins.standard.above + (moving > 0 ? ahead : 0),
      below: TimelineMargins.standard.below + (moving < 0 ? ahead : 0)
    )
    let delta = position - flight.applied
    flight.applied = position
    self.flight = flight
    scroll(by: CGFloat(delta))

    if now - flight.start >= flight.path.duration {
      endFlight(settle: true)
    } else {
      rebakeIfEndsChanged(now: now)
    }
  }

  /// Rows that loaded during the fling can bring an end into reach, or take one away. The rest of
  /// the path is baked again from the path's own position and velocity at `now`, on the same clock.
  private func rebakeIfEndsChanged(now: CFTimeInterval) {
    guard let flight, abs(state.layout.restShift) < 0.25 else { return }
    let layout = state.layout
    let upper = layout.distanceToOldest.map { flight.applied + Double($0) }
    let lower = layout.distanceToNewest.map { flight.applied - Double($0) }

    func differs(_ a: Double?, _ b: Double?) -> Bool {
      switch (a, b) {
        case (nil, nil): false
        case let (a?, b?): abs(a - b) > 0.5
        default: true
      }
    }
    let end = flight.path.end
    let upperMatters = differs(upper, flight.upper) && (flight.path.touchesUpper || (upper.map { $0 < end - 0.5 } ?? false))
    let lowerMatters = differs(lower, flight.lower) && (flight.path.touchesLower || (lower.map { $0 > end + 0.5 } ?? false))
    guard upperMatters || lowerMatters else { return }

    let time = min(max(0, now - flight.start), flight.path.duration)
    let position = flight.path.position(at: time)
    let velocity = flight.path.velocity(at: time)
    let path = physics.path(
      velocity: velocity, lower: lower.map { $0 - position }, upper: upper.map { $0 - position }, scalesVelocity: false
    )
    content.layer.removeAnimation(forKey: Self.flightKey)
    start(Flight(
      path: path, start: now, applied: flight.applied - position, lower: lower.map { $0 - position },
      upper: upper.map { $0 - position }
    ))
  }

  /// A finger landed: stop exactly where the content is on screen.
  /// A finger that caught a fling lifted without dragging: the content rests where it stopped.
  private func tapEnded() {
    guard caughtFlight, !isTracking else { return }
    caughtFlight = false
    rest()
  }

  private func catchFlight() {
    guard let flight else { return }
    caughtFlight = true
    lastFlightCatch = CACurrentMediaTime()
    var position = flight.path.position(at: min(max(0, CACurrentMediaTime() - flight.start), flight.path.duration))
    if content.layer.animationKeys() == [Self.flightKey], let presented = content.layer.presentation() {
      // Nothing else is moving the content, so what is presented is the path's position exactly.
      position = Double(origin) + flight.applied - Double(presented.bounds.origin.y)
    }
    self.flight = nil
    state.margins = .standard
    content.layer.removeAnimation(forKey: Self.flightKey)
    endIndicatorFlight()
    input.stopTicking()
    scroll(by: CGFloat(position - flight.applied))
    syncOrigin()
    updatePins(timing: .none)
    updateScreens(timing: .none, from: [:])
    // A drag beginning shows it again; a touch that only stopped the list lets it fade.
    scheduleIndicatorHide()
  }

  private func endFlight(settle: Bool) {
    guard let flight else { return }
    self.flight = nil
    state.margins = .standard
    content.layer.removeAnimation(forKey: Self.flightKey)
    endIndicatorFlight()
    input.stopTicking()
    if settle {
      scroll(by: CGFloat(flight.path.end - flight.applied))
      rest()
    } else {
      // Another change takes over from where the content is now.
      let position = flight.path.position(at: min(max(0, CACurrentMediaTime() - flight.start), flight.path.duration))
      scroll(by: CGFloat(position - flight.applied))
      syncOrigin()
    }
    updatePins(timing: .none)
    updateScreens(timing: .none, from: [:])
  }

  /// Brings the content inside its limits and onto whole pixels, then reports the stop.
  private func rest() {
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(0))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
    if let first = state.layout.placements.first {
      let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
      let aligned = (first.y * scale).rounded() / scale
      if abs(aligned - first.y) > 0.001 {
        update.scroll = .by(aligned - first.y)
        perform(update, timing: .none, changed: [])
      }
    }
    syncOrigin()
    scheduleIndicatorHide()
    onScrollEnded?()
  }
}
/// How far a pin is lifted: as far as its resting place is below the visible bottom edge, at most
/// to its span's top.
private func pinLift(overhang: CGFloat, maxLift: CGFloat) -> CGFloat {
  max(0, min(overhang, maxLift))
}
#endif
