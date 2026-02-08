import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct MoveThreadTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/MoveThread")

  public var method: InlineProtocol.Method = .moveThread
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let chatID: Int64
    // Target space. nil => move to home.
    let spaceID: Int64?
  }

  public init(chatID: Int64, spaceID: Int64?) {
    if chatID == 0 {
      log.error("chat ID is zero")
    }
    context = Context(chatID: chatID, spaceID: spaceID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .moveThread(.with {
      $0.chatID = context.chatID
      if let spaceID = context.spaceID {
        $0.spaceID = spaceID
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async throws(TransactionExecutionError) {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var chat = try Chat.fetchOne(db, id: context.chatID) else { return }
        chat.spaceId = context.spaceID
        try chat.save(db)

        let peer: Peer = .thread(id: context.chatID)
        if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer)) {
          dialog.spaceId = context.spaceID
          try dialog.save(db)
        } else {
          let newDialog = Dialog(optimisticForChat: chat)
          try newDialog.save(db, onConflict: .replace)
        }
      }
    } catch {
      log.error("Failed to optimistically move thread", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .moveThread(response) = result else {
      throw TransactionExecutionError.invalid
    }
    guard response.hasChat else {
      throw TransactionExecutionError.invalid
    }
    let protoChat = response.chat

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let chat = Chat(from: protoChat)
        try chat.save(db)

        let peer: Peer = .thread(id: chat.id)
        if var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peer)) {
          dialog.spaceId = chat.spaceId
          try dialog.save(db)
        } else {
          let newDialog = Dialog(optimisticForChat: chat)
          try newDialog.save(db, onConflict: .replace)
        }
      }
    } catch {
      log.error("Failed to apply moveThread result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("MoveThread transaction failed", error: error)
  }

  public func cancelled() async {
    log.trace("MoveThread transaction cancelled")
  }
}

public extension Transaction2 where Self == MoveThreadTransaction {
  static func moveThread(chatID: Int64, spaceID: Int64?) -> MoveThreadTransaction {
    MoveThreadTransaction(chatID: chatID, spaceID: spaceID)
  }
}
