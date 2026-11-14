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

  public init(
    height: @escaping (ID, CGFloat) -> CGFloat,
    make: @escaping (ID, CGFloat) -> UIView,
    update: @escaping (ID, UIView, CGFloat, TimelineTiming) -> Void = { _, _, _, _ in },
    recycle: @escaping (ID, UIView) -> Void = { _, _ in }
  ) {
    self.height = height
    self.make = make
    self.update = update
    self.recycle = recycle
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

  public init(
    rows: [ID]? = nil, coverage: TimelineCoverage? = nil, scroll: TimelineScroll<ID> = .preserve,
    topInset: CGFloat? = nil, bottomInset: CGFloat? = nil, changed: Set<ID> = [], timing: TimelineTiming = .none
  ) {
    self.rows = rows
    self.coverage = coverage
    self.scroll = scroll
    self.topInset = topInset
    self.bottomInset = bottomInset
    self.changed = changed
    self.timing = timing
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

  public private(set) var isTracking = false
  public var isDecelerating: Bool { flight != nil }
  public var layout: TimelineLayout<ID> { state.layout }
  public var position: TimelinePosition<ID> { state.position }
  public var panGestureRecognizer: UIPanGestureRecognizer { input.pan }

  private var state: TimelineState<ID>
  private let content = UIView()
  private var slots: [ID: Slot] = [:]
  /// Rows no longer in the placed window that an animation still shows.
  private var lingering: [ID: (slot: Slot, expiry: CFTimeInterval)] = [:]
  /// The scroll position the state's layout is expressed against: content y = viewport y + origin.
  private var origin: CGFloat = 0
  private let input = TimelineInput()
  private var flight: Flight?
  private var lastTranslation: CGFloat = 0
  /// How far the finger has pulled past an end, before the rubber band.
  private var pulled: CGFloat = 0
  private var isApplying = false
  private var queued: [() -> Void] = []
  private var beforeFirstLayout: [TimelineTransaction<ID>] = []
  private var topInset: CGFloat = 0
  private var bottomInset: CGFloat = 0

  private final class Slot {
    let view: UIView
    let row: UIView
    var y: CGFloat = 0
    var height: CGFloat = 0
    var width: CGFloat = 0

    init(row: UIView) {
      self.row = row
      view = UIView()
      view.layer.anchorPoint = .zero
      view.addSubview(row)
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
  /// Seconds of travel realised beyond the standard margins while flinging.
  private static var lookahead: CGFloat { 0.1 }

  public init(rows: TimelineRows<ID>) {
    self.rows = rows
    state = TimelineState(viewport: TimelineViewport(width: 0, height: 0))
    super.init(frame: .zero)
    clipsToBounds = true
    addSubview(content)
    addGestureRecognizer(input.pan)
    input.pan.onTouchDown = { [weak self] in self?.catchFlight() }
    input.onPan = { [weak self] pan in self?.handlePan(pan) }
    input.onTick = { [weak self] link in self?.tick(link) }
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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
    if transaction.scroll != .preserve, flight != nil, !isTracking { endFlight(settle: false) }
    perform(update, timing: transaction.timing, changed: transaction.changed)
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

  private func perform(_ update: TimelineUpdate<ID>, timing: TimelineTiming, changed: Set<ID>) {
    guard !isApplying else {
      // A change made while another is being applied (a row callback) runs right after it.
      queued.append { [weak self] in self?.perform(update, timing: timing, changed: changed) }
      return
    }
    isApplying = true
    let width = update.viewport?.width ?? state.viewport.width
    let change = state.apply(update) { rows.height($0, width) }
    var scrolled: CGFloat = 0
    if case let .by(delta) = update.scroll { scrolled = delta }
    commit(change, timing: timing, changed: changed, scrolled: scrolled)
    isApplying = false
    if !queued.isEmpty {
      let next = queued.removeFirst()
      next()
    }
  }

  private func commit(_ change: TimelineChange<ID>, timing: TimelineTiming, changed: Set<ID>, scrolled: CGFloat) {
    let layout = change.layout
    let width = layout.viewport.width
    let animates = timing.isAnimated && window != nil

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
        }
        if animates { slot.view.layer.addTrack(timing, keyPath: "position.y", from: moved) }
      } else {
        let slot = Slot(row: rows.make(placement.id, width))
        slots[placement.id] = slot
        place(slot, y: y, width: width, height: placement.height)
        content.addSubview(slot.view)
        if animates {
          // A row placed for the first time travels with its neighbours; one new to the data fades in.
          slot.view.layer.addTrack(timing, keyPath: "position.y", from: (change.offsets[placement.id] ?? 0) + originDelta)
          if change.inserted.contains(placement.id) {
            slot.view.layer.addTrack(timing, keyPath: "opacity", from: -1)
          }
        }
      }
    }

    // Rows that fell out of the placed window during an animated change are still on screen until
    // the motion ends: they stay, stacked beyond the window's ends, and travel with it.
    if animates, let first = layout.placements.first, let last = layout.placements.last {
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
      if animates, leaving.contains(id) {
        // A deleted row fades where it was while its neighbours close the gap.
        slot.view.layer.opacity = 0
        slot.view.layer.addTrack(timing, keyPath: "opacity", from: 1)
        content.sendSubviewToBack(slot.view)
        let recycle = rows.recycle
        let duration = timing.duration
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(duration))
          slot.view.removeFromSuperview()
          slot.view.layer.opacity = 1
          recycle(id, slot.row)
        }
      } else {
        slot.view.removeFromSuperview()
        rows.recycle(id, slot.row)
      }
    }

    syncOrigin()
    if animates { content.layer.addTrack(timing, keyPath: "bounds.origin.y", from: originDelta) }
    CATransaction.commit()

    if !change.demands.isEmpty { onDemand?(change.demands) }
    onLayout?(layout)
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
      entry.slot.view.removeFromSuperview()
      rows.recycle(id, entry.slot.row)
    }
  }

  private func place(_ slot: Slot, y: CGFloat, width: CGFloat, height: CGFloat) {
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

  // MARK: - Dragging

  private func handlePan(_ pan: TimelinePanGestureRecognizer) {
    switch pan.state {
      case .began:
        catchFlight()
        isTracking = true
        lastTranslation = pan.translation(in: self).y
        let shown = -state.layout.restShift
        let dimension = Double(max(1, state.viewport.usableHeight))
        pulled = shown == 0 ? 0 : (shown > 0 ? 1 : -1) * CGFloat(physics.rubberBandInverse(Double(abs(shown)), dimension: dimension))
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
    start(Flight(
      path: physics.path(velocity: Double(velocity), lower: lower, upper: upper), start: CACurrentMediaTime(),
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
    let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
    animation.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    self.flight = flight
    syncOrigin()
    content.layer.add(animation, forKey: Self.flightKey)
    CATransaction.commit()
    input.startTicking(maximumFramesPerSecond: window?.screen.maximumFramesPerSecond ?? 60)
  }

  /// Each frame: move the state to where the path is at the frame's time, which realises the rows
  /// coming into view. The motion itself does not depend on this running on time.
  private func tick(_ link: CADisplayLink) {
    guard var flight else {
      input.stopTicking()
      return
    }
    let now = CACurrentMediaTime()
    let time = min(max(link.targetTimestamp, now) - flight.start, flight.path.duration)
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

    let time = min(now - flight.start, flight.path.duration)
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
  private func catchFlight() {
    guard let flight else { return }
    var position = flight.path.position(at: min(CACurrentMediaTime() - flight.start, flight.path.duration))
    if content.layer.animationKeys() == [Self.flightKey], let presented = content.layer.presentation() {
      // Nothing else is moving the content, so what is presented is the path's position exactly.
      position = Double(origin) + flight.applied - Double(presented.bounds.origin.y)
    }
    self.flight = nil
    state.margins = .standard
    content.layer.removeAnimation(forKey: Self.flightKey)
    input.stopTicking()
    scroll(by: CGFloat(position - flight.applied))
    syncOrigin()
  }

  private func endFlight(settle: Bool) {
    guard let flight else { return }
    self.flight = nil
    state.margins = .standard
    content.layer.removeAnimation(forKey: Self.flightKey)
    input.stopTicking()
    if settle {
      scroll(by: CGFloat(flight.path.end - flight.applied))
      rest()
    } else {
      // Another change takes over from where the content is now.
      let position = flight.path.position(at: min(CACurrentMediaTime() - flight.start, flight.path.duration))
      scroll(by: CGFloat(position - flight.applied))
      syncOrigin()
    }
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
    onScrollEnded?()
  }
}
#endif
