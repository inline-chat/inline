import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct GetBotPresenceTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetBotPresence")

  public var method: InlineProtocol.Method = .getBotPresence
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public let peer: Peer
  }

  public init(peer: Peer) {
    context = Context(peer: peer)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getBotPresence(.with {
      $0.peerID = context.peer.toInputPeer()
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getBotPresence = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("getBotPresence succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("GetBotPresence transaction failed", error: error)
  }
}

public struct SetBotPresenceStateTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/SetBotPresenceState")

  public var method: InlineProtocol.Method = .setBotPresenceState
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let peer: Peer
    public let kindRawValue: Int
    public let comment: String?
  }

  public init(peer: Peer, kind: InlineProtocol.BotPresenceState.Kind, comment: String? = nil) {
    context = Context(peer: peer, kindRawValue: kind.rawValue, comment: comment)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .setBotPresenceState(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.state = .with {
        $0.kind = InlineProtocol.BotPresenceState.Kind(rawValue: context.kindRawValue) ?? .unspecified
        if let comment = context.comment, !comment.isEmpty {
          $0.comment = comment
        }
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setBotPresenceState = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("setBotPresenceState succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("SetBotPresenceState transaction failed", error: error)
  }
}

public extension Transaction2 where Self == GetBotPresenceTransaction {
  static func getBotPresence(peer: Peer) -> GetBotPresenceTransaction {
    GetBotPresenceTransaction(peer: peer)
  }
}

public extension Transaction2 where Self == SetBotPresenceStateTransaction {
  static func setBotPresenceState(
    peer: Peer,
    kind: InlineProtocol.BotPresenceState.Kind,
    comment: String? = nil
  ) -> SetBotPresenceStateTransaction {
    SetBotPresenceStateTransaction(peer: peer, kind: kind, comment: comment)
  }
}
