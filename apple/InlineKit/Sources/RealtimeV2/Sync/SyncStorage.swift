import Foundation
import InlineProtocol

public struct SyncState: Sendable {
  public let lastSyncDate: Int64

  public init(lastSyncDate: Int64) {
    self.lastSyncDate = lastSyncDate
  }
}

public struct BucketState: Sendable {
  public let date: Int64
  public let seq: Int64

  public init(date: Int64, seq: Int64) {
    self.date = date
    self.seq = seq
  }
}

public enum BucketKey: Sendable, Hashable {
  case space(id: Int64)
  case chat(peer: InlineProtocol.Peer)
  case user

  public func getEntityId() -> Int64 {
    switch self {
      case let .space(id):
        id

      case let .chat(peer):
        switch peer.type {
          case let .chat(value):
            -1 * value.chatID
          case let .user(value):
            value.userID
          default:
            fatalError("Invalid peer type")
        }

      // there is only one user and that's ours
      case .user:
        0
    }
  }

  /// In sync with backend
  public func getBucket() -> Int {
    switch self {
      case .chat:
        1
      case .user:
        2
      case .space:
        3
    }
  }

  public func toProtocolBucket() -> InlineProtocol.UpdateBucket {
    switch self {
      case let .chat(peer):
        InlineProtocol.UpdateBucket.with { $0.chat = .with { $0.peerID = peer.toInputPeer() } }
      case let .space(id):
        InlineProtocol.UpdateBucket.with { $0.space = .with { $0.spaceID = id } }
      case .user:
        InlineProtocol.UpdateBucket.with { $0.user = .init() }
    }
  }
}

public protocol SyncStorage: Sendable {
  func getHistoryRevision(for key: BucketKey) async throws -> Int64
  func getHistoryChatID(for key: BucketKey) async throws -> Int64?
  func getRemovalRevision() async throws -> Int64
  /// A local chat row can identify a DM by its counterpart user. An unknown
  /// chat ID returns nil so admission can resolve it through getChat.
  func canonicalPeer(forChatID chatID: Int64) async throws -> InlineProtocol.Peer?
  func getState() async throws -> SyncState
  @discardableResult
  func setState(_ state: SyncState) async -> Bool

  func getBucketState(for key: BucketKey) async throws -> BucketState
  @discardableResult
  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool

  /// Advances a production cursor monotonically and returns the effective stored state.
  /// A snapshot may have installed a newer cursor while a bucket actor was suspended.
  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState?

  @discardableResult
  func removeBucketState(for key: BucketKey) async -> Bool

  /// Uses a single transaction
  @discardableResult
  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool

  /// Clears global sync state and all bucket states.
  @discardableResult
  func clearSyncState() async -> Bool
}

public extension SyncStorage {
  func getHistoryRevision(for key: BucketKey) async throws -> Int64 {
    0
  }

  func getHistoryChatID(for key: BucketKey) async throws -> Int64? {
    guard case let .chat(peer) = key, case let .chat(chat) = peer.type else { return nil }
    return chat.chatID
  }

  /// Stores without destructive projection writers have no invalidations.
  func getRemovalRevision() async throws -> Int64 {
    0
  }
}
