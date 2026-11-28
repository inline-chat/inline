#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

// Input: the trackpad and Magic Mouse (phased scroll events), mouse wheels, the keyboard, clicks during a fling, and
// drags that leave the list (autoscroll for a selection).

extension TimelineListView {
  // MARK: - Pointer

  /// During a fling the content's model follows what is shown a frame at a time; a point is looked up where the
  /// content is shown, exactly. A click stops the fling first (a trackpad touch already has, at `mayBegin`); then
  /// model and screen agree.
  func timeline_hitTest(_ point: NSPoint) -> NSView? {
    if let superview, indicatorTakes(convert(point, from: superview)) { return self }
    if flight != nil || coast != nil, let type = NSApp.currentEvent?.type,
       type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    {
      catchFlight()
      caughtFlight = false
      rest()
    }
    guard let superview else { return super.hitTest(point) }
    let local = convert(point, from: superview)
    guard flight != nil else {
      let hit = super.hitTest(point)
      // Over the rows (the floating header, a host's overlay) first; then pins, which a lift can carry outside their
      // own row, where AppKit's hit testing (a view's frame within its superview) never finds them.
      if let hit, hit !== content, !hit.isDescendant(of: content) { return hit }
      return pinHit(at: local) ?? hit
    }
    guard bounds.contains(local), !isHidden else { return nil }
    // What lies over the rows (the floating header, a host's overlay) first, where it is. The knob was handled.
    for view in subviews.reversed() where view !== content && view !== indicatorView {
      if let hit = view.hitTest(local) { return hit }
    }
    if let pin = pinHit(at: local) { return pin }
    // The rows where they show now.
    let presented = NSPoint(x: local.x - content.frame.minX, y: local.y - content.frame.minY + presentedOrigin)
    for view in content.subviews.reversed() where !view.isHidden {
      if let hit = view.hitTest(presented) { return hit }
    }
    return content
  }

  /// A pin (a sticky avatar) where it shows at `local`, by its own hit test.
  func pinHit(at local: NSPoint) -> NSView? {
    for slot in slots.values {
      guard let pin = slot.pin, !pin.view.isHiddenOrHasHiddenAncestor, let pinSuperview = pin.view.superview,
            let shown = presentedFrame(of: pin.view), shown.contains(local) else { continue }
      if let hit = pin.view.hitTest(NSPoint(x: pin.view.frame.midX, y: pin.view.frame.midY)), hit.isDescendant(of: pinSuperview) {
        return hit
      }
    }
    return nil
  }

  /// A drag that leaves the list's usable area (selecting text across messages) scrolls it, faster the further the
  /// pointer is outside, as a clip view's autoscroll does. Returns whether the list moved.
  @discardableResult
  func timeline_autoscroll(with event: NSEvent) -> Bool {
    let point = convert(event.locationInWindow, from: nil)
    let viewport = state.viewport
    var delta: CGFloat = 0
    if point.y < viewport.usableTop {
      delta = viewport.usableTop - point.y
    } else if point.y > viewport.usableBottom {
      delta = viewport.usableBottom - point.y
    }
    guard abs(delta) > 0.5 else { return false }
    let limit = max(10, viewport.usableHeight / 4)
    delta = max(-limit, min(limit, delta))
    let before = state.layout
    catchFlight()
    caughtFlight = false
    var update = TimelineUpdate<ID>(viewport: self.viewport(), scroll: .by(delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
    scheduleRest()
    return state.layout.placements.first.map { first in
      before.placement(for: first.id).map { abs($0.y - first.y) > 0.01 } ?? true
    } ?? false
  }

  // MARK: - Keyboard

  func timeline_keyDown(with event: NSEvent) {
    interpretKeyEvents([event])
  }

  /// Keyboard scrolling, as a scroll view's: a page is the usable height less a line of overlap.
  func keyScroll(by delta: CGFloat) {
    catchFlight()
    caughtFlight = false
    showIndicator()
    showFloatingHeader()
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: Self.keyScrollTiming, changed: [])
    scheduleIndicatorHide()
    scheduleFloatingHeaderHide()
    onScrollEnded?()
  }

  /// NSScrollView animates a keyboard scroll over about a fifth of a second, easing out.
  static var keyScrollTiming: TimelineTiming { .curve(duration: 0.2, c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1) }

  var page: CGFloat { max(40, state.viewport.usableHeight - 40) }

  func timeline_scrollPageUp(_ sender: Any?) { keyScroll(by: page) }
  func timeline_scrollPageDown(_ sender: Any?) { keyScroll(by: -page) }
  func timeline_pageUp(_ sender: Any?) { keyScroll(by: page) }
  func timeline_pageDown(_ sender: Any?) { keyScroll(by: -page) }
  func timeline_scrollLineUp(_ sender: Any?) { keyScroll(by: Self.lineScroll * 4) }
  func timeline_scrollLineDown(_ sender: Any?) { keyScroll(by: -Self.lineScroll * 4) }
  func timeline_moveUp(_ sender: Any?) { keyScroll(by: Self.lineScroll * 4) }
  func timeline_moveDown(_ sender: Any?) { keyScroll(by: -Self.lineScroll * 4) }

  func timeline_scrollToEndOfDocument(_ sender: Any?) {
    catchFlight()
    caughtFlight = false
    apply(TimelineTransaction(scroll: .latest, timing: .standard, towards: .newer))
  }

  func timeline_scrollToBeginningOfDocument(_ sender: Any?) {
    guard let first = state.rows.first else { return }
    catchFlight()
    caughtFlight = false
    apply(TimelineTransaction(scroll: .to(first, .top(0)), timing: .standard, towards: .older))
  }

  func timeline_moveToBeginningOfDocument(_ sender: Any?) { scrollToBeginningOfDocument(sender) }
  func timeline_moveToEndOfDocument(_ sender: Any?) { scrollToEndOfDocument(sender) }

  // MARK: - Scroll input

  func timeline_scrollWheel(with event: NSEvent) {
    // Momentum events are the system's continuation of a gesture. NSScrollView ignores their deltas and runs its own
    // deceleration from the release velocity; so does this list (the fling started at `.ended`). A horizontal
    // gesture's momentum goes where the gesture went.
    if !event.momentumPhase.isEmpty {
      recordMomentum(event)
      let ends = event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
      if ends, momentumInterrupted(), flight != nil, !gestureIsHorizontal, !horizontalTaken {
        // A finger on the trackpad (a touch or a tap, which sends no `mayBegin`) ends the system's momentum at once,
        // its deltas still large; NSScrollView stops there (Mo's recorded gestures: 9 of 13 flings ended so, 0.18–0.43 s
        // after the lift). A stream that runs out ends slow, and the fling goes on to its own end.
        momentumSpeed = 0
        catchFlight()
        caughtFlight = false
        rest()
        return
      }
      if !ends {
        let dy = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.lineScroll)
        // The system's momentum events come at 60 Hz.
        momentumSpeed = abs(dy) * 60
      }
      if gestureIsHorizontal || horizontalTaken {
        routeHorizontal(event)
      } else if coast != nil {
        followMomentum(event)
      } else if flight != nil {
        steerFlight(with: event)
      }
      return
    }
    let phase = event.phase
    let dx = event.scrollingDeltaX
    let dy = event.scrollingDeltaY
    if phase.contains(.mayBegin) {
      stopScrollMotions()
      catchFlight()
      return
    }
    if phase.contains(.began) {
      stopScrollMotions()
      momentumSpeed = 0
      horizontalTaken = false
      gestureIsHorizontal = abs(dx) > abs(dy) * 1.5
      if gestureIsHorizontal {
        routeHorizontal(event)
        return
      }
      catchFlight()
      caughtFlight = false
      beginTracking()
      finishGestureRecord()
      if onGestureRecord != nil { gestureRecord = TimelineGestureRecord(began: event.timestamp) }
      track(dy, at: event.timestamp)
      return
    }
    if phase.contains(.changed) {
      if gestureIsHorizontal {
        routeHorizontal(event)
        return
      }
      if !isTracking { beginTracking() }
      track(dy, at: event.timestamp)
      return
    }
    if phase.contains(.ended) || phase.contains(.cancelled) {
      if gestureIsHorizontal {
        routeHorizontal(event)
        gestureIsHorizontal = false
        return
      }
      if isTracking {
        isTracking = false
        // NSScrollView's fling: AppKit's calculator from 0.9 × the fingers' speed (`FingerVelocity`), within 2–8% of
        // NSScrollView's travel on recorded gestures. The other shape follows the system's momentum stream (twice
        // the travel), kept for comparison (`TimelineFling.followsNSScrollView`).
        let followsNSScrollView = TimelineFling.followsNSScrollView
        let released = !phase.contains(.ended) ? 0
          : followsNSScrollView ? 0.9 * finger.velocity(releasedAt: event.timestamp)
          : velocity.velocity(releasedAt: event.timestamp)
        let gain = followsNSScrollView ? 1 : NativeScrolling.releaseGain(for: released)
        if var record = gestureRecord {
          record.released = event.timestamp
          record.trackedDuration = event.timestamp - record.began
          record.releaseVelocity = released
          record.gain = gain
          record.lastTracked = record.tracked.map { [event.timestamp - $0.time, $0.delta] }
          gestureRecord = record
        }
        if coastsOnMainThread {
          beginCoast(velocity: CGFloat(released * gain))
        } else {
          release(velocity: CGFloat(released * gain))
          // The first of the system's momentum events re-bakes it once at the system's speed (the momentum shape
          // only; NSScrollView ignores the events' deltas).
          momentumSteer = !followsNSScrollView && Self.steersByMomentum && flight != nil ? (event.timestamp, false) : nil
        }
        if var record = gestureRecord, let path = flight?.path ?? coast?.path {
          record.flingTravel = path.end
          record.flingDuration = path.duration
          gestureRecord = record
        }
      } else if caughtFlight {
        // A touch that stopped a fling lifted without moving.
        caughtFlight = false
        release(velocity: 0)
      }
      return
    }
    // No phase: a mouse wheel notch, or a device that sends plain deltas. A wheel turned sideways (or with shift)
    // is not the list's.
    if abs(dx) > abs(dy) {
      super.scrollWheel(with: event)
      return
    }
    let delta = event.hasPreciseScrollingDeltas ? dy : dy * Self.lineScroll
    guard abs(delta) > 0.001 else { return }
    stopScrollMotions()
    catchFlight()
    caughtFlight = false
    onScrollBegan?()
    showIndicator()
    showFloatingHeader()
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    perform(update, timing: .none, changed: [])
    scheduleRest()
  }

  /// A horizontal gesture goes to the host with the row it started on (swipe to reply), else up the chain.
  func routeHorizontal(_ event: NSEvent) {
    if event.phase.contains(.began) {
      let point = convert(event.locationInWindow, from: nil)
      horizontalTaken = onHorizontalScroll?(event, row(atPresented: point)) ?? false
      if !horizontalTaken { super.scrollWheel(with: event) }
      return
    }
    // Taken: the rest of the gesture and its momentum go to the host, until the next gesture begins.
    if horizontalTaken {
      _ = onHorizontalScroll?(event, nil)
    } else {
      super.scrollWheel(with: event)
    }
  }

  /// A wheel notch moves this far per line, as NSScrollView's `verticalLineScroll`.
  static var lineScroll: CGFloat { 10 }

  func beginTracking() {
    jumpTarget = nil
    flightBouncedOnNewest = false
    restWork?.cancel()
    restWork = nil
    isTracking = true
    velocity.reset()
    finger.reset()
    let shown = -state.layout.restShift
    pulled = shown / NativeScrolling.rubberBandShare
    showIndicator()
    showFloatingHeader()
    onScrollBegan?()
  }

  func track(_ delta: CGFloat, at time: TimeInterval) {
    velocity.add(delta, at: time)
    finger.add(Double(delta), at: time)
    if var record = gestureRecord {
      record.trackedTravel += Double(delta)
      record.trackedEvents += 1
      record.tracked.append((time, Double(delta)))
      if record.tracked.count > 64 { record.tracked.removeFirst(record.tracked.count - 64) }
      gestureRecord = record
    }
    drag(by: delta)
  }

  /// Whether the momentum stream ending now was cut short: its latest event still moved faster than a stream running
  /// out does (its last events are a few points a frame).
  func momentumInterrupted() -> Bool {
    defer { momentumSpeed = 0 }
    return momentumSpeed > Self.interruptedMomentumSpeed
  }

  /// 4 pt a frame at 60 Hz.
  static var interruptedMomentumSpeed: Double { 240 }

  /// The system's momentum events for the gesture just released, kept beside what the list played.
  func recordMomentum(_ event: NSEvent) {
    guard var record = gestureRecord, record.released > 0 else { return }
    let dy = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.lineScroll)
    if record.momentumEvents == 0 {
      record.firstMomentum = event.timestamp
      record.momentumFirstDelay = event.timestamp - record.released
      record.momentumFirstDelta = dy
    }
    record.momentumEvents += 1
    record.momentumTravel += dy
    record.momentumDuration = event.timestamp - record.firstMomentum
    if record.momentumSamples.count < 40 { record.momentumSamples.append([event.timestamp - record.firstMomentum, dy]) }
    gestureRecord = record
    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { finishGestureRecord() }
  }

  func finishGestureRecord() {
    guard let record = gestureRecord, record.released > 0 else { return }
    gestureRecord = nil
    onGestureRecord?(record)
  }

  /// Moves the content with the trackpad. Past an end the travel is rubber banded.
  func drag(by delta: CGFloat) {
    guard delta != 0 else { return }
    let layout = state.layout
    let shown = -layout.restShift
    let limit = max(1, layout.viewport.usableHeight) / 2
    // The end moved under the fingers (a page landed above, rows left): what is past it now is what shows, or the
    // next move would leap by the old pull (iOS fixed the same, re-syncing from the origin).
    if abs(max(-limit, min(limit, pulled * NativeScrolling.rubberBandShare)) - shown) > 0.5 {
      pulled = shown / NativeScrolling.rubberBandShare
    }
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
    let nowShown = max(-limit, min(limit, pulled * NativeScrolling.rubberBandShare))
    scroll(by: moved + (nowShown - shown))
  }

  func scroll(by delta: CGFloat) {
    guard abs(delta) > 0.0001 else { return }
    var update = TimelineUpdate<ID>(viewport: viewport(), scroll: .by(delta))
    update.followsBottomInset = false
    update.pinsWhenAtBottom = false
    update.allowsOverscroll = true
    perform(update, timing: .none, changed: [])
  }

  /// A wheel notch ends a scroll once no notch has come for a moment.
  func scheduleRest() {
    restWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.restWork = nil
        guard !self.isTracking, self.flight == nil, self.coast == nil else { return }
        self.rest()
      }
    }
    restWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
  }
}
#endif
