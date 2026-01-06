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
  func getState() async -> SyncState
  func setState(_ state: SyncState) async

  func getBucketState(for key: BucketKey) async -> BucketState
  func setBucketState(for key: BucketKey, state: BucketState) async

  /// Uses a single transaction
  func setBucketStates(states: [BucketKey: BucketState]) async

  /// Clears global sync state and all bucket states.
  func clearSyncState() async
}
