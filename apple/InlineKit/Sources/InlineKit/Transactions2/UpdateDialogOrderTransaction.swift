import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateDialogOrderTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updateDialogOrder
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let peerId: Peer
    let order: String?
    let pinnedOrder: String?
    let pinned: Bool?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UpdateDialogOrder")

  public init(peerId: Peer, order: String? = nil, pinnedOrder: String? = nil, pinned: Bool? = nil) {
    context = Context(peerId: peerId, order: order, pinnedOrder: pinnedOrder, pinned: pinned)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogOrder(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let order = context.order {
        $0.order = order
      }
      if let pinnedOrder = context.pinnedOrder {
        $0.pinnedOrder = pinnedOrder
      }
      if let pinned = context.pinned {
        $0.pinned = pinned
      }
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        try applyLocalOrder(&dialog, db: db)
        try dialog.save(db, onConflict: .replace)
      }
    } catch {
      log.error("Failed to optimistically update dialog order", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogOrder(response) = result else {
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

        var chat = Chat(from: response.chat)
        try chat.saveWithValidLastMsg(db)
        _ = try response.dialog.saveFull(db)
      }
    } catch {
      log.error("Failed to apply dialog order result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateDialogOrder transaction failed", error: error)
  }

  private func applyLocalOrder(_ dialog: inout Dialog, db: Database) throws {
    if let order = context.order {
      dialog.order = order
    }

    if let pinnedOrder = context.pinnedOrder {
      dialog.pinnedOrder = pinnedOrder
    }

    guard let pinned = context.pinned else { return }

    dialog.pinned = pinned
    if pinned {
      if dialog.order == nil {
        dialog.order = try Dialog.nextSidebarOrder(db)
      }
      if dialog.pinnedOrder == nil {
        dialog.pinnedOrder = try Dialog.nextPinnedOrder(db)
      }
      dialog.open = true
      dialog.archived = false
      dialog.chatListHidden = nil
      return
    }

    if context.order != nil {
      dialog.open = true
      dialog.archived = false
      dialog.chatListHidden = nil
    }
  }
}

public extension Transaction2 where Self == UpdateDialogOrderTransaction {
  static func updateDialogOrder(
    peerId: Peer,
    order: String? = nil,
    pinnedOrder: String? = nil,
    pinned: Bool? = nil
  ) -> UpdateDialogOrderTransaction {
    UpdateDialogOrderTransaction(peerId: peerId, order: order, pinnedOrder: pinnedOrder, pinned: pinned)
  }
}
