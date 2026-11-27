#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

// Flings: the whole path is baked at release from AppKit's own momentum calculator and handed to the render server;
// the display link only realises rows along it. Rows that load during the fling can move an end: the rest of the
// path is baked again on the same clock.

extension TimelineListView {
  func release(velocity: CGFloat) {
    pulled = 0
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
    let isFling = abs(shown) <= 0.25
    let appKitFling = isFling && TimelineFling.followsNSScrollView
    let path = !isFling || appKitFling
      ? NativeScrolling.path(velocity: Double(velocity), lower: lower, upper: upper, viewportHeight: Double(layout.viewport.height))
      : NativeScrolling.systemPath(velocity: Double(velocity), lower: lower, upper: upper, viewportHeight: Double(layout.viewport.height))
    start(Flight(
      path: path, start: CACurrentMediaTime(), applied: 0, lower: lower, upper: upper,
      tau: isFling && !appKitFling ? NativeScrolling.momentumShape(for: Double(velocity)).tau : nil,
      appKitFling: appKitFling && !path.touchesUpper && !path.touchesLower
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
    let realOnly = flight.tau != nil || flight.appKitFling
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
      upper: upper.map { $0 - position }, tau: path.touchesUpper || path.touchesLower ? nil : flight.tau,
      appKitFling: flight.appKitFling && !path.touchesUpper && !path.touchesLower
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


  /// When a change made now shows on screen: the display's next refresh after now (the display link's target). On
  /// screen, a catch stopped there showed no step back in 12 of 12 catches (one more refresh of the fling's own motion,
  /// then still); a refresh later than that went on by two.
  func catchTime() -> CFTimeInterval {
    let now = CACurrentMediaTime()
    let rate = Double(window?.screen?.maximumFramesPerSecond ?? 60)
    var interval = 1.0 / max(30, rate)
    var next = now
    if let link, link.targetTimestamp > 0 {
      let step = link.targetTimestamp - link.timestamp
      if step > 0.002, step < 0.05 { interval = step }
      next = link.targetTimestamp
      while next < now { next += interval }
    }
    return next
  }

  /// A touch landed: stop where the content shows when the stop reaches the screen.
  /// The render server plays the fling on until this commit lands, a frame or two after it is made: a stop where the
  /// content was at the touch stepped back by that much motion (2–27 pt on screen at 1,600–3,300 pt/s, 60 Hz,
  /// TimelineScrollLab `--compare catch`). Rows, pins and the floating header all stop at the same place.
  func catchFlight() {
    momentumSteer = nil
    flightBouncedOnNewest = false
    if coast != nil {
      stopCoast()
      caughtFlight = true
    }
    guard let flight, let contentLayer = content.layer else { return }
    caughtFlight = true
    let position = flight.path.position(at: min(max(0, catchTime() - flight.start), flight.path.duration))
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
      // The way it last moved (a bounce's return goes against its start).
      let path = flight.path
      let tail = path.end - path.position(at: max(0, path.duration - 0.05))
      rest(moving: CGFloat(tail))
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
  /// `moving`: the direction the content last moved in (positive: down, towards older), so the snap to whole pixels
  /// goes on with it, never back: on a 1× display the nearest pixel can be half a point behind, a step back at the end of
  /// a slow tail (−33 pt/s at +1.1 s after a fling in `stress.fling-into-loading-edge`).
  func rest(moving: CGFloat = 0) {
    state.margins = .standard
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(0))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
    if let first = state.layout.placements.first {
      let scale = max(1, window?.backingScaleFactor ?? 2)
      // At an end the end is the rest: on with the motion would carry the content past it (1 pt past the oldest end) or
      // short of it (1 pt short of the newest, which then glided on: `fling.bounce-oldest`, `input.rubber-band-newest`).
      let layout = state.layout
      let atEnd = (layout.distanceToOldest ?? .infinity) < 1.5 || (layout.distanceToNewest ?? .infinity) < 1.5
      let rule: FloatingPointRoundingRule = atEnd ? .toNearestOrAwayFromZero
        : moving > 0.001 ? .up : moving < -0.001 ? .down : .toNearestOrAwayFromZero
      let aligned = (first.y * scale).rounded(rule) / scale
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
    // Where they show when the stop does (`catchTime`), as a fling is caught.
    let now = catchTime()
    let running = scrollMotions.filter { $0.timing.remaining(at: now - $0.start) > 0.0005 }
    scrollMotions = []
    guard !running.isEmpty else { return }
    // The pins' lifts no longer follow them either (re-baked on the next pass).
    for slot in slots.values { slot.pinChanges.removeAll { change in running.contains { $0.start == change.start } } }
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
