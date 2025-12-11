import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateMemberAccessTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/UpdateMemberAccess")

  public var method: InlineProtocol.Method = .updateMemberAccess
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
    let userId: Int64
    let access: AccessRole

    public enum AccessRole: Sendable, Codable {
      case member(canAccessPublicChats: Bool)
      case admin
    }
  }

  public init(spaceId: Int64, userId: Int64, access: Context.AccessRole) {
    context = Context(spaceId: spaceId, userId: userId, access: access)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateMemberAccess(.with {
      $0.spaceID = context.spaceId
      $0.userID = context.userId
      $0.role = .with {
        $0.role = switch context.access {
        case let .member(canAccessPublicChats):
          .member(.with {
            $0.canAccessPublicChats = canAccessPublicChats
          })
        case .admin:
          .admin(.init())
        }
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async throws(TransactionExecutionError) {
    // No optimistic local changes; rely on updates from server.
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateMemberAccess(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }
}

public extension Transaction2 where Self == UpdateMemberAccessTransaction {
  static func updateMemberAccess(
    spaceId: Int64,
    userId: Int64,
    access: UpdateMemberAccessTransaction.Context.AccessRole
  ) -> UpdateMemberAccessTransaction {
    UpdateMemberAccessTransaction(spaceId: spaceId, userId: userId, access: access)
  }
}

