#if os(macOS)
import Foundation
import Testing
@testable import TimelineAppKit
import TimelineCore

@MainActor
@Suite("Moved rows")
struct MovedRowsTests {
  @Test("Rows in order: nothing moved")
  func inOrder() {
    #expect(TimelineListView<Int>.outOfOrder([0, 1, 2, 5, 9]).isEmpty)
    #expect(TimelineListView<Int>.outOfOrder([3], weights: [40]).isEmpty)
  }

  @Test("A row moved past several: only it is out of the run")
  func oneMovedFar() {
    // Old ranks in new order: the row that was 4th now comes first.
    #expect(TimelineListView<Int>.outOfOrder([4, 0, 1, 2, 3]) == [0])
    #expect(TimelineListView<Int>.outOfOrder([4, 0, 1, 2, 3], weights: [40, 40, 40, 40, 40]) == [0])
  }

  @Test("A swap of equal rows: the later one stays, as before the weights")
  func equalSwap() {
    // [X, I, P] from [X, P, I]: the pending one (P) stays in the run, the incoming one lands.
    #expect(TimelineListView<Int>.outOfOrder([0, 2, 1]) == [1])
    #expect(TimelineListView<Int>.outOfOrder([0, 2, 1], weights: [50, 42, 42]) == [1])
  }

  @Test("A swap of a tall row and a short one: the short one lands, the tall one keeps its place")
  func weightedSwap() {
    // New order 122, 120, 124 from 120, 122, 124: by count either could move; by height the 36 pt row does.
    #expect(TimelineListView<Int>.outOfOrder([1, 0, 2], weights: [212, 36, 52]) == [1])
    #expect(TimelineListView<Int>.outOfOrder([1, 0, 2], weights: [36, 212, 52]) == [0])
  }

  @Test("Several short rows moving past one tall row: the tall one moves")
  func manyShortPastTall() {
    // The tall row (old rank 0) now comes after three short ones: moving it is less height than moving all three.
    #expect(TimelineListView<Int>.outOfOrder([1, 2, 3, 0], weights: [30, 30, 30, 60]) == [3])
    // Taller than all three together: they move instead.
    #expect(TimelineListView<Int>.outOfOrder([1, 2, 3, 0], weights: [30, 30, 30, 200]) == [0, 1, 2])
  }
}
#endif
