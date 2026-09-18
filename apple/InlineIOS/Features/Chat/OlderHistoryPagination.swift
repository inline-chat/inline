import Foundation

/// Keeps a user's request for older history alive across asynchronous pages and layout updates.
/// Geometry uses the inverted list's physical bottom, including its navigation-bar inset.
struct OlderHistoryPagination {
  struct Request: Equatable {
    fileprivate let generation: UInt64
    let beforeMessageID: Int64
  }

  private(set) var hasDemand = false
  private var activeRequest: Request?
  private var blockedCursor: Int64?
  private var generation: UInt64 = 0

  static func isNearOldestEdge(
    offsetY: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat
  ) -> Bool {
    guard viewportHeight > 0, contentHeight >= 0,
          offsetY.isFinite, contentHeight.isFinite, viewportHeight.isFinite,
          topInset.isFinite, bottomInset.isFinite
    else { return false }
    let oldestOffset = max(-topInset, contentHeight - viewportHeight + bottomInset)
    // Pulling beyond the edge still expresses demand; it must not disable pagination.
    // Start one visible screen ahead so fetching and sizing can finish before
    // scrolling hits the end and begins rubber-banding. Keep the window bounded.
    let prefetchDistance = max(100, viewportHeight - max(0, topInset) - max(0, bottomInset))
    return offsetY >= oldestOffset - prefetchDistance
  }

  /// Only older-only extensions may preserve the history viewport. A send,
  /// deletion, reorder, or navigation to a different window has other semantics.
  static func appendsOlderItems<Item: Equatable>(previous: [Item], next: [Item]) -> Bool {
    !previous.isEmpty && next.count > previous.count && next.starts(with: previous)
  }

  mutating func beginGesture() {
    // A new gesture may retry a failed request, without automatically looping on failure.
    blockedCursor = nil
  }

  mutating func requestOlder() {
    hasDemand = true
  }

  mutating func beginRequest(oldestMessageID: Int64?, isNearEdge: Bool) -> Request? {
    guard isNearEdge else {
      hasDemand = false
      return nil
    }
    guard hasDemand, activeRequest == nil,
          let oldestMessageID, oldestMessageID > 1, oldestMessageID != blockedCursor
    else { return nil }
    generation &+= 1
    let request = Request(generation: generation, beforeMessageID: oldestMessageID)
    activeRequest = request
    return request
  }

  /// Returns false for a completion from a canceled/replaced history window.
  mutating func finishRequest(_ request: Request, oldestMessageID: Int64?, succeeded: Bool) -> Bool {
    guard activeRequest == request else { return false }
    activeRequest = nil
    let madeProgress = oldestMessageID.map { $0 > 0 && $0 < request.beforeMessageID } ?? false
    if !succeeded || !madeProgress {
      blockedCursor = request.beforeMessageID
      hasDemand = false
    }
    return true
  }

  mutating func reset() {
    hasDemand = false
    activeRequest = nil
    blockedCursor = nil
  }
}
