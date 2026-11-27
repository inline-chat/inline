#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

// Coasting: the motion after the fingers lift, driven on the main thread one frame at a time, as NSScrollView and
// Telegram's lists move. Each frame realises and draws the rows it brings in before the frame shows them, so the
// screen never shows a row that is not ready: a slow frame shows late, never blank.
//
// On a real trackpad the system's momentum events drive it: NSScrollView follows them, so their travel is the native
// feel. They come at 60 Hz (merged into fewer, larger ones when the main thread is busy) and decay by about 5% each
// (measured from real gestures: a time constant near 0.3 s). So each event resets where the system is and how fast,
// and every display frame (120 Hz on ProMotion) shows that motion decaying until the next event: smooth between
// events, the system's travel at each. Without momentum events (synthetic input) the coast falls back to AppKit's own
// deceleration from the release velocity. Into an end, the coast hands over to the bounce.

extension TimelineListView {
  struct Coast {
    var velocity: Double
    var released: CFTimeInterval
    /// The calculator's path, until momentum events take over.
    var path: ScrollPath?
    var applied: Double = 0
    /// The ends the path was made for, as path displacements.
    var lower: Double?
    var upper: Double?
    var followsEvents = false
    /// The system's momentum as its events give it: their travel so far, the latest one's time, the speed then.
    var systemTravel: Double = 0
    var eventTime: CFTimeInterval = 0
    var eventVelocity: Double = 0
    /// Travel shown since momentum events took over (the calculator's frames before the first included).
    var shownTravel: Double = 0
    /// The last frame's step and time, so the next step changes speed smoothly.
    var lastStep: Double = 0
    var lastFrame: CFTimeInterval = 0
    var lastFrameInterval: CFTimeInterval = 1.0 / 120
  }

  /// The system's momentum decay: about 5% per 1/60 s in real gestures.
  static var momentumDecay: Double { 0.3 }
  /// Momentum events come at 60 Hz; the first one's delta stands for one such interval.
  static var momentumInterval: Double { 1.0 / 60 }

  func beginCoast(velocity: CGFloat) {
    pulled = 0
    let shown = -state.layout.restShift
    // Past an end, or too slow to coast: the release returns or rests as before.
    guard abs(shown) <= 0.25, abs(Double(velocity)) >= NativeScrolling.minimumFlingVelocity else {
      release(velocity: velocity)
      return
    }
    let now = CACurrentMediaTime()
    var coast = Coast(velocity: Double(velocity), released: now)
    let layout = state.layout
    coast.lower = layout.distanceToNewest.map { -Double($0) }
    coast.upper = layout.distanceToOldest.map { Double($0) }
    coast.path = NativeScrolling.path(
      velocity: Double(velocity), lower: coast.lower, upper: coast.upper, viewportHeight: Double(layout.viewport.height)
    )
    self.coast = coast
    showIndicator()
    showFloatingHeader()
    startTicking()
    // The display link's first callback comes a frame later: step now, for the next frame, so the frame after the
    // lift already moves (a render-server fling started in the lift's own commit).
    let interval = window?.screen?.minimumRefreshInterval ?? (1.0 / 60)
    tickCoast(at: now + interval)
  }

  /// A page that landed (or rows that left) moved an end the path was slowing for: the rest of the path again, from
  /// where and how fast the content is now, as a render-server fling re-bakes.
  func repathIfEndsChanged(_ coast: inout Coast, at time: CFTimeInterval) {
    guard let path = coast.path else { return }
    let ends = state.layout.ends
    let upper = ends.upper.map { coast.applied + Double($0) }
    let lower = ends.lower.map { coast.applied + Double($0) }
    func differs(_ a: Double?, _ b: Double?) -> Bool {
      switch (a, b) {
        case (nil, nil): false
        case let (a?, b?): abs(a - b) > 0.5
        default: true
      }
    }
    let end = path.end
    let upperMatters = differs(upper, coast.upper) && (path.touchesUpper || (upper.map { $0 < end - 0.5 } ?? false))
    let lowerMatters = differs(lower, coast.lower) && (path.touchesLower || (lower.map { $0 > end + 0.5 } ?? false))
    guard upperMatters || lowerMatters else { return }
    let t = min(max(0, time - coast.released), path.duration)
    let position = path.position(at: t)
    coast.path = NativeScrolling.path(
      velocity: path.velocity(at: t), lower: lower.map { $0 - position }, upper: upper.map { $0 - position },
      viewportHeight: Double(state.viewport.height)
    )
    coast.released = time
    coast.applied -= position
    coast.lower = lower.map { $0 - position }
    coast.upper = upper.map { $0 - position }
  }

  /// A momentum event of the gesture just released: where the system's motion is and how fast. Frames show it.
  func followMomentum(_ event: NSEvent) {
    guard var coast else { return }
    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
      // The system stopped: show the rest of its travel, then rest.
      let delta = coast.systemTravel - coast.shownTravel
      coast.shownTravel = coast.systemTravel
      self.coast = coast
      if abs(delta) > 0.01, delta.sign == coast.eventVelocity.sign { scroll(by: CGFloat(delta)) }
      endCoast()
      return
    }
    let dy = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Self.lineScroll)
    let time = event.timestamp
    if !coast.followsEvents {
      // The calculator's frames since the lift stand for the same motion as this first event.
      coast.followsEvents = true
      coast.path = nil
      coast.shownTravel = coast.applied
      coast.systemTravel = 0
      coast.eventVelocity = dy / Self.momentumInterval
    } else {
      // Events come every 1/60 s; their time stamps jitter by a millisecond or more, which would scale the speed up
      // and down. The nominal interval, unless events were merged (a busy main thread): then the real gap.
      let gap = time - coast.eventTime
      let interval = gap > Self.momentumInterval * 1.6 ? min(gap, 0.25) : Self.momentumInterval
      coast.eventVelocity = dy / interval
    }
    coast.systemTravel += dy
    coast.eventTime = time
    self.coast = coast
  }

  /// One frame of a coast: the system's momentum decaying from its latest event, or the calculator's path.
  func tickCoast(at time: CFTimeInterval) {
    guard var coast else { return }
    if coast.followsEvents {
      let tau = Self.momentumDecay
      let ahead = max(0, time - coast.eventTime)
      let decay = exp(-ahead / tau)
      let target = coast.systemTravel + coast.eventVelocity * tau * (1 - decay)
      // This frame's step: towards the system's curve, its change from the last step limited, so an event that moves
      // the curve a little is absorbed over the next frames rather than shown as a jolt. Never backwards.
      var step = target - coast.shownTravel
      let frame = coast.lastFrame > 0 ? max(time - coast.lastFrame, 1.0 / 240) : Self.momentumInterval / 2
      if coast.lastStep != 0 {
        let expected = coast.lastStep * exp(-frame / tau) * frame / max(1.0 / 240, coast.lastFrameInterval)
        let slack = max(abs(expected) * 0.15, 0.5)
        step = min(max(step, expected - slack), expected + slack)
      }
      if step.sign != coast.eventVelocity.sign { step = 0 }
      coast.shownTravel += step
      coast.lastFrameInterval = frame
      coast.lastStep = step
      coast.lastFrame = time
      self.coast = coast
      if abs(step) > 0.001 { scroll(by: CGFloat(step)) }
      noteCoastFrame(step: step, events: true)
      // Into an end: the bounce takes it, from how fast it is going.
      if abs(state.layout.restShift) > 0.25 {
        stopCoast()
        release(velocity: CGFloat(coast.eventVelocity * decay))
        return
      }
      // The stream went quiet, its curve has nothing left to travel, and what it travelled is shown.
      if abs(coast.eventVelocity) * tau * decay < 0.5, abs(target - coast.shownTravel) < 0.5 { endCoast() }
      return
    }
    repathIfEndsChanged(&coast, at: time)
    guard let path = coast.path else { return endCoast() }
    let t = min(max(0, time - coast.released), path.duration)
    let position = path.position(at: t)
    let delta = position - coast.applied
    coast.applied = position
    self.coast = coast
    scroll(by: CGFloat(delta))
    noteCoastFrame(step: delta, events: false)
    if t >= path.duration { endCoast() }
  }

  /// Diagnostics: one coast frame into the gesture's record.
  func noteCoastFrame(step: Double, events: Bool) {
    guard var record = gestureRecord, record.coastFrames.count < 400 else { return }
    let now = CACurrentMediaTime()
    let since = record.lastCoastTick > 0 ? now - record.lastCoastTick : 0
    record.lastCoastTick = now
    record.coastFrames.append([now - record.released, step, since, lastPerformDuration * 1000, events ? 1 : 0])
    gestureRecord = record
  }

  /// The coast ran out: back inside an end it went past, or at rest.
  func endCoast() {
    guard coast != nil else { return }
    coast = nil
    updateTicking()
    if abs(state.layout.restShift) > 0.25 {
      release(velocity: 0)
    } else {
      rest()
    }
  }

  /// A touch, a click or a change took over: the content stays where it shows (the model is there already).
  func stopCoast() {
    guard coast != nil else { return }
    coast = nil
    updateTicking()
  }
}
#endif
