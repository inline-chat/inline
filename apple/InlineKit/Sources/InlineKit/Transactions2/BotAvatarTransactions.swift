import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct SetBotAvatarTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/SetBotAvatar")

  public var method: InlineProtocol.Method = .setBotAvatar
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
    public let kindRawValue: Int
    public let displayName: String
    public let description: String?
    public let fileUniqueId: String
  }

  public init(
    botUserId: Int64,
    kind: InlineProtocol.BotAvatar.Kind,
    displayName: String,
    description: String? = nil,
    fileUniqueId: String
  ) {
    context = Context(
      botUserId: botUserId,
      kindRawValue: kind.rawValue,
      displayName: displayName,
      description: description,
      fileUniqueId: fileUniqueId
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .setBotAvatar(.with {
      $0.botUserID = context.botUserId
      $0.kind = InlineProtocol.BotAvatar.Kind(rawValue: context.kindRawValue) ?? .unspecified
      $0.displayName = context.displayName
      if let description = context.description {
        $0.description_p = description
      }
      $0.fileUniqueID = context.fileUniqueId
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setBotAvatar = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("setBotAvatar succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("SetBotAvatar transaction failed", error: error)
  }
}

public struct ClearBotAvatarTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/ClearBotAvatar")

  public var method: InlineProtocol.Method = .clearBotAvatar
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
  }

  public init(botUserId: Int64) {
    context = Context(botUserId: botUserId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .clearBotAvatar_p(.with {
      $0.botUserID = context.botUserId
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .clearBotAvatar_p = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("clearBotAvatar succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("ClearBotAvatar transaction failed", error: error)
  }
}

public extension Transaction2 where Self == SetBotAvatarTransaction {
  static func setBotAvatar(
    botUserId: Int64,
    kind: InlineProtocol.BotAvatar.Kind,
    displayName: String,
    description: String? = nil,
    fileUniqueId: String
  ) -> SetBotAvatarTransaction {
    SetBotAvatarTransaction(
      botUserId: botUserId,
      kind: kind,
      displayName: displayName,
      description: description,
      fileUniqueId: fileUniqueId
    )
  }
}

public extension Transaction2 where Self == ClearBotAvatarTransaction {
  static func clearBotAvatar(botUserId: Int64) -> ClearBotAvatarTransaction {
    ClearBotAvatarTransaction(botUserId: botUserId)
  }
}
