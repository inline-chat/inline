import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateUserSettingsTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .updateUserSettings
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var notificationSettings: NotificationSettingsManager
    public var privacySettings: PrivacySettingsManager?
    public var composeSettings: ComposeSettingsManager?
    public var messageGestureSettings: MessageGestureValues?

    enum CodingKeys: String, CodingKey {
      case notificationSettings
      case privacySettings
      case composeSettings
      case messageGestureSettings
    }

    public init(
      notificationSettings: NotificationSettingsManager,
      privacySettings: PrivacySettingsManager? = nil,
      composeSettings: ComposeSettingsManager? = nil,
      messageGestureSettings: MessageGestureValues? = nil
    ) {
      self.notificationSettings = notificationSettings
      self.privacySettings = privacySettings
      self.composeSettings = composeSettings
      self.messageGestureSettings = messageGestureSettings
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      notificationSettings = try container.decode(NotificationSettingsManager.self, forKey: .notificationSettings)
      privacySettings = try container.decodeIfPresent(PrivacySettingsManager.self, forKey: .privacySettings)
      composeSettings = try container.decodeIfPresent(ComposeSettingsManager.self, forKey: .composeSettings)
      messageGestureSettings = try container.decodeIfPresent(MessageGestureValues.self, forKey: .messageGestureSettings)
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(notificationSettings, forKey: .notificationSettings)
      try container.encodeIfPresent(privacySettings, forKey: .privacySettings)
      try container.encodeIfPresent(composeSettings, forKey: .composeSettings)
      try container.encodeIfPresent(messageGestureSettings, forKey: .messageGestureSettings)
    }
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/UpdateUserSettings")

  public init(
    notificationSettings: NotificationSettingsManager,
    privacySettings: PrivacySettingsManager? = nil,
    composeSettings: ComposeSettingsManager? = nil,
    messageGestureSettings: MessageGestureValues? = nil
  ) {
    context = Context(
      notificationSettings: notificationSettings,
      privacySettings: privacySettings,
      composeSettings: composeSettings,
      messageGestureSettings: messageGestureSettings
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateUserSettings(.with {
      $0.userSettings = .with {
        $0.notificationSettings = context.notificationSettings.toProtocol()
        if let privacySettings = context.privacySettings {
          $0.privacySettings = privacySettings.toProtocol()
        }
        if let gestures = context.messageGestureSettings {
          $0.messageGestureSettings = gestures.toProtocol()
        }
        if let composeSettings = context.composeSettings {
          $0.composeSettings = composeSettings.toProtocol()
        }
      }
    })
  }

  /// Global settings edits must not overtake an already dispatched edit. The
  /// transaction owner scopes this fixed lane to the authenticated account.
  public var executionKey: TransactionExecutionKey? {
    TransactionExecutionKey(namespace: "user-settings", value: "global")
  }

  // MARK: - Transaction Methods

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateUserSettings(result) = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("updateUserSettings result: \(result)")

    // Note(@mo): Should we keep this? Legacy calls to this method used plain invoke not invokeWithHandler
    // Apply to database/UI
    await Api.realtime.applyUpdatesAndWait(result.updates)
  }
}

// Helper

public extension Transaction2 where Self == UpdateUserSettingsTransaction {
  static func updateUserSettings(
    notificationSettings: NotificationSettingsManager,
    privacySettings: PrivacySettingsManager? = nil,
    composeSettings: ComposeSettingsManager? = nil,
    messageGestureSettings: MessageGestureValues? = nil
  ) -> UpdateUserSettingsTransaction {
    UpdateUserSettingsTransaction(
      notificationSettings: notificationSettings,
      privacySettings: privacySettings,
      composeSettings: composeSettings,
      messageGestureSettings: messageGestureSettings
    )
  }
}
