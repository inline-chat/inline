import InlineProtocol

public enum UpdateApplySource: Sendable {
  case realtime
  case syncCatchup
}

public struct UpdateApplyResult: Sendable {
  public let appliedCount: Int
  public let failedCount: Int

  public var succeeded: Bool {
    failedCount == 0
  }

  public init(appliedCount: Int, failedCount: Int) {
    self.appliedCount = appliedCount
    self.failedCount = failedCount
  }

  public static func success(count: Int) -> UpdateApplyResult {
    UpdateApplyResult(appliedCount: count, failedCount: 0)
  }
}

/// Protocol for applying updates within the Sync actor context
public protocol ApplyUpdates: Sendable {
  /// Apply a batch of updates to the database
  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource) async -> UpdateApplyResult
}
