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

  var protocolSettings: InlineProtocol.DialogNotificationSettings? {
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
  public var type: TransactionKindType = .mutation(MutationConfig(retryAfterAck: true))

  public struct Context: Sendable, Codable {
    public var peerId: Peer
    public var selection: DialogNotificationSettingSelection
    let intentId: String?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UpdateDialogNotificationSettings")

  public init(peerId: Peer, selection: DialogNotificationSettingSelection) {
    context = Context(
      peerId: peerId,
      selection: selection,
      intentId: UUID().uuidString
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogNotificationSettings(.with {
      $0.peerID = context.peerId.toInputPeer()
      if let settings = context.selection.protocolSettings {
        $0.notificationSettings = settings
      }
    })
  }

  public var executionKey: TransactionExecutionKey? {
    let value: String
    switch context.peerId {
    case let .user(id): value = "user:\(id)"
    case let .thread(id): value = "thread:\(id)"
    }
    return TransactionExecutionKey(namespace: "dialog-notification-settings", value: value)
  }

  public func optimistic() async {
    await DialogMutationRollbackTracker.shared.reserveNotificationRecord(
      intentID: context.intentId,
      peer: context.peerId
    )
    do {
      let original = try await AppDatabase.shared.reader.read { db in
        try Dialog.get(peerId: context.peerId).fetchOne(db)
      }
      await DialogMutationRollbackTracker.shared.recordNotification(
        intentID: context.intentId,
        peer: context.peerId,
        original: original,
        selection: context.selection
      )
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else {
          return
        }
        dialog.notificationSettings = context.selection.protocolSettings
        try dialog.save(db)
      }
    } catch {
      await DialogMutationRollbackTracker.shared.cancelNotificationRecordReservation(
        intentID: context.intentId,
        peer: context.peerId
      )
      log.error("Failed to update dialog notification settings optimistically", error: error)
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogNotificationSettings(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdatesAndWait(response.updates)
    guard let resolution = await DialogMutationRollbackTracker.shared.beginNotificationSuccess(
      intentID: context.intentId,
      peer: context.peerId
    ) else { return }
    guard await reconcileNotificationSettings(using: resolution) else { return }
    await DialogMutationRollbackTracker.shared.finalizeNotificationResolution(
      token: resolution.token,
      peer: context.peerId
    )
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateDialogNotificationSettings transaction failed", error: error)
    await rollbackNotificationSettings()
  }

  public func cancelled() async {
    await rollbackNotificationSettings()
  }

  private func rollbackNotificationSettings() async {
    guard let resolution = await DialogMutationRollbackTracker.shared.beginNotificationFailure(
      intentID: context.intentId,
      peer: context.peerId
    ) else { return }

    // Keep the resolution in the tracker if the local write fails. That failed
    // intent must not become a rollback baseline for a newer local choice.
    guard await reconcileNotificationSettings(using: resolution) else { return }
    await DialogMutationRollbackTracker.shared.finalizeNotificationResolution(
      token: resolution.token,
      peer: context.peerId
    )
  }

  private func reconcileNotificationSettings(using resolution: DialogNotificationMutationResolution) async -> Bool {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        guard var dialog = try Dialog.get(peerId: context.peerId).fetchOne(db) else { return }
        guard Self.restoreNotificationSettings(
          &dialog,
          using: resolution
        ) else { return }
        try dialog.save(db, onConflict: .replace)
      }
      return true
    } catch {
      log.error("Failed to reconcile dialog notification settings", error: error)
      return false
    }
  }

  @discardableResult
  static func restoreNotificationSettings(
    _ dialog: inout Dialog,
    using resolution: DialogNotificationMutationResolution
  ) -> Bool {
    guard dialog.notificationSelection == resolution.expectedCurrentSelection else { return false }
    dialog.notificationSettings = resolution.targetSettings
    return true
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
