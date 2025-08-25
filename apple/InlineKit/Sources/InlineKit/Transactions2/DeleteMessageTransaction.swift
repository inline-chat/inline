import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteMessageTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .deleteMessages
  public var context: Context

  public struct Context: Sendable, Codable {
    public var messageIds: [Int64]
    public var peerId: Peer
    public var chatId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/DeleteMessage")

  public init(messageIds: [Int64], peerId: Peer, chatId: Int64) {
    context = Context(messageIds: messageIds, peerId: peerId, chatId: chatId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteMessages(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageIds = context.messageIds
    })
  }

  // Computed
  public var messageIds: [Int64] { context.messageIds }
  public var peerId: Peer { context.peerId }
  public var chatId: Int64 { context.chatId }

  // Methods
  public func optimistic() async {
    log.debug("Optimistic delete message \(messageIds) \(peerId) \(chatId)")
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Message.deleteMessages(db, messageIds: messageIds, chatId: chatId)
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerId)
      }
    } catch {
      log.error("Failed to delete message", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .deleteMessages(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }
}

// Helper

public extension Transaction2 where Self == DeleteMessageTransaction {
  static func deleteMessages(messageIds: [Int64], peerId: Peer, chatId: Int64) -> DeleteMessageTransaction {
    DeleteMessageTransaction(messageIds: messageIds, peerId: peerId, chatId: chatId)
  }
}
