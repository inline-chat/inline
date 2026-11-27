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
      // A top pin: its span ends at the bottom of its last row (less the host's inset); in mirrored coordinates that is
      // the span's "top", its rest top the "bottom", the usable top (plus its gap) the edge.
      let top = pin.edge == .top
      let mirror: CGFloat = top ? -1 : 1
      var spanEndID: ID?
      var geometry: TimelinePinGeometry
      if top {
        var spanBottom = CGFloat.infinity
        if let end = pin.spanEnd, let index = state.index[end], index >= first.index, index - first.index < layout.placements.count {
          let placed = layout.placements[index - first.index]
          spanBottom = placed.maxY - pin.spanBottomInset + ahead
          spanEndID = end
        }
        geometry = TimelinePinGeometry(
          bottom: -(placement.y + pin.bottom - pin.height + ahead), height: pin.height, spanTop: -spanBottom,
          edge: -(layout.viewport.usableTop + pin.edgeGap)
        )
      } else {
        geometry = TimelinePinGeometry(bottom: placement.y + pin.bottom + ahead, height: pin.height, spanTop: spanTop, edge: edge)
      }
      var next = PinState(
        view: pin.view,
        spanStart: pin.spanStart,
        rest: CGRect(x: 0, y: pin.bottom - pin.height, width: 0, height: pin.height),
        geometry: geometry,
        flightStart: flight?.start
      )
      next.mirror = mirror
      // Every pass: the host may have laid the view out at rest since (an update of the row).
      slot.row.layoutSubtreeIfNeeded()
      place(pin.view, in: slot.row, rest: next.rest, lift: next.geometry.lift * mirror)
      // The pin's place in its row moved (the row grew or shrank under it): it starts where it rested and moves on the
      // change's timing, as the row's insides do (the host animates them on it). Placed at its new rest at once, an
      // avatar sat up to 46 pt below its growing bubble (update lab, `update.growAbove`). Its place on screen can stay
      // the same (the row's top moved up as much), so this comes before the geometry check.
      var restMoved: CGFloat = 0
      if timing.isAnimated, let old = slot.pin, old.view === next.view {
        restMoved = next.rest.minY - old.rest.minY
      } else if timing.isAnimated, avatarArrivals[placement.id] == nil, let before = pinRestBefore[placement.id],
                before.view === next.view
      {
        // A pin new to a row this change updated (a regroup handed it the avatar as the row changed): it rests where
        // the host's insides put it, which the host moves from where they were on the change's timing, so it starts
        // where it would have rested in the row's old layout (the host's answer, asked before the update).
        restMoved = next.rest.minY - before.top
      } else if timing.isAnimated, avatarArrivals[placement.id] == nil, let grown = contentResized[placement.id] {
        // The host gave no pin for the row's old layout: a guess, the rest kept its distance from the row's bottom (47 pt
        // below the bubble without it, `update.batch` pinned). Rows only regrouped are left out: guessing their pin's
        // old rest from the row's bottom broke four delete and reorder cases.
        restMoved = grown
      }
      // A pin new to a row the change resized (a regroup handed it the avatar) is not started from a guessed rest:
      // assuming it sat on the row's old bottom fixed one batch case (46 → 8 pt) and broke four delete and reorder cases
      // (0 → 6–52 pt) in the update lab, 2026-11-27.
      if abs(restMoved) > 0.01 {
        if let track = timing.track(keyPath: "position.y", from: -restMoved * downward(in: pin.view)) {
          pinTrackCount &+= 1
          layer.add(stamped(track), forKey: "\(Self.pinKey).\(pinTrackCount)")
        }
      }
      if let old = slot.pin, old.matches(next) {
        slot.pin = next
        continue
      }
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
          layer.add(stamped(track), forKey: "\(Self.pinKey).\(pinTrackCount)")
        }
      }
      // The lift follows everything moving it at once: a running flight's path and each animated change still under
      // way (its row, less what the pin's rest moved in the row, its span's top and the edge, each `start × q(t)`).
      // Baked again from now whenever any of them changes, so a change landing mid-flight (an arrival or a growing
      // row during a bounce) or an inset change during a drag or a jump is in the bake (they were baked along the
      // flight only, or against a settled state the next update replaced: 4.8–64 pt off in the update lab).
      // Changes from an earlier pass: their tracks have committed, and so has the bake that began with them.
      if slot.pinChanges.contains(where: { !$0.resolved }), let begun = layer.animation(forKey: Self.pinKey), begun.beginTime > 0 {
        let start = layer.convertTime(begun.beginTime, to: nil)
        for i in slot.pinChanges.indices where !slot.pinChanges[i].resolved {
          slot.pinChanges[i].start = start
          slot.pinChanges[i].resolved = true
        }
      }
      let previousGeometry = slot.pin?.geometry
      let previousChanges = slot.pinChanges
      slot.pin = next
      slot.pinChanges.removeAll { $0.timing.remaining(at: now - $0.start) <= 0 }
      var added = false
      if timing.isAnimated, !handedOver, let rowStart = rowStarts[placement.id] {
        let row = (rowStart - restMoved) * mirror
        let overhangSlope = row - (top ? -topEdgeStart : edgeStart)
        let maxLiftSlope = (top ? spanEndID : spanStartID).flatMap { rowStarts[$0] }.map { row - $0 * mirror } ?? 0
        if abs(overhangSlope) > 0.01 || abs(maxLiftSlope) > 0.01 {
          slot.pinChanges.append(PinChange(start: commitTime, timing: timing, overhangSlope: overhangSlope, maxLiftSlope: maxLiftSlope))
          added = true
        }
      }
      // A change added now: the bake begins with its tracks, when the transaction commits (on `commitTime`'s clock).
      if slot.pinChanges.isEmpty, let flight {
        // Only the flight moves it: its own path's samples and exact crossings (the cheaper bake: the lift's cost
        // went 0.40 → 0.70 ms when every pin took the combined one).
        bake(layer, next, flight: flight, sign: sign)
      } else {
        bakeLift(layer, next, slot.pinChanges, now: added ? commitTime : now, sign: sign)
      }
      // An animated change that moves nothing the lift depends on but still changes it (a span that regrouped): from
      // where it showed, on the change's timing. Not for a row a reorder landed somewhere else: its lift there starts
      // fresh (eased from its old place's, an arriving row's avatar sat 3.9 pt lifted off its bubble at its new place,
      // `update.reorderPending` pinned).
      if timing.isAnimated, !added, !handedOver, !landedMoves.contains(placement.id), let previousGeometry {
        let before = liftAt(previousGeometry, previousChanges, time: now, mirror: mirror)
        let after = liftAt(next.geometry, slot.pinChanges, time: now, mirror: mirror)
        if abs(before - after) > 0.01, let track = timing.track(keyPath: "position.y", from: -(before - after) * sign * mirror) {
          pinTrackCount &+= 1
          layer.add(stamped(track), forKey: "\(Self.pinKey).\(pinTrackCount)")
        }
      }
    }
  }

  /// The pin's lift at `time`: its geometry moved by the running flight (row and span together) and by each change's
  /// remaining part.
  func liftAt(_ geometry: TimelinePinGeometry, _ changes: [PinChange], time: CFTimeInterval, mirror: CGFloat = 1) -> CGFloat {
    var overhang = geometry.overhang
    var maxLift = geometry.maxLift
    if let flight { overhang += (flight.shift(at: time) - flight.ahead) * mirror }
    for change in changes {
      let q = CGFloat(change.timing.remaining(at: time - change.start))
      overhang += change.overhangSlope * q
      maxLift += change.maxLiftSlope * q
    }
    return max(0, min(overhang, max(0, maxLift)))
  }

  /// One additive animation of the lift from now until the flight and every change have ended, on the flight's sample
  /// rate (1/240 s at most), with a sample added exactly where the lift's clamp switches (found by bisection), so
  /// linear interpolation cuts no corner.
  func bakeLift(
    _ layer: CALayer, _ pin: PinState, _ changes: [PinChange], now: CFTimeInterval, implicitBegin: Bool = false, sign: CGFloat
  ) {
    layer.removeAnimation(forKey: Self.pinKey)
    var end = now
    if let flight { end = max(end, flight.start + flight.path.duration) }
    for change in changes { end = max(end, change.start + change.timing.duration) }
    guard end > now + 0.001 else { return }
    let final = pin.geometry.lift
    let step = min(flight?.path.interval ?? (1.0 / 240), 1.0 / 240)
    func regime(_ t: CFTimeInterval) -> Int {
      var overhang = pin.geometry.overhang
      var maxLift = pin.geometry.maxLift
      if let flight { overhang += (flight.shift(at: t) - flight.ahead) * pin.mirror }
      for change in changes {
        let q = CGFloat(change.timing.remaining(at: t - change.start))
        overhang += change.overhangSlope * q
        maxLift += change.maxLiftSlope * q
      }
      return overhang <= 0 ? 0 : overhang < max(0, maxLift) ? 1 : 2
    }
    var times: [CFTimeInterval] = []
    var t = now
    var last = regime(now)
    times.append(now)
    while t < end - 1e-6 {
      let next = min(end, t + step)
      let state = regime(next)
      if state != last {
        var low = t
        var high = next
        for _ in 0 ..< 12 {
          let mid = (low + high) / 2
          if regime(mid) == last { low = mid } else { high = mid }
        }
        times.append(low)
        times.append(high)
        last = state
      }
      times.append(next)
      t = next
    }
    var values: [NSNumber] = []
    var varies = false
    for time in times {
      let value = -(liftAt(pin.geometry, changes, time: time, mirror: pin.mirror) - final) * sign * pin.mirror
      if abs(value) > 0.01 { varies = true }
      values.append(NSNumber(value: Double(value)))
    }
    guard varies else { return }
    let duration = end - now
    let animation = CAKeyframeAnimation(keyPath: "position.y")
    animation.values = values
    animation.keyTimes = times.map { NSNumber(value: ($0 - now) / duration) }
    animation.duration = duration
    animation.calculationMode = .linear
    animation.isAdditive = true
    if !implicitBegin { animation.beginTime = layer.convertTime(now, from: nil) }
    animation.isRemovedOnCompletion = true
    animation.fillMode = .backwards
    animation.preferredFrameRateRange = flightFrameRate
    layer.add(animation, forKey: Self.pinKey)
  }

  /// Bakes the pin's lift along an animated change: at each moment the row, its span's top and the edge are
  /// `start × q` from where they settle (q: how much of the motion remains), so the lift is the pin geometry with those
  /// offsets. False when nothing it depends on moves.
  func bakeAlong(
    _ timing: TimelineTiming, layer: CALayer, pin: PinState, rowStart: CGFloat, spanStart: CGFloat?, sign: CGFloat
  ) -> Bool {
    let geometry = pin.geometry
    let overhangSlope = rowStart - (pin.mirror > 0 ? edgeStart : -topEdgeStart)
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
    layer.add(stamped(animation), forKey: "\(Self.pinKey).\(pinTrackCount)")
    return true
  }

  /// A row leaving the placed window during an animated change keeps its pin while it is still on screen: a far
  /// jump's old screen sliding out, or a row that fell out of the window travelling with the content until the motion
  /// ends. It moves rigidly with its neighbours, starting `travel` from where it ends, so its lift follows like any
  /// animated change (its span's top moves with it). For a slide, rows above the screen went at once, so the pin stops
  /// at the top of the strip (`stripTop`, layout y of the old layout, with the span's top inset) if its span started
  /// above it: it never rises over the destination joined there. `edge` is the old layout's visible bottom edge.
  func slidePin(_ slot: Slot, travel: CGFloat, timing: TimelineTiming, stripTop: CGFloat?, edge: CGFloat) {
    slot.pinChanges = []
    guard var pin = slot.pin, let layer = pin.view.layer else { return }
    for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.pinKey) {
      layer.removeAnimation(forKey: key)
    }
    if let stripTop, pin.mirror > 0 {
      // The pin's resting top, in the old layout: its bottom is `overhang` below the edge.
      let restTop = pin.geometry.overhang + edge - pin.rest.height
      pin.geometry.maxLift = min(pin.geometry.maxLift, max(0, restTop - stripTop))
    }
    // Where it settles: `travel` further along, against the edge where it settles.
    let m = pin.mirror
    pin.geometry.overhang += (m > 0 ? edgeStart : -topEdgeStart) - travel * m
    pin.flightStart = nil
    slot.pin = pin
    place(pin.view, in: slot.row, rest: pin.rest, lift: pin.geometry.lift * m)
    _ = bakeAlong(timing, layer: layer, pin: pin, rowStart: travel * m, spanStart: travel * m, sign: downward(in: pin.view) * m)
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
    return pin.geometry.lift(shift: (flight.shift(at: now) - flight.ahead) * pin.mirror)
  }

  /// The flight's path as the pin's lift: the same samples on the same clock as the content's.
  func bake(_ layer: CALayer, _ pin: PinState, flight: Flight, sign: CGFloat) {
    layer.removeAnimation(forKey: Self.pinKey)
    // A lift is a move up on screen; what the path adds is the end's lift less the sample's.
    let geometry = pin.geometry
    let m = pin.mirror
    let followed = flight.path.follow(
      { -geometry.lift(shift: $0 * m) * sign * m }, kinks: [-geometry.overhang * m, (geometry.maxLift - geometry.overhang) * m]
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
      in: state.layout, height: header.height, gap: header.gap, ownInset: header.ownInset, shift: flight?.ahead ?? 0,
      section: header.section
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
  func updateFloatingHeader(timing: TimelineTiming, from: CGFloat? = nil, slides: Bool = false) {
    guard let header = floatingHeader, let layer = header.view.layer else { return }
    defer { syncSectionRows(timing: slides ? .none : timing) }
    // A far jump's slide: the screen sliding out and the destination sliding in move as one strip; the header follows
    // the rows of both as they show (placed at the destination's settled place, it showed over the destination's own
    // day row mid-slide, `update.deleteAbove` mid-jump, 6 frames). Not bakeable: as before, at once.
    // A far jump's slide: the date hides while the two strips slide and shows again, for the destination, as the
    // slide ends (Telegram shows the target alone, then fills history; decided 2026-11-27, reversible). One date view
    // can show one title, and a slide across two days showed the destination's 4–6 frames early.
    if slides {
      updateFloatingHeader(timing: .none, from: from)
      guard timing.isAnimated, headerShown != nil else { return }
      let duration = Double(timing.duration)
      let fadeIn = 0.1
      let hold = CAKeyframeAnimation(keyPath: "opacity")
      hold.values = [0, 0, 1]
      hold.keyTimes = [0, NSNumber(value: duration / (duration + fadeIn)), 1]
      hold.duration = duration + fadeIn
      hold.fillMode = .backwards
      layer.add(stamped(hold), forKey: "\(Self.headerKey).slide")
      return
    }
    // An animated change that moves rows (a delete closing, a growth, an update that waited out a slide): where the
    // header goes, and whether it shows, follow the rows as they move, not their settled places (decided on those, it
    // showed or hid 4–6 frames early, `update.deleteAbove` mid-jump).
    if timing.isAnimated, flight == nil, !rowStarts.isEmpty, bakeHeaderAlongChange(header, layer: layer, timing: timing) {
      return
    }
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
    // Along a flight the section on screen now leads: where it is not the one the flight ends in, the header shows it,
    // baked from here (title, place, fade), and each frame follows into the next (`followHeaderSection`). Baked for the
    // end alone, the day at the top went untitled for ~300 ms of a fling into an older day (`day-pill` journey).
    if let flight, let current = currentHeaderPlace(header, flight: flight), current.section != place.section {
      headerShown = place
      if headerBakedSection != current.section || headerFlightStart != flight.start {
        headerFlightStart = nil
        bakeHeaderFromHidden(header, layer: layer)
      }
      return
    }
    let sectionChanged = headerTitle != place.section
    if sectionChanged {
      header.configure(header.view, place.section)
      headerTitle = place.section
    }
    let frame = NSRect(x: 0, y: place.y, width: width, height: header.height)
    let moved = header.view.frame.minY - place.y
    let wasShown = headerShown != nil
    if header.view.frame != frame { header.view.frame = frame }
    layer.opacity = 1
    layer.removeAnimation(forKey: "\(Self.headerKey).opacity")
    if let flight {
      if headerFlightStart != flight.start || sectionChanged || headerShown?.y != place.y || headerBakedSection != place.section {
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
      layer.add(stamped(track), forKey: "\(Self.headerKey).track.\(headerTrackCount)")
    }
  }

  /// The header along an animated change: at each sample its place among the rows as they show then (each row its
  /// settled y plus what it still has to travel), baked as one additive position track and a stepped opacity, on the
  /// change's own clock (begun with its tracks, when the transaction commits). False when the change shows no section or
  /// passes through more than one (the plain path handles those).
  func bakeHeaderAlongChange(
    _ header: TimelineFloatingHeader<ID>, layer: CALayer, timing: TimelineTiming, strip: Bool = false
  ) -> Bool {
    var layout = state.layout
    if strip {
      // The strip sliding out (lingering), where it settles in the layout's coordinates: it moves with the destination.
      let origin = content.bounds.origin.y
      let outgoing = lingering.map { TimelinePlacement(id: $0.key, index: -1, y: $0.value.slot.y - origin, height: $0.value.slot.height) }
      layout.placements = (layout.placements + outgoing).sorted { $0.y < $1.y }
    }
    let own = Double(timing.duration)
    guard own > 0.01 else { return false }
    // Scrolls still running from earlier changes (a jump this change landed in) move every row too: the content's
    // bounds origin is that much from where it settles (the bake replaces the header's own tracks for them).
    let earlier = contentTracks.filter { $0.start < commitTime - 0.000_001 }
    let carouselStart = strip ? (layout.placements.lazy.compactMap { self.rowStarts[$0.id] }.first ?? 0) : 0
    let duration = earlier.reduce(own) { max($0, $1.start + Double($1.timing.duration) - commitTime) }
    let count = max(2, Int(duration * 120) + 1)
    var places: [TimelineFloatingHeaderPlace<ID>?] = []
    places.reserveCapacity(count)
    var moving = layout
    for i in 0 ..< count {
      let t = Double(i) / Double(count - 1) * duration
      let q = CGFloat(timing.remaining(at: t))
      let scrolled = earlier.reduce(CGFloat(0)) { $0 + $1.from * CGFloat($1.timing.remaining(at: commitTime + t - $1.start)) }
      moving.placements = layout.placements.map { placement in
        var placement = placement
        placement.y += (rowStarts[placement.id] ?? (strip ? carouselStart : 0)) * q - scrolled
        return placement
      }
      places.append(TimelineHeaderFloat.place(
        in: moving, height: header.height, gap: header.gap, ownInset: header.ownInset, shift: 0, section: header.section
      ))
    }
    let sections = Set(places.compactMap { $0?.section })
    guard sections.count == 1, let section = sections.first, let anchor = places.last.flatMap({ $0 }) ?? places.compactMap({ $0 }).first
    else { return false }
    let final = places[count - 1]
    if headerTitle != section {
      header.configure(header.view, section)
      headerTitle = section
    }
    let frame = NSRect(x: 0, y: anchor.y, width: bounds.width, height: header.height)
    if header.view.frame != frame { header.view.frame = frame }
    // A far jump's slide still hiding the date (an inset change lands mid-slide, it does not wait): the hold stays, and
    // being the earlier of two opacity animations it is what shows (22 frames shown mid-slide when removed here).
    for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.headerKey) && key != "\(Self.headerKey).slide" {
      layer.removeAnimation(forKey: key)
    }
    layer.opacity = final == nil ? 0 : 1
    var ys: [NSNumber] = []
    var opacities: [NSNumber] = []
    var lastY = anchor.y
    var fades = false
    for place in places {
      if let place { lastY = place.y }
      ys.append(NSNumber(value: Double(lastY - anchor.y)))
      opacities.append(NSNumber(value: place == nil ? 0 : 1))
      if (place == nil) != (final == nil) { fades = true }
    }
    let move = CAKeyframeAnimation(keyPath: "position.y")
    move.values = ys
    move.duration = duration
    move.calculationMode = .linear
    move.isAdditive = true
    move.fillMode = .backwards
    layer.add(stamped(move), forKey: Self.headerKey)
    if fades {
      let fade = CAKeyframeAnimation(keyPath: "opacity")
      fade.values = opacities
      fade.duration = duration
      fade.calculationMode = .discrete
      fade.fillMode = .backwards
      layer.add(stamped(fade), forKey: "\(Self.headerKey).opacity")
    }
    headerShown = final
    headerFlightStart = nil
    return true
  }

  /// The header's place along the running flight, for the section it shows: its y and, where the section's own row
  /// is in sight or the header is pushed out, its opacity.
  func bakeHeader(_ header: TimelineFloatingHeader<ID>, layer: CALayer, flight: Flight, section: ID) {
    layer.removeAnimation(forKey: Self.headerKey)
    layer.removeAnimation(forKey: "\(Self.headerKey).opacity")
    headerFlightStart = flight.start
    headerBakedSection = section
    let layout = state.layout
    let ahead = flight.ahead
    let endY = header.view.frame.minY
    var lastY = endY
    var ys: [CGFloat] = []
    var opacities: [CGFloat] = []
    var moves = false
    var fades = false
    let sampler = TimelineHeaderFloat.Sampler(
      layout: layout, height: header.height, gap: header.gap, ownInset: header.ownInset, section: header.section
    )
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
    let now = followTime ?? CACurrentMediaTime()
    guard let current = TimelineHeaderFloat.place(
      in: layout, height: header.height, gap: header.gap, ownInset: header.ownInset, shift: flight.shift(at: now),
      section: header.section
    ) else { return }
    header.configure(header.view, current.section)
    headerTitle = current.section
    headerBakedSection = current.section
    header.view.frame = NSRect(x: 0, y: current.y, width: bounds.width, height: header.height)
    layer.opacity = 0
    var ys: [CGFloat] = []
    var opacities: [CGFloat] = []
    var lastY = current.y
    let sampler = TimelineHeaderFloat.Sampler(
      layout: layout, height: header.height, gap: header.gap, ownInset: header.ownInset, section: header.section
    )
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
    guard let current = currentHeaderPlace(header, flight: flight), current.section != headerBakedSection else { return }
    // The section on screen differs from the one baked: place again (the one on screen leads), from here.
    headerFlightStart = nil
    updateFloatingHeader(timing: .none)
  }

  /// The header's place with the content where a running flight shows it on the frame being made (the display link's
  /// target in a tick): a section reached on that frame is shown on it (at the current time, the header took a new day
  /// over a frame after its row hid: 2 of 684 fling samples untitled).
  func currentHeaderPlace(_ header: TimelineFloatingHeader<ID>, flight: Flight) -> TimelineFloatingHeaderPlace<ID>? {
    TimelineHeaderFloat.place(
      in: state.layout, height: header.height, gap: header.gap, ownInset: header.ownInset,
      shift: flight.shift(at: followTime ?? CACurrentMediaTime()), section: header.section
    )
  }

  /// `hidesOwnRow`: each section's own row placed hides while its title is above the header's place (where the header
  /// takes the title over), on the path the content takes: along a running flight (baked once per flight and place),
  /// along an animated change's row tracks, or at once. The rule is the header's own (`TimelineHeaderFloat`), per row.
  func syncSectionRows(timing: TimelineTiming) {
    guard let header = floatingHeader, header.hidesOwnRow else { return }
    let layout = state.layout
    let line = layout.viewport.usableTop + header.gap - 0.5
    let along = timing.isAnimated && flight == nil && !rowStarts.isEmpty
    let duration = Double(timing.duration)
    let count = along ? max(2, Int(duration * 120) + 1) : 0
    let earlier = along ? contentTracks.filter { $0.start < commitTime - 0.000_001 } : []
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for placement in layout.placements {
      guard let slot = slots[placement.id], header.section(placement.id) == placement.id else { continue }
      let title = placement.y + header.ownInset
      let layer = slot.row.layer
      if let flight {
        // Its place where the flight ends is the same on every frame of it: baked once.
        let end = title + flight.ahead
        if let bake = slot.sectionBake, bake.flightStart == flight.start, abs(bake.y - end) < 0.25 { continue }
        slot.sectionBake = (flight.start, end)
        layer?.removeAnimation(forKey: Self.sectionRowKey)
        let hidden = flight.path.positions.map { end + CGFloat($0 - flight.path.end) < line }
        slot.row.isHidden = end < line
        if let layer, hidden.contains(!slot.row.isHidden) {
          let animation = CAKeyframeAnimation(keyPath: "hidden")
          animation.values = hidden.map { NSNumber(value: $0) }
          animation.duration = flight.path.duration
          animation.calculationMode = .discrete
          animation.beginTime = layer.convertTime(flight.start, from: nil)
          animation.isRemovedOnCompletion = true
          animation.fillMode = .backwards
          animation.preferredFrameRateRange = flightFrameRate
          layer.add(animation, forKey: Self.sectionRowKey)
        }
        continue
      }
      slot.sectionBake = nil
      layer?.removeAnimation(forKey: Self.sectionRowKey)
      // While the header is faded (at rest, or before the list first moves), a title only just past its place keeps
      // its own row (the fade keeps such a title: `scheduleFloatingHeaderHide`).
      slot.row.isHidden = title < line && (headerContainer.alphaValue > 0.5 || title < line - header.height / 2)
      guard along, let layer else { continue }
      // Along the change: the row where it shows at each sample (its start offset closing, earlier scrolls running).
      var hidden: [Bool] = []
      hidden.reserveCapacity(count)
      for i in 0 ..< count {
        let t = Double(i) / Double(count - 1) * duration
        let q = CGFloat(timing.remaining(at: t))
        let scrolled = earlier.reduce(CGFloat(0)) { $0 + $1.from * CGFloat($1.timing.remaining(at: commitTime + t - $1.start)) }
        hidden.append(title + (rowStarts[placement.id] ?? 0) * q - scrolled < line)
      }
      guard hidden.contains(!slot.row.isHidden) else { continue }
      let animation = CAKeyframeAnimation(keyPath: "hidden")
      animation.values = hidden.map { NSNumber(value: $0) }
      animation.duration = duration
      animation.calculationMode = .discrete
      animation.fillMode = .backwards
      layer.add(stamped(animation), forKey: Self.sectionRowKey)
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
        // A title only just past the header's place stays (Telegram: less than half its height from its row): its row
        // is hidden under it, so fading it would take the title off its own place.
        if header.hidesOwnRow, let shown = self.headerShown, let own = self.state.layout.placement(for: shown.section),
           own.y + header.ownInset > shown.y - header.height / 2
        {
          return
        }
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
