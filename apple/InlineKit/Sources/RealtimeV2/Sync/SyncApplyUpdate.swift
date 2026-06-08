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

public struct ChatRepairSnapshot: Sendable {
  public let peer: InlineProtocol.Peer
  public let chat: InlineProtocol.GetChatResult
  public let history: InlineProtocol.GetChatHistoryResult
  public let reason: String

  public init(
    peer: InlineProtocol.Peer,
    chat: InlineProtocol.GetChatResult,
    history: InlineProtocol.GetChatHistoryResult,
    reason: String
  ) {
    self.peer = peer
    self.chat = chat
    self.history = history
    self.reason = reason
  }
}

/// Protocol for applying updates within the Sync actor context
public protocol ApplyUpdates: Sendable {
  /// Apply a batch of updates to the database
  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult

  /// Apply a bounded current-state repair for a chat bucket.
  func repairChat(_ snapshot: ChatRepairSnapshot) async -> Bool
}

public extension ApplyUpdates {
  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource) async -> UpdateApplyResult {
    await apply(updates: updates, source: source, sidecars: nil)
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> Bool {
    false
  }
}
