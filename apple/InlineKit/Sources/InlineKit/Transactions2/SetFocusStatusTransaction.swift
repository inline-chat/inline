import Foundation
import InlineProtocol
import RealtimeV2

/// Reports whether an Apple Focus silences this user's notifications.
public struct SetFocusStatusTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setFocusStatus
  public var context: Context
  // A stale report is worse than none; the next activation sends a fresh one.
  public var type: TransactionKindType = .ephemeral(EphemeralTransactionConfig(maxQueueAge: 30))

  public struct Context: Sendable, Codable {
    let focused: Bool
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(focused: Bool) {
    context = Context(focused: focused)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .setFocusStatus(.with { $0.focused = context.focused })
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setFocusStatus = rpcResult else { throw TransactionExecutionError.invalid }
  }
}

public extension Transaction2 where Self == SetFocusStatusTransaction {
  static func setFocusStatus(focused: Bool) -> SetFocusStatusTransaction {
    SetFocusStatusTransaction(focused: focused)
  }
}
