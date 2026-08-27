import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct JoinSpaceByInviteTokenTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .joinSpaceByInviteToken
  public var context: Context
  // Invite tokens are bearer credentials. Keep retries in memory so the raw
  // token is never serialized into the durable transaction queue.
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable {
    public let token: String
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/JoinSpaceByInviteToken")

  public init(token: String) {
    context = Context(token: token)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .joinSpaceByInviteToken(.with { $0.token = context.token })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .joinSpaceByInviteToken(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Space(from: response.space).save(db)
        try Member(from: response.member).save(db)
      }
    } catch {
      log.error("Failed to save joined space", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct GetSpaceInviteLinkTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getSpaceInviteLink
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public let spaceId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64) {
    context = Context(spaceId: spaceId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getSpaceInviteLink(.with { $0.spaceID = context.spaceId })
  }

  public func apply(_: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

public struct SetSpaceInviteLinkEnabledTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setSpaceInviteLinkEnabled
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let spaceId: Int64
    public let enabled: Bool
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64, enabled: Bool) {
    context = Context(spaceId: spaceId, enabled: enabled)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .setSpaceInviteLinkEnabled(.with {
      $0.spaceID = context.spaceId
      $0.enabled = context.enabled
    })
  }

  public func apply(_: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

public extension Transaction2 where Self == JoinSpaceByInviteTokenTransaction {
  static func joinSpaceByInviteToken(token: String) -> JoinSpaceByInviteTokenTransaction {
    JoinSpaceByInviteTokenTransaction(token: token)
  }
}

public extension Transaction2 where Self == GetSpaceInviteLinkTransaction {
  static func getSpaceInviteLink(spaceId: Int64) -> GetSpaceInviteLinkTransaction {
    GetSpaceInviteLinkTransaction(spaceId: spaceId)
  }
}

public extension Transaction2 where Self == SetSpaceInviteLinkEnabledTransaction {
  static func setSpaceInviteLinkEnabled(spaceId: Int64, enabled: Bool) -> SetSpaceInviteLinkEnabledTransaction {
    SetSpaceInviteLinkEnabledTransaction(spaceId: spaceId, enabled: enabled)
  }
}
