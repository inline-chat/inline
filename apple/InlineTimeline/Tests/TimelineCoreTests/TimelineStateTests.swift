import CoreGraphics
import Testing
@testable import TimelineCore

/// Rows are integers; a row's height comes from a table the test can change.
private struct Fixture {
  var state: TimelineState<Int>
  var heights: [Int: CGFloat] = [:]
  var defaultHeight: CGFloat = 50
  var heightCalls = 0

  init(viewport: TimelineViewport = TimelineViewport(width: 320, height: 600, topInset: 50, bottomInset: 60)) {
    state = TimelineState(viewport: viewport, margins: TimelineMargins(above: 100, below: 100))
  }

  @discardableResult
  mutating func apply(_ update: TimelineUpdate<Int>) -> TimelineChange<Int> {
    let heights = heights
    let fallback = defaultHeight
    var calls = 0
    let change = state.apply(update) { id in
      calls += 1
      return heights[id] ?? fallback
    }
    heightCalls += calls
    return change
  }

  func y(_ id: Int) -> CGFloat? { state.layout.placement(for: id)?.y }
  func maxY(_ id: Int) -> CGFloat? { state.layout.placement(for: id)?.maxY }
}

private func checkInvariants(_ layout: TimelineLayout<Int>, rows: [Int], sourceLocation: SourceLocation = #_sourceLocation) {
  let placements = layout.placements
  guard !rows.isEmpty else {
    #expect(placements.isEmpty, sourceLocation: sourceLocation)
    return
  }
  #expect(!placements.isEmpty, sourceLocation: sourceLocation)
  for (previous, next) in zip(placements, placements.dropFirst()) {
    #expect(next.index == previous.index + 1, sourceLocation: sourceLocation)
    #expect(abs(next.y - previous.maxY) < 0.001, sourceLocation: sourceLocation)
  }
  guard let first = placements.first, let last = placements.last else { return }
  // The usable area is covered unless the loaded rows end.
  if first.index > 0 { #expect(first.y <= layout.viewport.usableTop, sourceLocation: sourceLocation) }
  if last.index < rows.count - 1 { #expect(last.maxY >= layout.viewport.usableBottom, sourceLocation: sourceLocation) }
}

@Suite struct TimelineStateTests {
  @Test func `the span of the lowest visible row stays placed to its end, within the span margin`() {
    var state = TimelineState<Int>(
      viewport: TimelineViewport(width: 320, height: 600, topInset: 50, bottomInset: 60),
      margins: TimelineMargins(above: 100, below: 100, span: 1_000)
    )
    let rows = Array(0 ..< 200)
    // Row 10 sits at the bottom of the usable area; its span runs to row 30 (20 rows, 1,000 pt below).
    state.apply(.init(rows: rows, scroll: .to(10, .bottom(0))), spanEnd: { $0 >= 5 && $0 < 30 ? 30 : nil }) { _ in 50 }
    #expect(state.layout.placement(for: 30) != nil)
    #expect(state.layout.placement(for: 31) == nil)
    let placements = state.layout.placements
    for (previous, next) in zip(placements, placements.dropFirst()) {
      #expect(next.index == previous.index + 1)
    }
    // A span ending beyond the span margin places nothing extra.
    state.apply(.init(scroll: .to(10, .bottom(0))), spanEnd: { $0 >= 5 && $0 < 100 ? 100 : nil }) { _ in 50 }
    #expect(state.layout.placement(for: 100) == nil)
    #expect((state.layout.placements.last?.maxY ?? 0) <= 600 + 100 + 50)
    // Without a span, the usual margins.
    state.apply(.init(scroll: .to(10, .bottom(0)))) { _ in 50 }
    #expect(state.layout.placement(for: 30) == nil)
  }

  @Test func `latest rests the newest row on the usable bottom and places only the window`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 10_000), scroll: .latest))
    #expect(fixture.maxY(9_999) == 540)
    #expect(fixture.state.layout.position == .latest)
    #expect(fixture.state.layout.isAtBottom)
    #expect(fixture.state.layout.distanceToNewest == 0)
    #expect(fixture.state.layout.distanceToOldest == nil)
    // 600 pt of viewport and 100 pt margins at 50 pt a row: far fewer than the 10,000 rows.
    #expect(fixture.state.layout.placements.count < 20)
    #expect(fixture.heightCalls < 40)
    checkInvariants(fixture.state.layout, rows: fixture.state.rows)
  }

  @Test func `content shorter than the usable area rests on the bottom`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: [1, 2, 3], scroll: .latest))
    #expect(fixture.maxY(3) == 540)
    #expect(fixture.y(1) == 390)
    // It cannot be scrolled.
    fixture.apply(.init(scroll: .by(200)))
    #expect(fixture.y(1) == 390)
    fixture.apply(.init(scroll: .by(-200)))
    #expect(fixture.y(1) == 390)
  }

  @Test func `a message arriving while pinned moves the whole block up by its height`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .latest))
    fixture.heights[100] = 80
    let change = fixture.apply(.init(rows: Array(0 ... 100)))
    #expect(fixture.maxY(100) == 540)
    #expect(change.inserted == [100])
    #expect(change.uniformOffset == 80)
    #expect(change.offsets[100] == 80)
    #expect(change.offsets[99] == 80)
    #expect(change.removed.isEmpty)
  }

  @Test func `an older page arriving above a reading row moves nothing`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(100 ..< 200), coverage: .init(reachesOldest: false), scroll: .to(150, .top(20))))
    let before = fixture.state.layout.placements
    #expect(fixture.y(150) == 70)
    let change = fixture.apply(.init(rows: Array(0 ..< 200)))
    #expect(fixture.y(150) == 70)
    for placement in before { #expect(fixture.y(placement.id) == placement.y) }
    #expect(!change.movesAnything)
    #expect(change.inserted.isEmpty)
  }

  @Test func `a message arriving while reading history moves nothing on screen`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .to(50, .top(0))))
    let change = fixture.apply(.init(rows: Array(0 ... 100)))
    #expect(fixture.y(50) == 50)
    #expect(change.uniformOffset == nil)
    #expect(!change.movesAnything)
  }

  @Test func `the keyboard opening moves a pinned list and a reading row by the inset change`() {
    var pinned = Fixture()
    pinned.apply(.init(rows: Array(0 ..< 100), scroll: .latest))
    var viewport = pinned.state.viewport
    viewport.bottomInset += 300
    let change = pinned.apply(.init(viewport: viewport))
    #expect(pinned.maxY(99) == 240)
    #expect(change.uniformOffset == 300)

    var reading = Fixture()
    reading.apply(.init(rows: Array(0 ..< 100), scroll: .to(50, .top(100))))
    #expect(reading.y(50) == 150)
    let before = reading.y(56)
    let readingChange = reading.apply(.init(viewport: viewport))
    #expect(reading.y(56) == before.map { $0 - 300 })
    #expect(readingChange.uniformOffset == 300)
    // Closing brings it back exactly.
    viewport.bottomInset -= 300
    reading.apply(.init(viewport: viewport))
    #expect(reading.y(50) == 150)
  }

  @Test func `content under a finger does not follow the keyboard`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .to(50, .top(100))))
    var viewport = fixture.state.viewport
    viewport.bottomInset += 300
    let change = fixture.apply(.init(viewport: viewport, followsBottomInset: false, pinsWhenAtBottom: false))
    #expect(fixture.y(50) == 150)
    #expect(!change.movesAnything)
  }

  @Test func `a streamed message growing while pinned keeps its bottom and reports the old height`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .latest))
    fixture.heights[99] = 72
    let change = fixture.apply(.init())
    #expect(fixture.maxY(99) == 540)
    #expect(change.previousHeights == [99: 50])
    #expect(change.offsets[98] == 22)
    #expect(change.offsets[99] == 22)
  }

  @Test func `a row changing height above the reading row leaves it in place`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .to(50, .top(100))))
    fixture.heights[49] = 120
    let change = fixture.apply(.init())
    // The reading row is the lowest visible one; a row growing above it pushes older rows up.
    let anchor = fixture.state.layout.position
    #expect(fixture.y(50) == 150)
    #expect(change.offsets[48] == 70)
    #expect(change.offsets[50] == 0)
    #expect(change.offsets[51] == 0)
    #expect(change.previousHeights[49] == 50)
    #expect(anchor != .latest)
  }

  @Test func `deleting the reading row hands its place to the next row`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .to(50, .top(0))))
    guard case let .row(reading, top) = fixture.state.layout.position else {
      Issue.record("expected a reading row")
      return
    }
    // The lowest visible row: its top is above the usable bottom, its bottom at or below it.
    #expect(top < 540 && top + 50 >= 540)
    let nextY = fixture.y(reading + 1)
    var rows = Array(0 ..< 100)
    rows.removeAll { $0 == reading }
    let change = fixture.apply(.init(rows: rows))
    #expect(fixture.y(reading + 1) == nextY)
    #expect(change.removed.map(\.id) == [reading])
    // Rows above close the gap by moving down.
    #expect(change.offsets[reading - 1] == -50)
  }

  @Test func `scrolling stops at the loaded ends unless overscroll is allowed`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 30), scroll: .latest))
    fixture.apply(.init(scroll: .by(5_000)))
    #expect(fixture.y(0) == 50)
    #expect(fixture.state.layout.distanceToOldest == 0)
    #expect(fixture.state.layout.restShift == 0)

    fixture.apply(.init(scroll: .by(40), allowsOverscroll: true))
    #expect(fixture.y(0) == 90)
    #expect(fixture.state.layout.restShift == -40)

    fixture.apply(.init(scroll: .by(-10_000)))
    #expect(fixture.maxY(29) == 540)
    #expect(fixture.state.layout.isAtBottom)
  }

  @Test func `scrolling a pinned list keeps pinning off until it rests on the bottom again`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 100), scroll: .latest))
    fixture.apply(.init(scroll: .by(120), pinsWhenAtBottom: false))
    #expect(fixture.maxY(99) == 660)
    #expect(fixture.state.layout.position != .latest)
    #expect(!fixture.state.layout.isAtBottom)
    // A message arriving now does not move the reader.
    let top = fixture.state.layout.placements[0]
    fixture.apply(.init(rows: Array(0 ... 100)))
    #expect(fixture.y(top.id) == top.y)
    // Back at the bottom, the next arrival is followed.
    fixture.apply(.init(scroll: .by(-10_000), pinsWhenAtBottom: false))
    #expect(fixture.state.layout.isAtBottom)
    fixture.apply(.init(rows: Array(0 ... 101)))
    #expect(fixture.maxY(101) == 540)
    #expect(fixture.state.layout.position == .latest)
  }

  @Test func `a jump to a far row is disjoint and lands where asked`() {
    var fixture = Fixture()
    fixture.apply(.init(rows: Array(0 ..< 10_000), scroll: .latest))
    fixture.heights[5_000] = 90
    let change = fixture.apply(.init(scroll: .to(5_000, .center)))
    #expect(change.isDisjoint)
    #expect(fixture.y(5_000) == 250, "placements: \(fixture.state.layout.placements.map { "\($0.id)@\($0.y)+\($0.height)" })")
    checkInvariants(fixture.state.layout, rows: fixture.state.rows)
  }

  @Test func `history is demanded near a loaded end that is not a real end`() {
    var fixture = Fixture()
    let change = fixture.apply(.init(rows: Array(0 ..< 100), coverage: .init(reachesOldest: false, reachesNewest: true),
                                     scroll: .to(5, .top(0))))
    #expect(change.demands == [.older])
    let none = fixture.apply(.init(coverage: .init(reachesOldest: true, reachesNewest: true)))
    #expect(none.demands.isEmpty)
  }

  @Test func `a width change that changes every height keeps the reading row and the pinned bottom`() {
    var reading = Fixture()
    reading.apply(.init(rows: Array(0 ..< 100), scroll: .to(50, .top(30))))
    guard case let .row(row, top) = reading.state.layout.position else {
      Issue.record("expected a reading row")
      return
    }
    let distance = reading.state.viewport.usableBottom - top
    reading.defaultHeight = 35
    var viewport = TimelineViewport(width: 600, height: 320, topInset: 40, bottomInset: 60)
    reading.apply(.init(viewport: viewport))
    // The lowest visible row keeps its distance from the usable bottom.
    #expect(reading.y(row) == viewport.usableBottom - distance)

    var pinned = Fixture()
    pinned.apply(.init(rows: Array(0 ..< 100), scroll: .latest))
    pinned.defaultHeight = 35
    viewport.bottomInset = 200
    pinned.apply(.init(viewport: viewport))
    #expect(pinned.maxY(99) == 120)
  }

  @Test func `random updates keep the layout contiguous, covering and inside its limits`() {
    for seed in 1 ... 12 {
      var generator = SplitMix(seed: UInt64(seed))
      var fixture = Fixture()
      var rows = Array(0 ..< 400)
      var next = 400
      fixture.apply(.init(rows: rows, scroll: .latest))
      for _ in 0 ..< 400 {
        switch generator.next() % 9 {
          case 0:
            rows.append(next); next += 1
            fixture.heights[next - 1] = CGFloat(20 + generator.next() % 200)
            fixture.apply(.init(rows: rows))
          case 1:
            if rows.count > 5 { rows.remove(at: Int(generator.next() % UInt64(rows.count))) }
            fixture.apply(.init(rows: rows))
          case 2:
            let id = rows[Int(generator.next() % UInt64(rows.count))]
            fixture.heights[id] = CGFloat(20 + generator.next() % 300)
            fixture.apply(.init())
          case 3:
            var viewport = fixture.state.viewport
            viewport.bottomInset = CGFloat(60 + generator.next() % 340)
            fixture.apply(.init(viewport: viewport))
          case 4:
            let landscape = generator.next() % 2 == 0
            fixture.defaultHeight = landscape ? 35 : 50
            fixture.apply(.init(viewport: TimelineViewport(
              width: landscape ? 600 : 320, height: landscape ? 320 : 600, topInset: landscape ? 40 : 50,
              bottomInset: fixture.state.viewport.bottomInset.clamped(to: 0 ... 200)
            )))
          case 5:
            fixture.apply(.init(scroll: .to(rows[Int(generator.next() % UInt64(rows.count))], .center)))
          case 6:
            fixture.apply(.init(scroll: .latest))
          default:
            fixture.apply(.init(scroll: .by(CGFloat(Int(generator.next() % 1_200) - 600)), pinsWhenAtBottom: false))
        }
        checkInvariants(fixture.state.layout, rows: rows)
        #expect(abs(fixture.state.layout.restShift) < 0.001)
        if fixture.state.layout.position == .latest, let last = fixture.state.layout.placements.last {
          #expect(last.id == rows.last)
          #expect(abs(last.maxY - fixture.state.viewport.usableBottom) < 0.001)
        }
      }
    }
  }
}

private struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
