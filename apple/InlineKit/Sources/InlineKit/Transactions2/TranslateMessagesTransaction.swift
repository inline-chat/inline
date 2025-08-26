import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct TranslateMessagesTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .translateMessages
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let messageIds: [Int64]
    let language: String
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/TranslateMessages")

  public init(peerId: Peer, messageIds: [Int64], language: String) {
    context = Context(peerId: peerId, messageIds: messageIds, language: language)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .translateMessages(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageIds = context.messageIds
      $0.language = context.language
    })
  }

  // Computed
  private var peerId: Peer {
    context.peerId
  }

  // MARK: - Transaction Methods

  public func optimistic() async {}

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .translateMessages(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("result: \(result)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        // FIXME: see if we can get chatId from outside to save one query
        guard let chat = try Chat.getByPeerId(peerId: peerId) else {
          log.error("could not find chat")
          return
        }
        let chatID = chat.id
        for translation in result.translations {
          do {
            _ = try Translation.save(db, protocolTranslation: translation, chatId: chatID)
          } catch {
            Log.shared.error("Failed to save one translation", error: error)
          }
        }
      }
    } catch {
      log.error("Failed to save translations", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

// Helper

public extension Transaction2 where Self == TranslateMessagesTransaction {
  static func translateMessages(peerId: Peer, messageIds: [Int64], language: String) -> TranslateMessagesTransaction {
    TranslateMessagesTransaction(peerId: peerId, messageIds: messageIds, language: language)
  }
}
