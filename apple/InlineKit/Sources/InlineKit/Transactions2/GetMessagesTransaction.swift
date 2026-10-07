import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetMessagesTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetMessages")

  public var method: InlineProtocol.Method = .getMessages
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var messageIds: [Int64]
    public var admissionToken: HistoryPageAdmissionToken?
  }

  public init(peer: Peer, messageIds: [Int64]) {
    context = Context(peer: peer, messageIds: messageIds)
  }

  public var historyReadChatID: Int64? {
    context.admissionToken?.chatId
  }

  public var historyReadBucket: BucketKey? {
    .chat(peer: context.peer.toHistoryProtocolPeer())
  }

  public func preparingForDispatch() async throws(TransactionExecutionError) -> any Transaction2 {
    do {
      var prepared = self
      let admission = try await AppDatabase.shared.dbWriter.write { db in
        let peer = try HistoryPageAdmissionToken.canonicalPeer(db, peer: context.peer)
        return try (peer, HistoryPageAdmissionToken.capture(db, peer: peer))
      }
      prepared.context.peer = admission.0
      prepared.context.admissionToken = admission.1
      return prepared
    } catch HistoryPageAdmissionError.missingChat { throw .historyUnavailable }
    catch { throw .invalid }
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getMessages(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.messageIds = context.messageIds
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {
    log.debug("GetMessages transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getMessages(response) = result else {
      throw TransactionExecutionError.invalid
    }

    let peerId = context.peer

    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try Self.apply(response, context: context, db: db)
      }

      Task.detached(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesReload(peer: peerId, animated: false)
      }

      log.trace("getMessages saved")
    } catch HistoryPageAdmissionError.stale {
      throw .staleHistory
    } catch HistoryPageAdmissionError.unavailable {
      throw .historyUnavailable
    } catch {
      log.error("Failed to save getMessages results", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public static func apply(_ response: InlineProtocol.GetMessagesResult, context: Context, db: Database) throws {
    var context = context
    context.peer = try HistoryPageAdmissionToken.canonicalPeer(db, peer: context.peer)

    let chatID = try HistoryPageAdmissionToken.resolveChatId(db, peer: context.peer)
    guard let token = context.admissionToken else { throw HistoryPageAdmissionError.stale }
    try token.validateSnapshot(db, peer: context.peer, seq: response.hasSeq ? response.seq : nil)
    let requested = Set(context.messageIds)
    guard !requested.isEmpty, context.messageIds.count <= 100,
          requested.allSatisfy({ 1 ... MessageHistoryHole.positiveMessageIDMax ~= $0 }),
          response.messages.allSatisfy({ requested.contains($0.id) })
    else { throw HistoryPageAdmissionError.malformedPage }
    try HistoryPageReducer.validateMessages(response.messages, chatId: chatID, peer: context.peer, descending: false)
    _ = try HistoryPageReducer.save(response.messages, db: db)
    try HistoryPageReducer.reconcileExactAbsences(
      requested: requested, returned: Set(response.messages.map(\.id)), chatId: chatID, token: token, db: db
    )
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get messages", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getMessages transaction")
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetMessagesTransaction {
  static func getMessages(peer: Peer, messageIds: [Int64]) -> GetMessagesTransaction {
    GetMessagesTransaction(peer: peer, messageIds: messageIds)
  }
}
