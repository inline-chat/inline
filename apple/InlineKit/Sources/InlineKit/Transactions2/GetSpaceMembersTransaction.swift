import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetSpaceMembersTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetSpaceMembers")

  // Properties
  public var method: InlineProtocol.Method = .getSpaceMembers
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
  }

  public init(spaceId: Int64) {
    context = Context(spaceId: spaceId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getSpaceMembers(.with { $0.spaceID = context.spaceId })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getSpaceMembers(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getSpaceMembers result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        // Save users
        for user in response.users {
          do {
            _ = try User.save(db, user: user)
          } catch {
            Log.shared.error("Failed to save user", error: error)
          }
        }

        // Save members
        for member in response.members {
          do {
            let member = Member(from: member)
            try member.save(db)
          } catch {
            Log.shared.error("Failed to save member", error: error)
          }
        }
      }
      log.trace("getSpaceMembers saved")
    } catch {
      log.error("Failed to save space members data", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetSpaceMembersTransaction {
  static func getSpaceMembers(spaceId: Int64) -> GetSpaceMembersTransaction {
    GetSpaceMembersTransaction(spaceId: spaceId)
  }
}
