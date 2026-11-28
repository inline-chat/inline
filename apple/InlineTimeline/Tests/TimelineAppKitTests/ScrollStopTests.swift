#if os(macOS)
import AppKit
import Testing
@testable import TimelineAppKit
import TimelineCore

/// Stops and the scroll callbacks, on a list with no window (nothing shows, nothing takes focus).
@MainActor
@Suite("Scroll stops")
struct ScrollStopTests {
  func makeList(rows count: Int = 60) -> (TimelineListView<Int>, Counts) {
    let list = TimelineListView<Int>(rows: TimelineRows(
      height: { _, _ in 50 },
      make: { _, _ in NSView() }
    ))
    list.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
    list.layoutSubtreeIfNeeded()
    list.apply(TimelineTransaction(rows: Array(0 ..< count), coverage: TimelineCoverage(), scroll: .latest))
    let counts = Counts()
    list.onScrollBegan = { counts.began += 1 }
    list.onScrollEnded = { counts.ended += 1 }
    return (list, counts)
  }

  final class Counts {
    var began = 0
    var ended = 0
  }

  func wheel(_ dy: Int32) -> NSEvent {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
    return NSEvent(cgEvent: cg)!
  }

  @Test("A series of wheel notches reports one began and one end")
  func wheelSeriesIsBalanced() async throws {
    let (list, counts) = makeList()
    for _ in 0 ..< 5 { list.scrollWheel(with: wheel(12)) }
    #expect(counts.began == 1)
    try await Task.sleep(for: .milliseconds(450))
    #expect(counts.ended == 1)
    // A later series is a new scroll.
    list.scrollWheel(with: wheel(12))
    #expect(counts.began == 2)
  }

  @Test("A stop during a bounce past an end returns to the end, never snaps")
  func stopPastAnEndReturns() async throws {
    let (list, counts) = makeList()
    // At the newest end, thrown further towards it: the content overshoots, then settles.
    list.fling(velocity: -3_000)
    #expect(list.flight != nil)
    try await Task.sleep(for: .milliseconds(60))
    list.stopScrolling()
    // Stopped past the end where it showed: a return runs from there (it once stayed there, or snapped).
    #expect(abs(list.state.layout.restShift) > 0.25)
    #expect(list.flight != nil)
    #expect(counts.ended == 0)
  }

  @Test("A stop inside the ends rests there and reports it")
  func stopInsideRests() async throws {
    let (list, counts) = makeList()
    list.fling(velocity: 2_000)
    try await Task.sleep(for: .milliseconds(60))
    list.stopScrolling()
    #expect(list.flight == nil)
    #expect(abs(list.state.layout.restShift) < 0.26)
    #expect(counts.ended == 1)
  }

  @Test("Stopping a list at rest reports nothing")
  func stopAtRestIsQuiet() {
    let (list, counts) = makeList()
    list.stopScrolling()
    #expect(counts.began == 0)
    #expect(counts.ended == 0)
  }
}
#endif
