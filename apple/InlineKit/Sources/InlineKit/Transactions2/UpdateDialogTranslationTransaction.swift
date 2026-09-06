import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateDialogTranslationTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updateDialogTranslation
  public var type: TransactionKindType = .mutation()
  public var context: Context

  public struct Context: Sendable, Codable {
    public var peer: Peer
    public var enabled: Bool
    public var intent: UUID
    public var importLegacyEnabled: Bool?
  }

  enum CodingKeys: String, CodingKey { case context }

  public init(peer: Peer, enabled: Bool, intent: UUID, importLegacyEnabled: Bool = false) {
    context = Context(peer: peer, enabled: enabled, intent: intent, importLegacyEnabled: importLegacyEnabled)
  }

  public var executionKey: TransactionExecutionKey? {
    TransactionExecutionKey(namespace: "dialog-translation", value: context.peer.toString())
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateDialogTranslation(.with {
      $0.peerID = context.peer.toInputPeer()
      $0.enabled = context.enabled
      $0.importLegacyEnabled = context.importLegacyEnabled == true
    })
  }

  public func apply(_ result: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateDialogTranslation(response) = result else {
      throw TransactionExecutionError.invalid
    }
    await Api.realtime.applyUpdatesAndWait(response.updates)
    finish()
  }

  public func failed(error: TransactionError2) async {
    let database = AppDatabase.shared
    let preferences = database.translationPreferences
    var savedLocally = false
    if context.importLegacyEnabled != true, Self.isUnsupportedSync(error) {
      do {
        let auth = Auth.shared.handle
        let account = try auth.beginAccountMutation()
        savedLocally = try await database.dbWriter.write { db in
          try auth.validateAccountMutation(account)
          return try Self.preserveLocalChoice(context, preferences: preferences, in: db)
        }
      } catch {
        Log.shared.error("Failed to preserve the local translation preference", error: error)
      }
    }
    // Persist an old-server fallback before removing the optimistic value, so
    // translation never flashes off between the failure and the local save.
    guard preferences.finish(for: context.peer, intent: context.intent) else { return }
    let message = savedLocally
      ? String(localized: "Your translation choice is saved on this device. Sync isn't available on this server yet.")
      : String(localized: "Couldn't save the translation setting. Please try again.")
    Log.shared.warning(
      "Translation sync failed category=\(error.privacySafeErrorCategory) local_fallback=\(savedLocally)"
    )
    preferences.notices.send((context.peer, message, !savedLocally))
  }

  static func isUnsupportedSync(_ error: TransactionError2) -> Bool {
    guard case let .rpcError(rpc) = error else { return false }
    return rpc.errorCode == .badRequest && rpc.code == 400
      && rpc.message == "Unsupported RPC method: \(InlineProtocol.Method.updateDialogTranslation.rawValue)"
  }

  static func preserveLocalChoice(
    _ context: Context,
    preferences: DialogTranslationPreferences,
    in db: Database
  ) throws -> Bool {
    guard context.importLegacyEnabled != true,
          preferences.isCurrentIntent(context.intent, for: context.peer),
          var dialog = try Dialog.get(peerId: context.peer).fetchOne(db) else { return false }
    dialog.translationEnabled = context.enabled
    // An older server has no shared preference. Reuse the legacy import path:
    // upload only enabled choices once support arrives, never a legacy off.
    dialog.translationLegacyImportPending = context.enabled
    try dialog.update(db)
    return true
  }
  public func cancelled() async { finish() }
  public func commitOutcomeUnknown() async { finish() }

  private func finish() {
    AppDatabase.shared.translationPreferences.finish(for: context.peer, intent: context.intent)
  }
}
