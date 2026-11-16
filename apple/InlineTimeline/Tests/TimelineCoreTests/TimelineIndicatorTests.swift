import CoreGraphics
import Testing
@testable import TimelineCore

@Suite struct TimelineIndicatorTests {
  private typealias Extent = TimelineIndicator.Extent

  @Test func `the estimate is the share of the travel above`() {
    #expect(TimelineIndicator.estimate(Extent(above: 300, below: 100, visible: 500)) == 0.75)
    #expect(TimelineIndicator.estimate(Extent(above: 0, below: 400, visible: 500)) == 0)
    // Nothing to travel: at the newest end, where the list rests.
    #expect(TimelineIndicator.estimate(Extent(above: 0, below: 0, visible: 500)) == 1)
  }

  @Test func `the thumb reaches an end exactly when the content does`() {
    let extent = Extent(above: 1_000, below: 200, visible: 500)
    #expect(TimelineIndicator.progress(0.6, extent: extent, moved: 1_000) == 0)
    #expect(TimelineIndicator.progress(0.6, extent: extent, moved: 500) == 0.3)
    #expect(abs(TimelineIndicator.progress(0.6, extent: extent, moved: -200) - 1) < 1e-9)
    #expect(abs(TimelineIndicator.progress(0.6, extent: extent, moved: -100) - 0.8) < 1e-9)
    // Past an end (a rubber band) it stays there.
    #expect(TimelineIndicator.progress(0.6, extent: extent, moved: 1_400) == 0)
    #expect(TimelineIndicator.progress(0.6, extent: extent, moved: -300) == 1)
  }

  @Test func `moving in steps is moving at once while the estimate holds`() {
    var indicator = TimelineIndicator(progress: 0.7)
    var extent = Extent(above: 2_000, below: 600, visible: 500)
    for _ in 0 ..< 10 {
      indicator.move(by: 120, extent: extent)
      extent = Extent(above: extent.above - 120, below: extent.below + 120, visible: 500)
    }
    let direct = TimelineIndicator.progress(0.7, extent: Extent(above: 2_000, below: 600, visible: 500), moved: 1_200)
    #expect(abs(indicator.progress - direct) < 1e-9)
  }

  @Test func `a page of history arriving changes the pace, not the place`() {
    var indicator = TimelineIndicator(progress: 0.2)
    // The page prepends: much more above, the thumb stays where it is.
    let before = indicator.progress
    let grown = Extent(above: 3_000, below: 4_000, visible: 500)
    #expect(indicator.progress == before)
    // Further up, it moves up, more slowly, and still meets the top with the content.
    indicator.move(by: 1_500, extent: grown)
    #expect(abs(indicator.progress - 0.1) < 1e-9)
    indicator.move(by: 1_500, extent: Extent(above: 1_500, below: 5_500, visible: 500))
    #expect(indicator.progress == 0)
  }

  @Test func `the thumb never moves against the scroll whatever the estimate does`() {
    var indicator = TimelineIndicator(progress: 0.5)
    var last = indicator.progress
    // Estimates that wander (rows measured, pages arriving) while the content moves up the history.
    let aboves: [CGFloat] = [800, 2_400, 300, 5_000, 90, 6_000, 10]
    for above in aboves {
      indicator.move(by: 40, extent: Extent(above: above, below: 700, visible: 500))
      #expect(indicator.progress <= last)
      last = indicator.progress
    }
    for below in [50, 900, 30, 4_000] as [CGFloat] {
      indicator.move(by: -25, extent: Extent(above: 500, below: below, visible: 500))
      #expect(indicator.progress >= last)
      last = indicator.progress
    }
  }

  @Test func `the length is the visible share of the track, with a minimum`() {
    #expect(TimelineIndicator.length(Extent(above: 500, below: 500, visible: 500), track: 600, minimum: 36) == 200)
    #expect(TimelineIndicator.length(Extent(above: 50_000, below: 0, visible: 500), track: 600, minimum: 36) == 36)
    #expect(TimelineIndicator.length(Extent(above: 0, below: 0, visible: 500), track: 600, minimum: 36) == 600)
  }

  @Test func `a layout's extent is exact at a placed end and estimated with the mean row beyond`() {
    var state = TimelineState<Int>(
      viewport: TimelineViewport(width: 320, height: 600, topInset: 50, bottomInset: 60),
      margins: TimelineMargins(above: 100, below: 100)
    )
    state.apply(TimelineUpdate(rows: Array(0 ..< 1_000), coverage: TimelineCoverage(), scroll: .latest)) { _ in 50 }
    let layout = state.layout
    let extent = layout.indicatorExtent(rowCount: 1_000, coverage: TimelineCoverage(), unknown: 0)
    #expect(extent.below == 0)
    #expect(extent.visible == 490)
    // 1,000 rows of 50 pt with 490 pt shown.
    #expect(abs(extent.above - (50_000 - 490)) < 0.001)
    // History the loaded rows do not reach adds the unknown allowance.
    let open = layout.indicatorExtent(
      rowCount: 1_000, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true), unknown: 980
    )
    #expect(abs(open.above - (50_000 - 490 + 980)) < 0.001)
    #expect(open.below == 0)
  }
}
