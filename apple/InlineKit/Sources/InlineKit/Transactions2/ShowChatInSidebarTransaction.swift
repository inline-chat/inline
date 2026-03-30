import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct ShowChatInSidebarTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .showChatInSidebar
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/ShowChatInSidebar")

  public init(peerId: Peer) {
    context = Context(peerId: peerId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .showChatInSidebar(.with {
      $0.peerID = context.peerId.toInputPeer()
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else {
          return
        }
        dialog.sidebarVisible = true
        try dialog.save(db)
      }
    } catch {
      log.error("Failed to optimistically show chat in sidebar", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .showChatInSidebar(response) = result else {
      throw TransactionExecutionError.invalid
    }

    guard response.hasChat, response.hasDialog else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let chat = Chat(from: response.chat)
        try chat.save(db)
        _ = try response.dialog.saveFull(db)
      }
    } catch {
      log.error("Failed to apply showChatInSidebar result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("ShowChatInSidebar transaction failed", error: error)
  }
}

public extension Transaction2 where Self == ShowChatInSidebarTransaction {
  static func showChatInSidebar(peerId: Peer) -> ShowChatInSidebarTransaction {
    ShowChatInSidebarTransaction(peerId: peerId)
  }
}
