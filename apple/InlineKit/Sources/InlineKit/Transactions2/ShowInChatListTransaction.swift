import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct ShowInChatListTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .showInChatList
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/ShowInChatList")

  public init(peerId: Peer) {
    context = Context(peerId: peerId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .showInChatList(.with {
      $0.peerID = context.peerId.toInputPeer()
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else {
          return
        }
        dialog.chatListHidden = nil
        try dialog.save(db)
      }
    } catch {
      log.error("Failed to optimistically show chat in chat list", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .showInChatList(response) = result else {
      throw TransactionExecutionError.invalid
    }

    guard response.hasChat, response.hasDialog else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        var chat = Chat(from: response.chat)
        try chat.saveWithValidLastMsg(db)
        _ = try response.dialog.saveFull(db)
      }
    } catch {
      log.error("Failed to apply showInChatList result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("ShowInChatList transaction failed", error: error)
  }
}

public extension Transaction2 where Self == ShowInChatListTransaction {
  static func showInChatList(peerId: Peer) -> ShowInChatListTransaction {
    ShowInChatListTransaction(peerId: peerId)
  }
}
