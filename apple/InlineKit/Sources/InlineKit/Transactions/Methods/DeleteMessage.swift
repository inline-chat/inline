import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

public struct TransactionDeleteMessage: Transaction {
  // Properties
  public var messageIds: [Int64]
  public var peerId: Peer
  public var chatId: Int64

  // Config
  public var id = UUID().uuidString
  public var config = TransactionConfig.default
  public var date = Date()

  public init(messageIds: [Int64], peerId: Peer, chatId: Int64) {
    self.messageIds = messageIds.filter {
      // only positive message ids
      Int64($0) > 0
    }
    self.peerId = peerId
    self.chatId = chatId
  }

  // Methods
  public func optimistic() {
    Log.shared.debug("Optimistic delete message \(messageIds) \(peerId) \(chatId)")
    do {
      try AppDatabase.shared.dbWriter.write { db in
        try Message.deleteMessages(db, messageIds: messageIds, chatId: chatId)
      }

      DispatchQueue.main.async(qos: .userInitiated) {
        MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerId)
      }
    } catch {
      Log.shared.error("Failed to delete message", error: error)
    }
  }

  public func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .deleteMessages,
      input: .deleteMessages(DeleteMessagesInput.with {
        $0.peerID = peerId.toInputPeer()
        $0.messageIds = messageIds
      })
    )

    guard case let .deleteMessages(response) = result else {
      throw DeleteMessageError.failed
    }

    return response.updates
  }

  public func shouldRetryOnFail(error: Error) -> Bool {
    if let error = error as? RealtimeAPIError {
      switch error {
        case let .rpcError(_, _, code):
          switch code {
            case 400, 401:
              return false

            default:
              return true
          }
        default:
          return true
      }
    }

    return true
  }

  public func didSucceed(result: [InlineProtocol.Update]) async {
    await Realtime.shared.updates.applyBatch(updates: result)
  }

  public func didFail(error: Error?) async {
    Log.shared.error("Failed to delete message", error: error)
  }

  public func rollback() async {}

  enum DeleteMessageError: Error {
    case failed
  }
}
