// Uses the production pagination state without an app, account, or simulator.
// xcrun swiftc -parse-as-library apple/InlineIOS/Features/Chat/OlderHistoryPagination.swift \
//   scripts/ios/check-older-history-pagination.swift -o /tmp/inline-older-history-check
import Foundation

@main
@MainActor
private struct OlderHistoryPaginationChecks {
  private static var checks = 0

  private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
  }

  private static func near(_ offset: CGFloat, height: CGFloat = 3_000, bottomInset: CGFloat = 90) -> Bool {
    OlderHistoryPagination.isNearOldestEdge(
      offsetY: offset, contentHeight: height, viewportHeight: 800, topInset: 64, bottomInset: bottomInset
    )
  }

  private static func start(_ state: inout OlderHistoryPagination, cursor: Int64 = 1_000) -> OlderHistoryPagination.Request {
    state.beginGesture()
    state.requestOlder()
    guard let request = state.beginRequest(oldestMessageID: cursor, isNearEdge: true) else {
      fatalError("A user at the oldest edge must be able to start a page")
    }
    checks += 1
    return request
  }

  static func main() {
    check(near(2_290), "The actual oldest edge includes the navigation inset")
    check(near(2_350), "Pulling beyond the oldest edge keeps pagination enabled")
    check(near(1_644), "Prefetch starts one unobscured viewport before the actual edge")
    check(!near(1_643), "Do not load before reaching the bounded prefetch threshold")
    check(!near(-64), "The latest edge of a long chat must not load older pages")
    check(near(2_200, bottomInset: 0), "Zero-inset lists still load at the edge")
    check(near(2_340, bottomInset: 140), "Pinned-header height participates in the edge")
    check(near(-64, height: 300), "A user can page history even when cached rows do not fill the screen")
    check(!near(.nan), "Invalid geometry cannot request history")
    check(!near(.infinity), "Unbounded geometry cannot request history")
    check(!OlderHistoryPagination.isNearOldestEdge(
      offsetY: 0, contentHeight: 0, viewportHeight: 0, topInset: 0, bottomInset: 0
    ), "A not-yet-laid-out view cannot request history")

    check(OlderHistoryPagination.isNearOldestEdge(
      offsetY: 2_400, contentHeight: 3_000, viewportHeight: 800, topInset: 500, bottomInset: 300
    ), "A heavily obscured viewport keeps at least 100 points of prefetch")
    check(!OlderHistoryPagination.isNearOldestEdge(
      offsetY: 2_099, contentHeight: 3_000, viewportHeight: 800, topInset: 500, bottomInset: 100
    ), "Large insets do not start unbounded prefetch")
    check(OlderHistoryPagination.isNearOldestEdge(
      offsetY: 750, contentHeight: 3_000, viewportHeight: 1_200, topInset: 50, bottomInset: 50
    ), "A taller viewport begins prefetch earlier")
    check(!OlderHistoryPagination.isNearOldestEdge(
      offsetY: 2_100, contentHeight: 3_000, viewportHeight: 400, topInset: 50, bottomInset: 50
    ), "A smaller viewport keeps a proportionate prefetch window")

    check(OlderHistoryPagination.appendsOlderItems(previous: [9, 8], next: [9, 8, 7, 6]),
          "An older-only page preserves the visible history row")
    check(!OlderHistoryPagination.appendsOlderItems(previous: [9, 8], next: [10, 9, 8]),
          "A new message must retain the existing send-scroll behavior")
    check(!OlderHistoryPagination.appendsOlderItems(previous: [9, 8], next: [9, 8]),
          "A same-item update is not pagination")
    check(!OlderHistoryPagination.appendsOlderItems(previous: [9, 8], next: [8, 7, 6]),
          "A replaced history window must not restore the old viewport")
    check(!OlderHistoryPagination.appendsOlderItems(previous: [9, 8], next: [8, 9, 7]),
          "A reordered list must not use an older-page anchor")
    check(!OlderHistoryPagination.appendsOlderItems(previous: [Int](), next: [9, 8]),
          "Initial loading must keep its initial scroll positioning")

    var state = OlderHistoryPagination()
    check(state.beginRequest(oldestMessageID: 1_000, isNearEdge: true) == nil,
          "Initial and programmatic layout must not start paging without user demand")
    let first = start(&state)
    state.requestOlder()
    check(state.beginRequest(oldestMessageID: 900, isNearEdge: true) == nil,
          "Scroll callbacks cannot overlap an in-flight local or remote page, even if its cursor changed")
    check(state.finishRequest(first, oldestMessageID: 997, succeeded: true), "The local page completes")
    // No further scroll event: this is the page/snapshot completion recheck.
    let continuation = state.beginRequest(oldestMessageID: 997, isNearEdge: true)
    check(continuation != nil, "A short last cached page continues to remote history after scrolling stops")
    check(continuation?.beforeMessageID == 997, "Continuation uses the newly loaded oldest message")
    if let continuation {
      check(state.finishRequest(continuation, oldestMessageID: 897, succeeded: true), "The remote page completes")
    }
    check(state.beginRequest(oldestMessageID: 897, isNearEdge: false) == nil,
          "Enough new content ends prefetching rather than downloading the whole chat")
    check(!state.hasDemand, "Leaving the oldest edge clears demand")
    check(state.beginRequest(oldestMessageID: 897, isNearEdge: true) == nil,
          "A later programmatic offset change does not resume a finished gesture")

    for finalCursor: Int64? in [1_000, 1_001, nil, 0, -1] {
      var stopped = OlderHistoryPagination()
      let request = start(&stopped)
      check(stopped.finishRequest(request, oldestMessageID: finalCursor, succeeded: true), "Completion is accepted")
      stopped.requestOlder()
      check(stopped.beginRequest(oldestMessageID: 1_000, isNearEdge: true) == nil,
            "Empty/duplicate/non-advancing pages cannot spin on the same cursor")
      stopped.beginGesture()
      check(stopped.beginRequest(oldestMessageID: 1_000, isNearEdge: true) != nil,
            "A new gesture can retry without a permanent false end-of-history marker")
    }

    var failed = OlderHistoryPagination()
    let failure = start(&failed)
    check(failed.finishRequest(failure, oldestMessageID: 900, succeeded: false), "The failed request releases ownership")
    check(failed.beginRequest(oldestMessageID: 900, isNearEdge: true) == nil,
          "An error does not automatically retry even if a concurrent update moved the cursor")

    var movedAway = OlderHistoryPagination()
    let pending = start(&movedAway)
    check(movedAway.beginRequest(oldestMessageID: 1_000, isNearEdge: false) == nil, "Scrolling away stops demand")
    check(movedAway.finishRequest(pending, oldestMessageID: 900, succeeded: true), "The in-flight page may finish")
    check(movedAway.beginRequest(oldestMessageID: 900, isNearEdge: true) == nil, "That completion cannot restart scrolling demand")

    var jumped = OlderHistoryPagination()
    let canceled = start(&jumped)
    jumped.reset()
    check(!jumped.hasDemand, "Navigation/disposal clears pending demand")
    let replacement = start(&jumped)
    check(!jumped.finishRequest(canceled, oldestMessageID: 900, succeeded: true), "A canceled window's completion is ignored")
    check(jumped.beginRequest(oldestMessageID: 900, isNearEdge: true) == nil, "A stale completion cannot release the new request")
    check(jumped.finishRequest(replacement, oldestMessageID: 900, succeeded: true), "The new window still completes normally")

    for cursor: Int64? in [nil, -1, 0, 1] {
      var ended = OlderHistoryPagination()
      ended.requestOlder()
      check(ended.beginRequest(oldestMessageID: cursor, isNearEdge: true) == nil,
            "Empty/optimistic history and the first server message have no valid older cursor")
    }
    print("Passed \(checks) older-history pagination checks.")
  }
}
