import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateDialogOpenTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updateDialogOpen
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let open: Bool
    let order: String?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UpdateDialogOpen")

  public init(peerId: Peer, open: Bool, order: String? = nil) {
    context = Context(
      peerId: peerId,
      open: open,
      order: order ?? Self.initialOrder(open: open)
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogOpen(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.open = context.open
      if let order = context.order {
        $0.order = order
      }
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try optimisticDialog(db) else { return }
        Self.applyLocalOpenState(&dialog, open: context.open, order: context.order)
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      log.error("Failed to optimistically update dialog open state", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogOpen(response) = result else {
      throw TransactionExecutionError.invalid
    }

    guard response.hasChat, response.hasDialog else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        if response.hasUser {
          _ = try User.save(db, user: response.user)
        }

        let chat = Chat(from: response.chat)
        try chat.save(db)
        _ = try response.dialog.saveFull(db)
        try Self.applyLocalOpenState(peerId: context.peerId, open: context.open, order: context.order, db: db)
      }
    } catch {
      log.error("Failed to apply dialog open result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateDialogOpen transaction failed", error: error)
  }

  private func optimisticDialog(_ db: Database) throws -> Dialog? {
    if let dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) {
      return dialog
    }

    guard context.open else { return nil }

    switch context.peerId {
      case let .user(id):
        return Dialog(optimisticForUserId: id)
      case let .thread(id):
        guard let chat = try Chat.fetchOne(db, id: id) else { return nil }
        var dialog = Dialog(optimisticForChat: chat)
        if chat.isReplyThread {
          dialog.chatListHidden = true
        }
        return dialog
    }
  }

  static func applyLocalOpenState(peerId: Peer, open: Bool, order: String? = nil, db: Database) throws {
    guard var dialog = try Dialog.get(peerId: peerId).fetchOne(db) else { return }
    applyLocalOpenState(&dialog, open: open, order: order)
    try dialog.save(db, onConflict: .replace)
  }

  private static func applyLocalOpenState(_ dialog: inout Dialog, open: Bool, order: String?) {
    if open {
      if dialog.open == false || dialog.order == nil {
        dialog.order = order ?? dialog.order
      }
      dialog.open = true
      dialog.archived = false
    } else {
      dialog.open = false
      dialog.openedDate = nil
      dialog.order = nil
    }
  }

  private static func initialOrder(open: Bool) -> String? {
    guard open else { return nil }

    return (try? AppDatabase.shared.reader.read { db in
      try Dialog.nextSidebarOrder(db)
    }) ?? FractionalIndex.after(nil)
  }
}

public extension Transaction2 where Self == UpdateDialogOpenTransaction {
  static func updateDialogOpen(peerId: Peer, open: Bool, order: String? = nil) -> UpdateDialogOpenTransaction {
    UpdateDialogOpenTransaction(peerId: peerId, open: open, order: order)
  }
}
