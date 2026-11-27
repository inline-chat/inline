import CoreGraphics

// What stays in sight while the rows it belongs to do, as pure functions of the layout and of how far the
// content has moved from it. A host evaluates them for the settled layout, and along a fling's path for each
// of the path's samples, so a sticky thing moves on the render server with the content.
//
// Shifts are in the layout's coordinates: positive moves the content down (towards older rows), as
// `TimelineScroll.by`. A layout's rows at shift `s` are at `placement.y + s`.

/// A view inside a row that stays in sight while its span does: the sender's avatar beside a group of
/// messages. It rests at its place in the row (the group's last row); while that place is below the
/// visible bottom edge it is lifted to keep its bottom on that edge, but never above the top of its span.
public struct TimelinePinGeometry: Equatable, Sendable {
  /// How far the pin's resting bottom is below the visible bottom edge, with the content where it settles.
  public var overhang: CGFloat
  /// How far it can be lifted before its top meets its span's top.
  public var maxLift: CGFloat

  public init(overhang: CGFloat, maxLift: CGFloat) {
    self.overhang = overhang
    self.maxLift = maxLift
  }

  /// The pin's place, for a pin resting at `bottom` (layout y) with `height`, in a span whose top is at
  /// `spanTop` (layout y; minus infinity when the span starts above the placed rows), against `edge`
  /// (the visible bottom edge).
  public init(bottom: CGFloat, height: CGFloat, spanTop: CGFloat, edge: CGFloat) {
    overhang = bottom - edge
    maxLift = max(0, bottom - height - spanTop)
  }

  /// The lift with the content where it settles.
  public var lift: CGFloat { lift(shift: 0) }

  /// The lift with the content `shift` away from where it settles.
  public func lift(shift: CGFloat) -> CGFloat {
    max(0, min(overhang + shift, maxLift))
  }

  public func isClose(to other: TimelinePinGeometry) -> Bool {
    abs(overhang - other.overhang) < 0.01 && (maxLift == other.maxLift || abs(maxLift - other.maxLift) < 0.01)
  }
}

/// The section title that floats at the top of the usable area while the reader scrolls (the day of the
/// topmost row). A section opens with its own row (a day separator). The header shows the section of the
/// topmost visible row; when the section's own row is in sight the row shows the title itself and the header
/// hides; the next section's row pushes the header up as it reaches it.
public struct TimelineFloatingHeaderPlace<ID: Hashable & Sendable>: Equatable, Sendable {
  public var section: ID
  /// The header's top, in the layout's coordinates.
  public var y: CGFloat

  public init(section: ID, y: CGFloat) {
    self.section = section
    self.y = y
  }
}

public enum TimelineHeaderFloat {
  /// Where a header of `height` floats over `layout` with the content `shift` away from it; nil when it
  /// is hidden (no section, or the section's own row is in sight). `section` gives the row that opens the
  /// section a row belongs to (that row itself for a section's own row); `gap` is how far below the usable
  /// top the header rests. `ownInset`: where the title sits in a section's own row; the header takes the title over when
  /// it reaches the header's place (0: when the row's top does).
  public static func place<ID: Hashable & Sendable>(
    in layout: TimelineLayout<ID>, height: CGFloat, gap: CGFloat = 0, ownInset: CGFloat = 0, shift: CGFloat = 0,
    section: (ID) -> ID?
  ) -> TimelineFloatingHeaderPlace<ID>? {
    let top = layout.viewport.usableTop + gap
    let placements = layout.placements
    guard let topIndex = placements.firstIndex(where: { $0.maxY + shift > top + 1 }) else { return nil }
    let topRow = placements[topIndex]
    guard let current = section(topRow.id) else { return nil }
    // The section's own row in sight shows the title itself. When that row is the top row (it crosses the header's
    // line, its title still below), it pushes the section before it, shown until pushed wholly out (it vanished 9 pt
    // early: the `day-pill` journey).
    if let own = placements.first(where: { $0.id == current }), own.y + ownInset + shift >= top - 0.5 {
      guard own.id == topRow.id, topIndex > 0, let previous = section(placements[topIndex - 1].id), previous != current
      else { return nil }
      let y = min(top, own.y + shift - height)
      guard y + height > layout.viewport.usableTop else { return nil }
      return TimelineFloatingHeaderPlace(section: previous, y: y)
    }
    var y = top
    if let next = placements[(topIndex + 1)...].first(where: { $0.id != current && section($0.id) == $0.id }) {
      y = min(top, next.y + shift - height)
    }
    // Pushed wholly above the usable area: nothing to show.
    guard y + height > layout.viewport.usableTop else { return nil }
    return TimelineFloatingHeaderPlace(section: current, y: y)
  }

  /// `place(in:height:gap:shift:section:)` for many shifts over one layout, as a fling's samples need: each row's
  /// section is looked up once, and each shift finds the top row by binary search rather than three scans of the
  /// rows (a fling has ~300 samples; the scans made its bake cost milliseconds in the lift's frame).
  public struct Sampler<ID: Hashable & Sendable> {
    let top: CGFloat
    let usableTop: CGFloat
    let height: CGFloat
    let ownInset: CGFloat
    let ids: [ID]
    let ys: [CGFloat]
    let maxYs: [CGFloat]
    let sections: [ID?]
    /// For each row, the next row after it that opens a section (`ids.count`: none).
    let nextStart: [Int]
    /// Each section's own row: the first row with its id.
    let own: [ID: Int]
    /// Rows ordered by their bottom edge, so the top row can be found by bisection (else scanned, as `place`).
    let sorted: Bool

    public init(
      layout: TimelineLayout<ID>, height: CGFloat, gap: CGFloat = 0, ownInset: CGFloat = 0, section: (ID) -> ID?
    ) {
      top = layout.viewport.usableTop + gap
      usableTop = layout.viewport.usableTop
      self.height = height
      self.ownInset = ownInset
      let placements = layout.placements
      ids = placements.map(\.id)
      ys = placements.map(\.y)
      maxYs = placements.map(\.maxY)
      let sections = placements.map { section($0.id) }
      self.sections = sections
      var nextStart = [Int](repeating: placements.count, count: placements.count)
      var next = placements.count
      for index in placements.indices.reversed() {
        nextStart[index] = next
        if sections[index] == placements[index].id { next = index }
      }
      self.nextStart = nextStart
      var own: [ID: Int] = [:]
      own.reserveCapacity(placements.count)
      for (index, id) in ids.enumerated() where own[id] == nil { own[id] = index }
      self.own = own
      sorted = zip(maxYs, maxYs.dropFirst()).allSatisfy { $0 <= $1 }
    }

    public func place(shift: CGFloat) -> TimelineFloatingHeaderPlace<ID>? {
      let limit = top + 1 - shift
      let topIndex: Int
      if sorted {
        var low = 0
        var high = maxYs.count
        while low < high {
          let mid = (low + high) / 2
          if maxYs[mid] > limit { high = mid } else { low = mid + 1 }
        }
        guard low < maxYs.count else { return nil }
        topIndex = low
      } else {
        guard let index = maxYs.firstIndex(where: { $0 > limit }) else { return nil }
        topIndex = index
      }
      guard let current = sections[topIndex] else { return nil }
      if let ownIndex = own[current], ys[ownIndex] + ownInset + shift >= top - 0.5 {
        // As `place`: an own row across the header's line pushes the section before it out.
        guard ownIndex == topIndex, topIndex > 0, let previous = sections[topIndex - 1], previous != current
        else { return nil }
        let y = min(top, ys[ownIndex] + shift - height)
        guard y + height > usableTop else { return nil }
        return TimelineFloatingHeaderPlace(section: previous, y: y)
      }
      var y = top
      var next = nextStart[topIndex]
      while next < ids.count, ids[next] == current { next = nextStart[next] }
      if next < ids.count { y = min(top, ys[next] + shift - height) }
      guard y + height > usableTop else { return nil }
      return TimelineFloatingHeaderPlace(section: current, y: y)
    }
  }
}

/// Far jumps: the screen slides out while the destination slides in next to it, as one strip ("carousel").
public enum TimelineCarousel {
  /// Whether a row of the screen a far jump leaves slides out with it: it shows on screen. Rows placed in the
  /// margins beyond the screen go at once, so the strip that slides is what the reader saw, as on iOS (which slides a
  /// picture of the screen).
  public static func slides(_ y: CGFloat, height rowHeight: CGFloat, screen: CGFloat) -> Bool {
    y + rowHeight > 0 && y < screen
  }

  /// How far the destination starts from where it settles, positive below: its strip of placed rows starts
  /// against the edge of the rows on screen that slide out, on the side it lies on, so the two strips join with no
  /// gap and no overlap. Nil when there is nothing to slide.
  /// `towards` is the side the destination lies on when the rows cannot tell (a window that was replaced).
  public static func travel<ID: Hashable & Sendable>(
    from previous: TimelineLayout<ID>, to layout: TimelineLayout<ID>, index: TimelineRowIndex<ID>,
    towards hint: TimelineEdge?
  ) -> CGFloat? {
    let screen = previous.viewport.height
    let shown = previous.placements.filter { slides($0.y, height: $0.height, screen: screen) }
    guard let oldFirst = previous.placements.first, let newFirst = layout.placements.first,
          let newLast = layout.placements.last
    else { return nil }
    let towards: TimelineEdge = index[oldFirst.id].map { $0 < newFirst.index ? .newer : .older } ?? hint ?? .newer
    switch towards {
      case .newer:
        // Newer rows are below: the destination's top starts at the bottom of what was on screen.
        let travel = (shown.last?.maxY ?? screen) - newFirst.y
        return travel > 0 ? travel : screen
      case .older:
        // Older rows are above: the destination's bottom starts at the top of what was on screen.
        let travel = (shown.first?.y ?? 0) - newLast.maxY
        return travel < 0 ? travel : -screen
    }
  }
}

extension ScrollPath {
  /// A value that depends on where the content is, sampled along this path for an additive keyframe
  /// animation on the same clock as the content's: for each sample, `value(shift)` minus `value(0)`, where
  /// `shift` is how far the content at that sample still is from the path's end (`position - end`, negative
  /// while it has yet to travel down). `varies` is false when every sample equals the end value.
  public func follow(_ value: (CGFloat) -> CGFloat) -> (values: [CGFloat], varies: Bool) {
    let end = value(0)
    var varies = false
    let values = positions.map { position -> CGFloat in
      let delta = value(CGFloat(position - self.end)) - end
      if abs(delta) > 0.01 { varies = true }
      return delta
    }
    return (values, varies)
  }

  /// `follow` for a value that bends at known shifts (`kinks`: where a clamp starts or stops), with a sample added
  /// exactly where the path crosses each one. The content moves linearly between samples, so the crossing time is
  /// exact and linear interpolation cuts no corner. `keyTimes` (0…1 of the path's duration) is nil when no sample was
  /// added, the samples then being evenly spaced.
  public func follow(
    _ value: (CGFloat) -> CGFloat, kinks: [CGFloat]
  ) -> (values: [CGFloat], keyTimes: [Double]?, varies: Bool) {
    let kinks = kinks.filter(\.isFinite)
    guard !kinks.isEmpty else {
      let plain = follow(value)
      return (plain.values, nil, plain.varies)
    }
    let end = value(0)
    let span = Double(positions.count - 1)
    var values: [CGFloat] = []
    var times: [Double] = []
    values.reserveCapacity(positions.count + kinks.count)
    times.reserveCapacity(positions.count + kinks.count)
    var varies = false
    var added = false
    func add(_ shift: CGFloat, at time: Double) {
      let delta = value(shift) - end
      if abs(delta) > 0.01 { varies = true }
      values.append(delta)
      times.append(time)
    }
    var previous: CGFloat?
    for (index, position) in positions.enumerated() {
      let shift = CGFloat(position - self.end)
      if let previous, previous != shift {
        let crossed = kinks.filter { ($0 - previous) * ($0 - shift) < 0 }
          .sorted { previous < shift ? $0 < $1 : $0 > $1 }
        for kink in crossed {
          let fraction = Double((kink - previous) / (shift - previous))
          add(kink, at: (Double(index - 1) + fraction) / span)
          added = true
        }
      }
      add(shift, at: span > 0 ? Double(index) / span : 0)
      previous = shift
    }
    return (values, added ? times : nil, varies)
  }
}

extension TimelineTiming {
  /// How much of a track with this timing remains `time` seconds after it starts: 1 at the start, 0 once it ends.
  /// A track goes from its delta to zero, so what shows is `delta × remaining`. Springs start at rest (Core
  /// Animation's `CASpringAnimation` with no initial velocity) and are cut at their duration, as the animation is.
  public func remaining(at time: Double) -> Double {
    guard time > 0 else { return 1 }
    switch self {
      case .none:
        return 0
      case let .spring(mass, stiffness, damping, duration):
        guard time < Double(duration) else { return 0 }
        let m = Double(mass), k = Double(stiffness), c = Double(damping)
        let omega = (k / m).squareRoot()
        let zeta = c / (2 * (k * m).squareRoot())
        if abs(zeta - 1) < 1e-6 {
          return (1 + omega * time) * exp(-omega * time)
        } else if zeta < 1 {
          let damped = omega * (1 - zeta * zeta).squareRoot()
          return exp(-zeta * omega * time) * (cos(damped * time) + zeta * omega / damped * sin(damped * time))
        } else {
          let root = (zeta * zeta - 1).squareRoot()
          let r1 = -omega * (zeta - root)
          let r2 = -omega * (zeta + root)
          return (r2 * exp(r1 * time) - r1 * exp(r2 * time)) / (r2 - r1)
        }
      case let .curve(duration, c1x, c1y, c2x, c2y):
        guard time < Double(duration) else { return 0 }
        return 1 - Self.bezier(x: time / Double(duration), Double(c1x), Double(c1y), Double(c2x), Double(c2y))
    }
  }

  /// About how sharply `remaining` bends, at most (per second squared): what sets how often a value following it must be
  /// sampled for linear interpolation to stay close. A spring's ω² (its start); a curve's, estimated for its duration.
  public var curvature: Double {
    switch self {
      case .none: 0
      case let .spring(mass, stiffness, _, _): Double(stiffness / mass)
      case let .curve(duration, _, _, _, _): 12 / max(1e-3, Double(duration * duration))
    }
  }

  /// The sampling interval that keeps linear interpolation within `tolerance` points of a value moving `amplitude`
  /// points along this timing, between 120 and 960 samples a second.
  public func interval(amplitude: CGFloat, tolerance: Double = 0.1) -> Double {
    let bend = Double(abs(amplitude)) * curvature
    guard bend > 0 else { return 1.0 / 120 }
    return min(1.0 / 120, max(1.0 / 960, (8 * tolerance / bend).squareRoot()))
  }

  /// A cubic Bézier timing function from (0, 0) to (1, 1) with these control points, at `x`.
  static func bezier(x: Double, _ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) -> Double {
    func coordinate(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
      let v = 1 - u
      return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
    }
    var low = 0.0, high = 1.0, u = x
    for _ in 0 ..< 40 {
      let value = coordinate(u, c1x, c2x)
      if abs(value - x) < 1e-9 { break }
      if value < x { low = u } else { high = u }
      u = (low + high) / 2
    }
    return coordinate(u, c1y, c2y)
  }

  /// A value that depends on how much of this timing's motion remains (`value(q)`, q from 1 at the start to 0 at the
  /// end), sampled every `interval` over the duration as an additive keyframe track (960 Hz: a stiff spring bends
  /// enough between 240 Hz samples for a point of error on a long slide): each sample is `value(q) −
  /// value(0)`. `kinks` are the q values where `value` bends (a clamp's ends); a sample is added exactly where the
  /// motion crosses each, so linear interpolation cuts no corner. Every part of an animated change moves on the same
  /// timing, so a sticky thing that depends on where rows are follows them exactly.
  public func follow(
    interval: Double = 1.0 / 960, kinks: [Double] = [], _ value: (Double) -> CGFloat
  ) -> (values: [CGFloat], keyTimes: [Double], varies: Bool) {
    let duration = seconds
    guard duration > 0 else { return ([0], [0], false) }
    let end = value(0)
    let count = max(1, Int((duration / interval).rounded(.up)))
    let step = duration / Double(count)
    let kinks = kinks.filter { $0.isFinite && $0 > 0 && $0 < 1 }
    var values: [CGFloat] = []
    var times: [Double] = []
    var varies = false
    func add(_ q: Double, at time: Double) {
      let delta = value(q) - end
      if abs(delta) > 0.01 { varies = true }
      values.append(delta)
      times.append(min(1, time / duration))
    }
    var previous = (time: 0.0, q: 1.0)
    add(1, at: 0)
    for index in 1 ... count {
      let time = index == count ? duration : Double(index) * step
      let q = index == count ? 0 : remaining(at: time)
      for kink in kinks where (kink - previous.q) * (kink - q) < 0 {
        // The motion crosses the kink between the two samples: find when, by bisection.
        var low = previous.time, high = time
        for _ in 0 ..< 40 {
          let mid = (low + high) / 2
          if (remaining(at: mid) - kink) * (previous.q - kink) > 0 { low = mid } else { high = mid }
        }
        add(kink, at: (low + high) / 2)
      }
      add(q, at: time)
      previous = (time, q)
    }
    return (values, times, varies)
  }

  /// How long a track with this timing runs, in seconds.
  fileprivate var seconds: Double {
    switch self {
      case .none: 0
      case let .spring(_, _, _, duration): Double(duration)
      case let .curve(duration, _, _, _, _): Double(duration)
    }
  }
}
