import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct ShowChatInSidebarTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/ShowChatInSidebar")

  public var method: InlineProtocol.Method = .showChatInSidebar
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peer: Peer
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(peer: Peer) {
    context = Context(peer: peer)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .showChatInSidebar(.with {
      $0.peerID = context.peer.toInputPeer()
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .showChatInSidebar(response) = result, response.hasChat, response.hasDialog else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let chat = Chat(from: response.chat)
        try chat.save(db)
        try response.dialog.saveFull(db)
      }
    } catch {
      log.error("Failed to save showChatInSidebar result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to show chat in sidebar", error: error)
  }
}

public extension Transaction2 where Self == ShowChatInSidebarTransaction {
  static func showChatInSidebar(peer: Peer) -> ShowChatInSidebarTransaction {
    ShowChatInSidebarTransaction(peer: peer)
  }
}
