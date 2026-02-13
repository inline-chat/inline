import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public enum DialogNotificationSettingSelection: String, Codable, Sendable, CaseIterable {
  case global
  case all
  case mentions
  case none

  fileprivate var protocolSettings: InlineProtocol.DialogNotificationSettings? {
    switch self {
      case .global:
        return nil
      case .all:
        return .with { $0.mode = .all }
      case .mentions:
        return .with { $0.mode = .mentions }
      case .none:
        return .with { $0.mode = .none }
    }
  }
}

public struct UpdateDialogNotificationSettingsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updateDialogNotificationSettings
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var peerId: Peer
    public var selection: DialogNotificationSettingSelection
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UpdateDialogNotificationSettings")

  public init(peerId: Peer, selection: DialogNotificationSettingSelection) {
    context = Context(peerId: peerId, selection: selection)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogNotificationSettings(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let settings = context.selection.protocolSettings {
        $0.notificationSettings = settings
      }
    })
  }

  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else {
          return
        }
        dialog.notificationSettings = context.selection.protocolSettings
        try dialog.save(db)
      }
    } catch {
      log.error("Failed to update dialog notification settings optimistically", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogNotificationSettings(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateDialogNotificationSettings transaction failed", error: error)
  }
}

public extension Transaction2 where Self == UpdateDialogNotificationSettingsTransaction {
  static func updateDialogNotificationSettings(
    peerId: Peer,
    selection: DialogNotificationSettingSelection
  ) -> UpdateDialogNotificationSettingsTransaction {
    UpdateDialogNotificationSettingsTransaction(peerId: peerId, selection: selection)
  }
}
