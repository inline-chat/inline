import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateUserSettingsTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .updateUserSettings
  public var context: Context

  public struct Context: Sendable, Codable {
    public var notificationSettings: NotificationSettingsManager
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/UpdateUserSettings")

  public init(notificationSettings: NotificationSettingsManager) {
    context = Context(notificationSettings: notificationSettings)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateUserSettings(.with {
      $0.userSettings = .with {
        $0.notificationSettings = context.notificationSettings.toProtocol()
      }
    })
  }

  // MARK: - Transaction Methods

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateUserSettings(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("updateUserSettings result: \(result)")

    // Note(@mo): Should we keep this? Legacy calls to this method used plain invoke not invokeWithHandler
    // Apply to database/UI
    await Api.realtime.applyUpdates(result.updates)
  }
}

// Helper

public extension Transaction2 where Self == UpdateUserSettingsTransaction {
  static func updateUserSettings(notificationSettings: NotificationSettingsManager) -> UpdateUserSettingsTransaction {
    UpdateUserSettingsTransaction(notificationSettings: notificationSettings)
  }
}
