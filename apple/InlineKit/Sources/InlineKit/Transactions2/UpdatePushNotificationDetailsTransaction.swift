import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct PushContentEncryptionKeyMetadata: Sendable, Codable {
  public var publicKey: Data
  public var keyId: String?
  public var algorithmRawValue: Int?

  public init(publicKey: Data, keyId: String? = nil, algorithmRawValue: Int? = nil) {
    self.publicKey = publicKey
    self.keyId = keyId
    self.algorithmRawValue = algorithmRawValue
  }
}

public struct UpdatePushNotificationDetailsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .updatePushNotificationDetails
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var applePushToken: String
    public var pushContentEncryptionKey: PushContentEncryptionKeyMetadata?
    public var pushContentVersion: UInt32?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/UpdatePushNotificationDetails")

  public init(
    applePushToken: String,
    pushContentEncryptionKey: PushContentEncryptionKeyMetadata? = nil,
    pushContentVersion: UInt32? = nil
  ) {
    context = Context(
      applePushToken: applePushToken,
      pushContentEncryptionKey: pushContentEncryptionKey,
      pushContentVersion: pushContentVersion
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updatePushNotificationDetails(.with {
      $0.applePushToken = context.applePushToken
      $0.notificationMethod = .with {
        $0.provider = .apns
        $0.apns = .with {
          $0.deviceToken = context.applePushToken
        }
      }
      if let pushContentVersion = context.pushContentVersion {
        $0.pushContentVersion = pushContentVersion
      }
      if let key = context.pushContentEncryptionKey {
        $0.pushContentEncryptionKey = .with {
          $0.publicKey = key.publicKey
          if let keyId = key.keyId {
            $0.keyID = keyId
          }
          if
            let algorithmRawValue = key.algorithmRawValue,
            let algorithm = InlineProtocol.PushContentEncryptionKey.Algorithm(rawValue: algorithmRawValue)
          {
            $0.algorithm = algorithm
          }
        }
      }
    })
  }

  public func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .updatePushNotificationDetails = rpcResult else {
      throw TransactionExecutionError.invalid
    }

    log.trace("updatePushNotificationDetails result applied")
  }
}

public extension Transaction2 where Self == UpdatePushNotificationDetailsTransaction {
  static func updatePushNotificationDetails(
    applePushToken: String,
    pushContentEncryptionKey: PushContentEncryptionKeyMetadata? = nil,
    pushContentVersion: UInt32? = nil
  ) -> UpdatePushNotificationDetailsTransaction {
    UpdatePushNotificationDetailsTransaction(
      applePushToken: applePushToken,
      pushContentEncryptionKey: pushContentEncryptionKey,
      pushContentVersion: pushContentVersion
    )
  }
}
