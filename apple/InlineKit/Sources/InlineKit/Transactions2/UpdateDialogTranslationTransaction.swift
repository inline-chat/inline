import Foundation
import InlineProtocol
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

  public func failed(error: TransactionError2) async { finish() }
  public func cancelled() async { finish() }
  public func commitOutcomeUnknown() async { finish() }

  private func finish() {
    AppDatabase.shared.translationPreferences.finish(for: context.peer, intent: context.intent)
  }
}
