import CoreGraphics
@testable import InlineIOSUI
import Testing

@Suite("Message list v2 exact geometry")
struct MessageListGeometryV2Tests {
  private func geometry(_ items: [(Int64, CGFloat)], viewport: CGFloat = 100) throws -> MessageListGeometryV2 {
    try #require(MessageListGeometryV2(
      items: items.map { .init(id: $0.0, height: $0.1) },
      width: 320,
      viewportHeight: viewport,
      spacing: 0,
      padding: 0
    ))
  }

  @Test func shortHistoryAlignsToBottomWithoutSyntheticRows() throws {
    let plan = try geometry([(1, 20), (2, 30)])
    #expect(plan.rows.map(\.frame.minY) == [50, 70])
    #expect(plan.contentSize.height == 100)
    #expect(plan.maximumOffsetY == 0)
    #expect(plan.isFollowingBottom(at: 0))
    #expect(try geometry([]).rows.isEmpty)
  }

  @Test func prependingHistoryPreservesTheSameReadingPoint() throws {
    let old = try geometry([(1, 80), (2, 80), (3, 80)])
    let anchor = try #require(old.anchor(at: 95))
    let next = try geometry([(0, 70), (1, 80), (2, 80), (3, 80)])
    let offset = next.offset(preserving: anchor, from: old)
    #expect(anchor.id == 2)
    #expect(offset == 165)
    #expect(try #require(next.frame(for: 2)).minY + anchor.localY - offset == anchor.viewportY)
  }

  @Test func changedHeightAboveAnchorAndNewIncomingRowDoNotPullReadingPosition() throws {
    let old = try geometry([(1, 80), (2, 80), (3, 80)])
    let anchor = try #require(old.anchor(at: 95))
    let next = try geometry([(1, 110), (2, 80), (3, 80), (4, 100)])
    #expect(next.offset(preserving: anchor, from: old) == 125)
    #expect(!old.isFollowingBottom(at: 40))
    #expect(old.isFollowingBottom(at: old.maximumOffsetY - 44))
  }

  @Test func deletingAnchorPrefersNewerSurvivorAtItsPreviousPosition() throws {
    let old = try geometry([(1, 80), (2, 80), (3, 80), (4, 80)])
    let anchor = try #require(old.anchor(at: 95))
    let next = try geometry([(1, 80), (3, 80), (4, 80)])
    let offset = next.offset(preserving: anchor, from: old)
    #expect(offset == 15)
    #expect(try #require(next.frame(for: 3)).minY - offset == 65)
  }

  @Test func deletedTailFallsBackToOlderRowAndClampsToNewExtent() throws {
    let old = try geometry([(1, 100), (2, 100), (3, 100)])
    let anchor = try #require(old.anchor(at: 220))
    let next = try geometry([(1, 100), (2, 100)])
    #expect(next.offset(preserving: anchor, from: old) == 100)
    #expect(try geometry([]).offset(preserving: anchor, from: old) == 0)
  }

  @Test func viewportResizeKeepsAnchorWhileFollowingUsesNewBottom() throws {
    let old = try geometry([(1, 100), (2, 100), (3, 100)])
    let anchor = try #require(old.anchor(at: 120))
    let next = try geometry([(1, 100), (2, 100), (3, 100)], viewport: 60)
    #expect(next.offset(preserving: anchor, from: old) == 120)
    #expect(next.maximumOffsetY == 240)
  }

  @Test func frameQueriesReturnOnlyIntersectingRowsAtExactBoundaries() throws {
    let plan = try geometry([(1, 50), (2, 50), (3, 50), (4, 50)])
    #expect(plan.indices(intersecting: CGRect(x: 0, y: 50, width: 320, height: 100)) == 1 ..< 3)
    #expect(plan.indices(intersecting: CGRect(x: 0, y: 500, width: 320, height: 100)).isEmpty)
    #expect(plan.indices(intersecting: .zero).isEmpty)
  }

  @Test func invalidOrDuplicateGeometryCannotReachTheCollection() {
    #expect(MessageListGeometryV2(items: [.init(id: 1, height: .nan)], width: 320, viewportHeight: 100) == nil)
    #expect(MessageListGeometryV2(items: [.init(id: 1, height: 0)], width: 320, viewportHeight: 100) == nil)
    #expect(MessageListGeometryV2(
      items: [.init(id: 1, height: 20), .init(id: 1, height: 30)],
      width: 320,
      viewportHeight: 100
    ) == nil)
    #expect(MessageListGeometryV2(items: [], width: 0, viewportHeight: 100) == nil)
  }

  @Test func heightsArePixelAlignedAndIdentityDoesNotDependOnPosition() throws {
    let plan = try #require(MessageListGeometryV2(
      items: [.init(id: -4, height: 10.1), .init(id: 99, height: 20.2)],
      width: 320, viewportHeight: 10, spacing: 0, padding: 0, displayScale: 3
    ))
    #expect(plan.rows[0].frame.height == 31.0 / 3)
    #expect(plan.rows[1].frame.height == 61.0 / 3)
    #expect(plan.index(for: -4) == 0)
    #expect(plan.frame(for: 99) == plan.rows[1].frame)
  }

  @Test func bounceAndInvalidThresholdsDoNotDetachAShortList() throws {
    let plan = try geometry([(1, 30)])
    #expect(plan.isFollowingBottom(at: -60))
    #expect(plan.isFollowingBottom(at: 60))
    #expect(!plan.isFollowingBottom(at: .nan))
    #expect(!plan.isFollowingBottom(at: 0, threshold: -1))
    #expect(!plan.isFollowingBottom(at: 0, threshold: .infinity))
  }

  @Test func pixelRoundingOverflowCannotCreateInfiniteFrames() {
    #expect(MessageListGeometryV2(
      items: [.init(id: 1, height: .greatestFiniteMagnitude)],
      width: 320,
      viewportHeight: 100,
      displayScale: 3
    ) == nil)
    #expect(MessageListGeometryV2(
      items: [.init(id: 1, height: 1)],
      width: 320,
      viewportHeight: 100,
      displayScale: .leastNonzeroMagnitude
    ) == nil)
    #expect(MessageListGeometryV2(items: [], width: 320, viewportHeight: .infinity) == nil)
    #expect(MessageListGeometryV2(items: [], width: 320, viewportHeight: 100, spacing: -1) == nil)
  }

  @Test func fractionalAnchorInSpacingPreservesTheFollowingRowPosition() throws {
    let old = try #require(MessageListGeometryV2(
      items: [.init(id: 1, height: 50), .init(id: 2, height: 100)],
      width: 320,
      viewportHeight: 50,
      spacing: 4,
      padding: 0
    ))
    let anchor = try #require(old.anchor(at: 51.5))
    #expect(anchor.id == 2)
    #expect(anchor.viewportY == 2.5)
    let next = try #require(MessageListGeometryV2(
      items: [.init(id: 1, height: 60.1), .init(id: 2, height: 100)],
      width: 320,
      viewportHeight: 50,
      spacing: 4,
      padding: 0,
      displayScale: 3
    ))
    #expect(abs(next.offset(preserving: anchor, from: old) - (61.5 + 1.0 / 3)) < 0.0001)
  }
}
