import Foundation
import InlineProtocol
import RealtimeV2

public struct GetUserSettingsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getUserSettings
  public var context: Context = .init()
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init() {}

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getUserSettings(.init())
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getUserSettings = result else {
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == GetUserSettingsTransaction {
  static func getUserSettings() -> GetUserSettingsTransaction {
    GetUserSettingsTransaction()
  }
}
