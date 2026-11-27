#if os(macOS)
import AppKit
import QuartzCore
import TimelineCore

// Sticky things: a sender's avatar that stays beside its group (pins, inside rows) and the section title that floats
// at the top (the floating header, over the rows). Both are functions of where the content is (`TimelineCore`'s
// `TimelinePinGeometry` and `TimelineFloatingHeader`), so they are baked into the same render-server path as a fling
// and get the same tracks as an animated change.

extension TimelineListView {
  // MARK: - Pins

  /// The centre on screen (in this view) of each pin shown now, by the span it belongs to, as last applied: the
  /// host's rows already describe the change being made (the old last message no longer has the avatar).
  func shownPins() -> [ID: CGFloat] {
    var shown: [ID: CGFloat] = [:]
    for slot in slots.values {
      guard let pinned = slot.pin, !pinned.view.isHidden, let frame = presentedFrame(of: pinned.view) else { continue }
      guard frame.maxY > 0, frame.minY < bounds.height else { continue }
      shown[pinned.spanStart] = frame.midY
    }
    return shown
  }

  /// Brings every placed row's pin to the lift the current state asks for. With an animated timing a pin whose lift
  /// changed moves there on that timing from where it is on screen; while a flight runs, each pin also gets the
  /// flight's path, so it moves on the render server with the content.
  ///
  /// The lift is the pin view's frame: AppKit owns the layer geometry of layer-backed views and resets a layer's
  /// transform whenever it rebuilds the layer tree (a row just made or shown again), so a transform set in the same
  /// pass is lost. A frame also keeps hit testing and accessibility where the avatar is. Animations stay additive on
  /// `position.y`, which AppKit leaves alone.
  func updatePins(timing: TimelineTiming) {
    let layout = state.layout
    guard let first = layout.placements.first else { return }
    let edge = layout.viewport.usableBottom
    // The layer's model scroll position is the end of a running flight; the state is where the flight has been
    // realised to.
    let ahead = flight?.ahead ?? 0
    let now = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for placement in layout.placements {
      guard let slot = slots[placement.id] else { continue }
      let pin = rows.pin(placement.id, slot.row)
      if let old = slot.pin, old.view !== pin?.view { unpin(slot) }
      guard let pin, let layer = pin.view.layer else { continue }
      // A span starting above the placed rows starts above the screen too: it does not limit.
      var spanTop = -CGFloat.infinity
      var spanStartID: ID?
      if let index = state.index[pin.spanStart], index >= first.index, index - first.index < layout.placements.count {
        let start = layout.placements[index - first.index]
        if let startSlot = slots[start.id] {
          spanTop = start.y + rows.spanTop(start.id, startSlot.row) + ahead
          spanStartID = start.id
        }
      }
      let next = PinState(
        view: pin.view,
        spanStart: pin.spanStart,
        rest: CGRect(x: 0, y: pin.bottom - pin.height, width: 0, height: pin.height),
        geometry: TimelinePinGeometry(
          bottom: placement.y + pin.bottom + ahead, height: pin.height, spanTop: spanTop, edge: edge
        ),
        flightStart: flight?.start
      )
      // Every pass: the host may have laid the view out at rest since (an update of the row).
      slot.row.layoutSubtreeIfNeeded()
      place(pin.view, in: slot.row, rest: next.rest, lift: next.geometry.lift)
      if let old = slot.pin, old.matches(next) { continue }
      // Where the pin is on screen now, before this change.
      let shown = slot.pin.map { presentedLift($0, now: now) }
      if slot.pin == nil { slot.view.layer?.zPosition = 1 }
      let sign = downward(in: pin.view)
      var handedOver = false
      if slot.pin == nil, let arrival = avatarArrivals.removeValue(forKey: placement.id) {
        handedOver = true
        // The row starts `offset` from its place on screen; the pin starts where the old one is. Its place is read
        // from the model (the frame just set): the tracks just added have not reached the screen.
        let restMid = pin.view.convert(pin.view.bounds, to: self).midY + followOffset
        if let track = timing.track(keyPath: "position.y", from: (arrival.from - restMid - arrival.offset) * sign) {
          pinTrackCount &+= 1
          layer.add(track, forKey: "\(Self.pinKey).\(pinTrackCount)")
        }
      }
      slot.pin = next
      if let flight {
        bake(layer, next, flight: flight, sign: sign)
      } else {
        layer.removeAnimation(forKey: Self.pinKey)
      }
      // An animated change moving the row, its span's top or the edge: the lift follows them along the change's own
      // timing (every part of the change moves on it), baked like a flight, not a spring of its own between the old
      // and new lifts, which a clamp makes far from where the row is (a jump: hundreds of points).
      if timing.isAnimated, flight == nil, !handedOver, let rowStart = rowStarts[placement.id],
         bakeAlong(timing, layer: layer, pin: next, rowStart: rowStart,
                   spanStart: spanStartID.flatMap { rowStarts[$0] }, sign: sign)
      {
        continue
      }
      // Tracks stack: each is keyed apart, so the next change does not cut the last one short. A lift up is a move
      // up on screen.
      if let shown {
        let delta = shown - presentedLift(next, now: now)
        if abs(delta) > 0.01, let track = timing.track(keyPath: "position.y", from: -delta * sign) {
          pinTrackCount &+= 1
          layer.add(track, forKey: "\(Self.pinKey).\(pinTrackCount)")
        }
      }
    }
  }

  /// Bakes the pin's lift along an animated change: at each moment the row, its span's top and the edge are
  /// `start × q` from where they settle (q: how much of the motion remains), so the lift is the pin geometry with those
  /// offsets. False when nothing it depends on moves.
  func bakeAlong(
    _ timing: TimelineTiming, layer: CALayer, pin: PinState, rowStart: CGFloat, spanStart: CGFloat?, sign: CGFloat
  ) -> Bool {
    let geometry = pin.geometry
    let overhangSlope = rowStart - edgeStart
    let maxLiftSlope = spanStart.map { rowStart - $0 } ?? 0
    guard abs(overhangSlope) > 0.01 || abs(maxLiftSlope) > 0.01 else { return false }
    func lift(_ q: Double) -> CGFloat {
      let overhang = geometry.overhang + overhangSlope * CGFloat(q)
      let maxLift = max(0, geometry.maxLift + maxLiftSlope * CGFloat(q))
      return max(0, min(overhang, maxLift))
    }
    var kinks: [Double] = []
    if overhangSlope != 0 { kinks.append(Double(-geometry.overhang / overhangSlope)) }
    if maxLiftSlope != 0 { kinks.append(Double(-geometry.maxLift / maxLiftSlope)) }
    if overhangSlope != maxLiftSlope {
      kinks.append(Double((geometry.maxLift - geometry.overhang) / (overhangSlope - maxLiftSlope)))
    }
    kinks = kinks.filter { $0.isFinite && $0 > 0 && $0 < 1 }
    // The lift is piecewise linear in q: its ends and corners say how far it moves. Most pins do not move at all
    // (a group well above the edge): nothing to bake.
    let end = lift(0)
    let amplitude = ([1] + kinks).map { abs(lift($0) - end) }.max() ?? 0
    guard amplitude > 0.01 else { return true }
    // How sharply the lift bends between samples is set by how fast what it follows moves (a clamped lift may move
    // 40 pt while its row travels 1,000), not by how far the lift itself moves.
    let travel = max(abs(overhangSlope), abs(maxLiftSlope))
    let followed = timing.follow(interval: timing.interval(amplitude: travel), kinks: kinks) { -lift($0) * sign }
    guard followed.varies else { return true }
    let animation = CAKeyframeAnimation(keyPath: "position.y")
    animation.values = followed.values.map { NSNumber(value: Double($0)) }
    animation.keyTimes = followed.keyTimes.map { NSNumber(value: $0) }
    animation.duration = timing.duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    animation.fillMode = .backwards
    animation.isRemovedOnCompletion = true
    pinTrackCount &+= 1
    layer.add(animation, forKey: "\(Self.pinKey).\(pinTrackCount)")
    return true
  }

  /// A row leaving the placed window during an animated change keeps its pin while it is still on screen: a far
  /// jump's old screen sliding out, or a row that fell out of the window travelling with the content until the motion
  /// ends. It moves rigidly with its neighbours, starting `travel` from where it ends, so its lift follows like any
  /// animated change (its span's top moves with it). For a slide, rows above the screen went at once, so the pin stops
  /// at the top of the strip (`stripTop`, layout y of the old layout, with the span's top inset) if its span started
  /// above it: it never rises over the destination joined there. `edge` is the old layout's visible bottom edge.
  func slidePin(_ slot: Slot, travel: CGFloat, timing: TimelineTiming, stripTop: CGFloat?, edge: CGFloat) {
    guard var pin = slot.pin, let layer = pin.view.layer else { return }
    for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.pinKey) {
      layer.removeAnimation(forKey: key)
    }
    if let stripTop {
      // The pin's resting top, in the old layout: its bottom is `overhang` below the edge.
      let restTop = pin.geometry.overhang + edge - pin.rest.height
      pin.geometry.maxLift = min(pin.geometry.maxLift, max(0, restTop - stripTop))
    }
    // Where it settles: `travel` further along, against the edge where it settles.
    pin.geometry.overhang += edgeStart - travel
    pin.flightStart = nil
    slot.pin = pin
    place(pin.view, in: slot.row, rest: pin.rest, lift: pin.geometry.lift)
    _ = bakeAlong(timing, layer: layer, pin: pin, rowStart: travel, spanStart: travel, sign: downward(in: pin.view))
  }

  /// Puts the pin view at its resting place in the row (top-down `rest`, in the row's coordinates), lifted by `lift`.
  func place(_ view: NSView, in row: NSView, rest: CGRect, lift: CGFloat) {
    guard let superview = view.superview else { return }
    let top = rest.minY - lift
    let inRow = NSRect(x: 0, y: row.isFlipped ? top : row.bounds.height - top - rest.height, width: 1, height: rest.height)
    let y = superview.convert(inRow, from: row).minY
    guard abs(view.frame.minY - y) > 0.001 else { return }
    view.setFrameOrigin(NSPoint(x: view.frame.minX, y: y))
  }

  /// +1 when a view's layer `position.y` grows downward on screen (its superview is flipped like the list), −1 when
  /// it grows upward.
  func downward(in view: NSView) -> CGFloat {
    guard let superview = view.superview else { return 1 }
    let a = superview.convert(NSPoint(x: 0, y: 0), from: self)
    let b = superview.convert(NSPoint(x: 0, y: 1), from: self)
    return b.y >= a.y ? 1 : -1
  }

  /// The pin's lift on screen at `now`, from its model value and its flight path.
  func presentedLift(_ pin: PinState, now: CFTimeInterval) -> CGFloat {
    guard let start = pin.flightStart, let flight, flight.start == start else { return pin.geometry.lift }
    return pin.geometry.lift(shift: flight.shift(at: now) - flight.ahead)
  }

  /// The flight's path as the pin's lift: the same samples on the same clock as the content's.
  func bake(_ layer: CALayer, _ pin: PinState, flight: Flight, sign: CGFloat) {
    layer.removeAnimation(forKey: Self.pinKey)
    // A lift is a move up on screen; what the path adds is the end's lift less the sample's.
    let geometry = pin.geometry
    let followed = flight.path.follow(
      { -geometry.lift(shift: $0) * sign }, kinks: [-geometry.overhang, geometry.maxLift - geometry.overhang]
    )
    guard followed.varies else { return }
    layer.add(
      flightAnimation(keyPath: "position.y", values: followed.values, keyTimes: followed.keyTimes, flight: flight, layer: layer),
      forKey: Self.pinKey
    )
  }

  /// The pin goes back to rest: its row left, or no longer has it.
  func unpin(_ slot: Slot) {
    guard let pin = slot.pin else { return }
    slot.pin = nil
    slot.view.layer?.zPosition = 0
    guard let layer = pin.view.layer else { return }
    for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.pinKey) {
      layer.removeAnimation(forKey: key)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    place(pin.view, in: slot.row, rest: pin.rest, lift: 0)
    CATransaction.commit()
  }

  /// An additive keyframe animation on the flight's clock.
  func flightAnimation(
    keyPath: String, values: [CGFloat], keyTimes: [Double]? = nil, flight: Flight, layer: CALayer
  ) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values.map { NSNumber(value: Double($0)) }
    animation.keyTimes = keyTimes?.map { NSNumber(value: $0) }
    animation.duration = flight.path.duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    animation.beginTime = layer.convertTime(flight.start, from: nil)
    animation.isRemovedOnCompletion = true
    animation.fillMode = .backwards
    animation.preferredFrameRateRange = flightFrameRate
    return animation
  }

  var flightFrameRate: CAFrameRateRange {
    let maximum = Float(window?.screen?.maximumFramesPerSecond ?? 60)
    // Pinned to the display's top rate: a wider range lets ProMotion throttle a fling to about 80 Hz (Telegram's
    // CoreList found the same).
    return CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
  }

  // MARK: - Floating header

  /// Where the header is with the content where it settles, in this view's coordinates.
  func settledHeaderPlace() -> TimelineFloatingHeaderPlace<ID>? {
    guard let header = floatingHeader else { return nil }
    return TimelineHeaderFloat.place(
      in: state.layout, height: header.height, gap: header.gap, shift: flight?.ahead ?? 0, section: header.section
    )
  }

  /// The header's top on screen now, when it shows.
  func presentedHeaderTop() -> CGFloat? {
    guard let header = floatingHeader, headerShown != nil, let layer = header.view.layer else { return nil }
    let presented = layer.presentation() ?? layer
    guard presented.opacity > 0.01 else { return nil }
    return presentedFrame(of: header.view)?.minY
  }

  /// Places the floating header for the current state: its section, its place with the content where it settles,
  /// its path along a running flight, and a track from `from` (where it was on screen) with an animated timing.
  func updateFloatingHeader(timing: TimelineTiming, from: CGFloat? = nil) {
    guard let header = floatingHeader, let layer = header.view.layer else { return }
    let place = settledHeaderPlace()
    let width = bounds.width
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let place else {
      if headerShown != nil {
        headerShown = nil
        headerFlightStart = nil
        layer.removeAnimation(forKey: Self.headerKey)
        layer.removeAnimation(forKey: "\(Self.headerKey).opacity")
        layer.opacity = 0
      }
      // A flight can still bring the header in: bake its path from hidden.
      bakeHeaderFromHidden(header, layer: layer)
      return
    }
    let sectionChanged = headerShown?.section != place.section
    if sectionChanged { header.configure(header.view, place.section) }
    let frame = NSRect(x: 0, y: place.y, width: width, height: header.height)
    let moved = header.view.frame.minY - place.y
    let wasShown = headerShown != nil
    if header.view.frame != frame { header.view.frame = frame }
    layer.opacity = 1
    layer.removeAnimation(forKey: "\(Self.headerKey).opacity")
    if let flight {
      if headerFlightStart != flight.start || sectionChanged || headerShown?.y != place.y {
        bakeHeader(header, layer: layer, flight: flight, section: place.section)
      }
    } else {
      layer.removeAnimation(forKey: Self.headerKey)
      headerFlightStart = nil
    }
    headerShown = place
    guard timing.isAnimated, wasShown, !sectionChanged else { return }
    let start = from.map { $0 - place.y } ?? moved
    if abs(start) > 0.01, let track = timing.track(keyPath: "position.y", from: start) {
      headerTrackCount &+= 1
      layer.add(track, forKey: "\(Self.headerKey).track.\(headerTrackCount)")
    }
  }

  /// The header's place along the running flight, for the section it shows: its y and, where the section's own row
  /// is in sight or the header is pushed out, its opacity.
  func bakeHeader(_ header: TimelineFloatingHeader<ID>, layer: CALayer, flight: Flight, section: ID) {
    layer.removeAnimation(forKey: Self.headerKey)
    layer.removeAnimation(forKey: "\(Self.headerKey).opacity")
    headerFlightStart = flight.start
    let layout = state.layout
    let ahead = flight.ahead
    let endY = header.view.frame.minY
    var lastY = endY
    var ys: [CGFloat] = []
    var opacities: [CGFloat] = []
    var moves = false
    var fades = false
    let sampler = TimelineHeaderFloat.Sampler(layout: layout, height: header.height, gap: header.gap, section: header.section)
    for position in flight.path.positions {
      let shift = ahead + CGFloat(position - flight.path.end)
      let place = sampler.place(shift: shift)
      if let place, place.section == section {
        lastY = place.y
        ys.append(place.y - endY)
        opacities.append(0)
      } else {
        ys.append(lastY - endY)
        opacities.append(-1)
        fades = true
      }
      if abs(ys[ys.count - 1]) > 0.01 { moves = true }
    }
    if moves { layer.add(flightAnimation(keyPath: "position.y", values: ys, flight: flight, layer: layer), forKey: Self.headerKey) }
    if fades {
      let fade = flightAnimation(keyPath: "opacity", values: opacities, flight: flight, layer: layer)
      fade.calculationMode = .discrete
      layer.add(fade, forKey: "\(Self.headerKey).opacity")
    }
  }

  /// Hidden where the flight ends, the header may still show along the way: baked for the section the flight's
  /// first sample shows, if any, so it leaves with the content rather than vanishing.
  func bakeHeaderFromHidden(_ header: TimelineFloatingHeader<ID>, layer: CALayer) {
    guard let flight, headerFlightStart != flight.start else { return }
    headerFlightStart = flight.start
    let layout = state.layout
    let now = CACurrentMediaTime()
    guard let current = TimelineHeaderFloat.place(
      in: layout, height: header.height, gap: header.gap, shift: flight.shift(at: now), section: header.section
    ) else { return }
    header.configure(header.view, current.section)
    header.view.frame = NSRect(x: 0, y: current.y, width: bounds.width, height: header.height)
    layer.opacity = 0
    var ys: [CGFloat] = []
    var opacities: [CGFloat] = []
    var lastY = current.y
    let sampler = TimelineHeaderFloat.Sampler(layout: layout, height: header.height, gap: header.gap, section: header.section)
    for position in flight.path.positions {
      let shift = flight.ahead + CGFloat(position - flight.path.end)
      if let place = sampler.place(shift: shift), place.section == current.section {
        lastY = place.y
        opacities.append(1)
      } else {
        opacities.append(0)
      }
      ys.append(lastY - current.y)
    }
    layer.add(flightAnimation(keyPath: "position.y", values: ys, flight: flight, layer: layer), forKey: Self.headerKey)
    let fade = flightAnimation(keyPath: "opacity", values: opacities, flight: flight, layer: layer)
    fade.calculationMode = .discrete
    layer.add(fade, forKey: "\(Self.headerKey).opacity")
  }

  /// Each frame of a flight: when the section on screen is no longer the one the header was baked for, show the new
  /// one and bake its path from here.
  func followHeaderSection() {
    guard let header = floatingHeader, let flight else { return }
    let now = CACurrentMediaTime()
    let current = TimelineHeaderFloat.place(
      in: state.layout, height: header.height, gap: header.gap, shift: flight.shift(at: now), section: header.section
    )
    guard let current, current.section != headerShown?.section else { return }
    // The section on screen differs from the one baked: re-place for the end, then bake from here.
    headerFlightStart = nil
    headerShown = nil
    updateFloatingHeader(timing: .none)
    if headerShown?.section != current.section, let layer = header.view.layer {
      bakeHeaderFromHidden(header, layer: layer)
    }
  }

  /// The header's visibility policy: shown while the list moves, faded after it rests.
  func showFloatingHeader() {
    guard let header = floatingHeader else { return }
    headerHide?.cancel()
    headerHide = nil
    if headerContainer.alphaValue < 1 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        headerContainer.animator().alphaValue = 1
      }
    }
    _ = header
  }

  func scheduleFloatingHeaderHide() {
    guard let header = floatingHeader, header.hidesWhenIdle else { return }
    headerHide?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isTracking, self.flight == nil, self.coast == nil else { return }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.3
          self.headerContainer.animator().alphaValue = 0
        }
      }
    }
    headerHide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + header.idleDelay, execute: work)
  }
}
#endif
