import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public enum DialogFollowModeSelection: String, Codable, Sendable {
  case relevance
  case following

  var protocolFollowMode: InlineProtocol.DialogFollowMode? {
    switch self {
      case .relevance:
        nil
      case .following:
        .following
    }
  }
}

public struct UpdateDialogFollowModeTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updateDialogFollowMode
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peerId: Peer
    public var selection: DialogFollowModeSelection
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UpdateDialogFollowMode")

  public init(peerId: Peer, selection: DialogFollowModeSelection) {
    context = Context(peerId: peerId, selection: selection)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogFollowMode(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let followMode = context.selection.protocolFollowMode {
        $0.followMode = followMode
      }
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else {
          return
        }
        dialog.followMode = context.selection.protocolFollowMode
        if context.selection == .following {
          try Self.applyManualFollowOpenState(&dialog, db: db)
        }
        try dialog.save(db)
      }
    } catch {
      log.error("Failed to update dialog follow mode optimistically", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogFollowMode(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateDialogFollowMode transaction failed", error: error)
  }

  static func applyManualFollowOpenState(_ dialog: inout Dialog, db: Database) throws {
    if dialog.open == false || dialog.order == nil {
      dialog.order = try Dialog.nextSidebarOrder(db)
    }
    dialog.open = true
    dialog.archived = false
    dialog.chatListHidden = nil
  }
}

public extension Transaction2 where Self == UpdateDialogFollowModeTransaction {
  static func updateDialogFollowMode(
    peerId: Peer,
    selection: DialogFollowModeSelection
  ) -> UpdateDialogFollowModeTransaction {
    UpdateDialogFollowModeTransaction(peerId: peerId, selection: selection)
  }
}
