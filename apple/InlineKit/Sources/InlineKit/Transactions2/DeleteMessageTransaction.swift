import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteMessageTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .deleteMessages
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/DeleteMessage")
  private var messageIds: [Int64]
  private var peerId: Peer
  private var chatId: Int64

  public init(messageIds: [Int64], peerId: Peer, chatId: Int64) {
    let filteredMessageIds = messageIds.filter { Int64($0) > 0 }
    input = .deleteMessages(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageIds = filteredMessageIds
    })
    self.messageIds = filteredMessageIds
    self.peerId = peerId
    self.chatId = chatId
  }

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

  public func failed(error: TransactionError2) async {
    log.error("Failed to delete message", error: error)
  }
}

// MARK: - Codable

extension DeleteMessageTransaction: Codable {
  enum CodingKeys: String, CodingKey {
    case messageIds, peerId, chatId
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(messageIds, forKey: .messageIds)
    try container.encode(peerId, forKey: .peerId)
    try container.encode(chatId, forKey: .chatId)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    messageIds = try container.decode([Int64].self, forKey: .messageIds)
    peerId = try container.decode(Peer.self, forKey: .peerId)
    chatId = try container.decode(Int64.self, forKey: .chatId)

    // Set method
    method = .deleteMessages

    // Reconstruct Protocol Buffer input
    input = .deleteMessages(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageIds = messageIds
    })
  }
}

// Helper

public extension Transaction2 where Self == DeleteMessageTransaction {
  static func deleteMessages(messageIds: [Int64], peerId: Peer, chatId: Int64) -> DeleteMessageTransaction {
    DeleteMessageTransaction(messageIds: messageIds, peerId: peerId, chatId: chatId)
  }
}
