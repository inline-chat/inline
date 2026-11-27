#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

// Flings: the whole path is baked at release from AppKit's own momentum calculator and handed to the render server;
// the display link only realises rows along it. Rows that load during the fling can move an end: the rest of the
// path is baked again on the same clock.

extension TimelineListView {
  func release(velocity: CGFloat, native: Bool = false) {
    pulled = 0
    // A new fling: tick timing starts afresh (the gap since the last fling's ticks is not a late tick).
    lastTick = 0
    tickGap = 1.0 / Double(window?.screen?.maximumFramesPerSecond ?? 60)
    frontiers = []
    let layout = state.layout
    let shown = Double(-layout.restShift)
    var lower = layout.distanceToNewest.map { -Double($0) }
    var upper = layout.distanceToOldest.map { Double($0) }
    if shown > 0.25 {
      upper = -shown
      lower = lower.map { min($0, -shown) }
    } else if shown < -0.25 {
      lower = -shown
      upper = upper.map { max($0, -shown) }
    } else if abs(Double(velocity)) < NativeScrolling.minimumFlingVelocity {
      rest()
      return
    }
    // Past an end (a return) AppKit's calculator bounces; a fling has the system's shape and stops only at real ends:
    // a loaded end with more history beyond is not a wall (its page is asked for 40 rows ahead and lands meanwhile).
    if abs(shown) <= 0.25 {
      if !state.coverage.reachesOldest { upper = nil }
      if !state.coverage.reachesNewest { lower = nil }
    }
    let path = abs(shown) > 0.25 || native
      ? NativeScrolling.path(velocity: Double(velocity), lower: lower, upper: upper, viewportHeight: Double(layout.viewport.height))
      : NativeScrolling.systemPath(velocity: Double(velocity), lower: lower, upper: upper, viewportHeight: Double(layout.viewport.height))
    start(Flight(
      path: path, start: CACurrentMediaTime(), applied: 0, lower: lower, upper: upper,
      tau: abs(shown) > 0.25 || native ? nil : NativeScrolling.momentumShape(for: Double(velocity)).tau
    ))
  }

  func start(_ flight: Flight) {
    guard flight.path.duration > 0.02, let contentLayer = content.layer else {
      self.flight = nil
      content.layer?.removeAnimation(forKey: Self.flightKey)
      scroll(by: CGFloat(flight.path.end - flight.applied))
      rest()
      return
    }
    let path = flight.path
    // The model value moves to the path's end now; the animation adds what is still to travel, so the motion is the
    // render server's from here, whatever the main thread does.
    let animation = CAKeyframeAnimation(keyPath: "bounds.origin.y")
    animation.values = path.positions.map { NSNumber(value: path.end - $0) }
    animation.duration = path.duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    animation.beginTime = contentLayer.convertTime(flight.start, from: nil)
    animation.isRemovedOnCompletion = true
    animation.fillMode = .backwards
    animation.preferredFrameRateRange = flightFrameRate

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if flight.path.touchesLower, state.coverage.reachesNewest { flightBouncedOnNewest = true }
    self.flight = flight
    syncOrigin()
    contentLayer.add(animation, forKey: Self.flightKey)
    updatePins(timing: .none)
    headerFlightStart = nil
    updateFloatingHeader(timing: .none)
    bakeIndicator(flight)
    CATransaction.commit()
    showIndicator()
    showFloatingHeader()
    startTicking()
  }

  func rebakeIfEndsChanged(now: CFTimeInterval) {
    guard let flight else { return }
    let ends = state.layout.ends
    // A system-shaped fling stops only at real ends; a return (no shape) at any end, as it was baked.
    let realOnly = flight.tau != nil
    let upper = (realOnly && !state.coverage.reachesOldest ? nil : ends.upper).map { flight.applied + Double($0) }
    let lower = (realOnly && !state.coverage.reachesNewest ? nil : ends.lower).map { flight.applied + Double($0) }

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
    let path = flight.tau.map {
      NativeScrolling.systemPath(
        velocity: velocity, lower: lower.map { $0 - position }, upper: upper.map { $0 - position },
        viewportHeight: Double(state.viewport.height), continuing: $0
      )
    } ?? NativeScrolling.path(
      velocity: velocity, lower: lower.map { $0 - position }, upper: upper.map { $0 - position },
      viewportHeight: Double(state.viewport.height)
    )
    content.layer?.removeAnimation(forKey: Self.flightKey)
    start(Flight(
      path: path, start: now, applied: flight.applied - position, lower: lower.map { $0 - position },
      upper: upper.map { $0 - position }, tau: path.touchesUpper || path.touchesLower ? nil : flight.tau
    ))
  }

  /// A momentum event of the gesture that started the running fling: the fling's speed was our estimate from the last
  /// finger events (in real gestures 3–5× too far, from merged events and the fitted gain); the system's momentum is
  /// what NSScrollView follows. When its speed differs from the path's, the rest of the path is baked again from where
  /// the content is now at the system's speed, on the render server as before: smooth between events whatever the
  /// main thread does, and travelling as the system's momentum does.
  func steerFlight(with event: NSEvent) {
    // Once, at the first momentum event; a path into an end bounces on its own and is left alone.
    guard let flight, let steer = momentumSteer, !steer.started, !flight.path.touchesUpper, !flight.path.touchesLower
    else { return }
    momentumSteer = (event.timestamp, true)
    guard !event.momentumPhase.contains(.ended), !event.momentumPhase.contains(.cancelled) else { return }
    let dy = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.lineScroll)
    // The first event's delta is one 1/60 s of the system's motion.
    let system = dy * 60
    guard abs(system) >= NativeScrolling.minimumFlingVelocity, system.sign == flight.path.velocity(at: 0).sign else { return }
    let now = CACurrentMediaTime()
    let time = min(max(0, now - flight.start), flight.path.duration)
    let position = flight.path.position(at: time)
    let ends = state.layout.ends
    let upper = ends.upper.map { flight.applied + Double($0) }
    let lower = ends.lower.map { flight.applied + Double($0) }
    var path = NativeScrolling.systemPath(
      velocity: system, lower: lower.map { $0 - position }, upper: upper.map { $0 - position },
      viewportHeight: Double(state.viewport.height)
    )
    // From the fling as it moves now to the system's curve over a few frames, so the speed changes smoothly (a single
    // switch showed as a dip in the app's captures). A path into an end keeps the calculator's bounce as it is.
    if !path.touchesUpper, !path.touchesLower {
      path = Self.crossfade(from: flight.path, at: time, into: path, over: 0.08)
    }
    content.layer?.removeAnimation(forKey: Self.flightKey)
    start(Flight(
      path: path, start: now, applied: flight.applied - position, lower: lower.map { $0 - position },
      upper: upper.map { $0 - position },
      tau: path.touchesUpper || path.touchesLower ? nil : NativeScrolling.momentumShape(for: system).tau
    ))
  }

  /// Brake to rows (lab fork). How far the rows placed beyond the viewport reach in the direction of travel, against
  /// how far the flight goes before the next tick can place more (1.5 tick intervals, at least two frames): when the
  /// flight would cross them, the rest of the path is baked again from where the content is, at the speed that stays
  /// inside them (with a 10% margin), blended in over 50 ms so the speed eases down rather than steps.
  func brakeIfOutrunning(now: CFTimeInterval) {
    guard let flight, !flight.path.touchesUpper, !flight.path.touchesLower else { return }
    let layout = state.layout
    guard let first = layout.placements.first, let last = layout.placements.last else { return }
    let time = min(max(0, now - flight.start), flight.path.duration)
    let velocity = flight.path.velocity(at: time)
    guard abs(velocity) > 300 else { return }
    // Positive velocity: the content moves down, older rows come in at the top.
    let covered: Double
    if velocity > 0 {
      guard first.index > 0 else { return } // the oldest loaded row is placed: the path ends there
      covered = Double(0 - first.y)
    } else {
      guard last.index < state.rows.count - 1 else { return }
      covered = Double(last.maxY - layout.viewport.height)
    }
    let frame = 1.0 / Double(window?.screen?.maximumFramesPerSecond ?? 60)
    // Until the next tick has placed more: a frame when ticks keep time, longer when rows make them late.
    let horizon = max(frame, brakeHorizonScale * tickGap)
    let position = flight.path.position(at: time)
    // How fast placed rows advance in the direction of travel, per second of wall time, over the last ticks: the
    // speed the main thread can sustain.
    let frontier = flight.applied + (velocity > 0 ? covered : -covered)
    frontiers.append((now, frontier))
    frontiers.removeAll { now - $0.t > 0.12 }
    var sustainable = Double.infinity
    if let oldest = frontiers.first, now - oldest.t > 2.5 * frame {
      sustainable = abs(frontier - oldest.x) / (now - oldest.t)
    }
    let ahead = abs(flight.path.position(at: min(flight.path.duration, time + horizon)) - position)
    let outruns = ahead > max(0, covered)
    let outpaces = abs(velocity) > 1.15 * sustainable && covered < abs(velocity) * 0.1
    guard outruns || outpaces else { return }
    // The speed that crosses at most what is placed before the next tick, and no faster than rows are placed.
    let allowed = max(300, min(brakeMargin * max(0, covered) / horizon, outpaces ? sustainable : .infinity))
    guard allowed < abs(velocity) * 0.97 else { return }
    let speed = velocity.sign == .minus ? -allowed : allowed
    let ends = state.layout.ends
    let upper = (state.coverage.reachesOldest ? ends.upper : nil).map { flight.applied + Double($0) }
    let lower = (state.coverage.reachesNewest ? ends.lower : nil).map { flight.applied + Double($0) }
    var path = NativeScrolling.systemPath(
      velocity: speed, lower: lower.map { $0 - position }, upper: upper.map { $0 - position },
      viewportHeight: Double(state.viewport.height), continuing: flight.tau
    )
    if !path.touchesUpper, !path.touchesLower {
      path = Self.crossfade(from: flight.path, at: time, into: path, over: brakeBlend)
    }
    brakeTimes.append(now)
    content.layer?.removeAnimation(forKey: Self.flightKey)
    start(Flight(
      path: path, start: now, applied: flight.applied - position, lower: lower.map { $0 - position },
      upper: upper.map { $0 - position }, tau: path.touchesUpper || path.touchesLower ? nil : flight.tau
    ))
  }

  /// `next` (starting at 0), blended in over `duration` from the rest of `current` after `time` (rebased to 0): the
  /// speeds are blended and the positions integrated from them, so the speed moves monotonically from one curve to
  /// the other (blending positions instead dips below both).
  static func crossfade(from current: ScrollPath, at time: Double, into next: ScrollPath, over duration: Double) -> ScrollPath {
    let interval = next.interval
    var velocities = next.velocities
    for i in velocities.indices {
      let t = Double(i) * interval
      guard t < duration else { break }
      let f = t / duration
      let w = f * f * (3 - 2 * f)
      velocities[i] = (1 - w) * current.velocity(at: min(current.duration, time + t)) + w * velocities[i]
    }
    var positions = [Double](repeating: 0, count: velocities.count)
    for i in 1 ..< positions.count { positions[i] = positions[i - 1] + velocities[i - 1] * interval }
    return ScrollPath(
      interval: interval, positions: positions, velocities: velocities, touchesLower: next.touchesLower,
      touchesUpper: next.touchesUpper
    )
  }


  /// A touch landed: stop exactly where the content is on screen.
  func catchFlight() {
    momentumSteer = nil
    flightBouncedOnNewest = false
    if coast != nil {
      stopCoast()
      caughtFlight = true
    }
    guard let flight, let contentLayer = content.layer else { return }
    caughtFlight = true
    let now = CACurrentMediaTime()
    var position = flight.path.position(at: min(max(0, now - flight.start), flight.path.duration))
    if (contentLayer.animationKeys() ?? []).allSatisfy({ $0 == Self.flightKey || $0 == Self.followKey }),
       let presented = contentLayer.presentation()
    {
      // Nothing else moves the content, so what is presented is the path's position exactly.
      position = Double(origin) + flight.applied - Double(presented.bounds.origin.y)
    }
    self.flight = nil
    contentLayer.removeAnimation(forKey: Self.flightKey)
    endIndicatorFlight()
    updateTicking()
    scroll(by: CGFloat(position - flight.applied))
    syncOrigin()
    updatePins(timing: .none)
    headerFlightStart = nil
    updateFloatingHeader(timing: .none)
  }

  func endFlight(settle: Bool) {
    guard let flight else { return }
    self.flight = nil
    state.margins = .standard
    content.layer?.removeAnimation(forKey: Self.flightKey)
    endIndicatorFlight()
    updateTicking()
    if settle {
      scroll(by: CGFloat(flight.path.end - flight.applied))
      rest()
      // A bounce on the newest end whose end moved during it (the newest grew, rows arrived): on to the end, pinned.
      let bounced = flightBouncedOnNewest
      flightBouncedOnNewest = false
      if bounced, state.coverage.reachesNewest, let distance = state.layout.distanceToNewest, distance > 0.5,
         distance < state.viewport.height
      {
        apply(TimelineTransaction(scroll: .latest, timing: .standard))
      }
    } else {
      let position = flight.path.position(at: min(max(0, CACurrentMediaTime() - flight.start), flight.path.duration))
      scroll(by: CGFloat(position - flight.applied))
      syncOrigin()
    }
    updatePins(timing: .none)
    headerFlightStart = nil
    updateFloatingHeader(timing: .none)
  }

  /// Brings the content inside its limits and onto whole pixels, then reports the stop.
  func rest() {
    state.margins = .standard
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(0))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
    if let first = state.layout.placements.first {
      let scale = max(1, window?.backingScaleFactor ?? 2)
      let aligned = (first.y * scale).rounded() / scale
      if abs(aligned - first.y) > 0.001 {
        update.scroll = .by(aligned - first.y)
        perform(update, timing: .none, changed: [])
      }
    }
    syncOrigin()
    scheduleIndicatorHide()
    scheduleFloatingHeaderHide()
    onScrollEnded?()
  }
}
extension TimelineListView {
  /// Stops animated scrolls where they show: their tracks go (content, rows, pins, the floating header, the knob) and
  /// the content's model moves by what they still had to travel, so nothing on screen moves. A touch or a wheel does
  /// this, as it catches a fling.
  func stopScrollMotions() {
    jumpTarget = nil
    let now = CACurrentMediaTime()
    let running = scrollMotions.filter { $0.timing.remaining(at: now - $0.start) > 0.0005 }
    scrollMotions = []
    guard !running.isEmpty else { return }
    var layers: [CALayer] = [content.layer, indicatorView.layer, floatingHeader?.view.layer].compactMap { $0 }
    for slot in Array(slots.values) + lingering.values.map(\.slot) {
      if let layer = slot.view.layer { layers.append(layer) }
      if let layer = slot.pin?.view.layer { layers.append(layer) }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in layers {
      for key in layer.animationKeys() ?? [] where running.contains(where: { $0.owns(key) }) {
        layer.removeAnimation(forKey: key)
      }
    }
    CATransaction.commit()
    // The model no longer follows them: what they still had to travel moves the state instead.
    contentTracks.removeAll { track in running.contains { $0.tracks.contains(track.serial) } }
    let remaining = running.reduce(CGFloat(0)) { $0 + $1.travel * CGFloat($1.timing.remaining(at: now - $1.start)) }
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(remaining))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
  }
}
extension TimelineListView {
  /// Brings a placed row fully into view, as little as it takes: its top to the usable top if it is above or taller
  /// than the usable area, else its bottom to the usable bottom.
  func reveal(_ slot: Slot) {
    guard let id = slots.first(where: { $0.value === slot })?.key, let placement = state.layout.placement(for: id) else { return }
    let viewport = state.layout.viewport
    let alignment: TimelineAlignment
    if placement.y < viewport.usableTop || placement.height > viewport.usableHeight {
      alignment = .top(0)
    } else if placement.maxY > viewport.usableBottom {
      alignment = .bottom(0)
    } else {
      return
    }
    apply(TimelineTransaction(scroll: .to(id, alignment), timing: .standard))
  }
}
#endif
