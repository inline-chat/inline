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
        try Self.apply(response, spaceID: context.spaceId, in: db)
      }
      log.trace("getSpaceMembers saved")
    } catch {
      log.error("Failed to save space members data", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  static func apply(
    _ response: InlineProtocol.GetSpaceMembersResult,
    spaceID: Int64,
    in db: Database
  ) throws {
    guard response.members.allSatisfy({ $0.spaceID == spaceID }) else {
      throw TransactionExecutionError.invalid
    }

    try Member
      .filter(Member.Columns.spaceId == spaceID)
      .deleteAll(db)
    for user in response.users {
      _ = try User.save(db, user: user)
    }

    for member in response.members {
      try Member(from: member).save(db)
    }
    try Space
      .filter(Space.Columns.id == spaceID)
      .updateAll(db, [Space.Columns.memberRosterComplete.set(to: true)])
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetSpaceMembersTransaction {
  static func getSpaceMembers(spaceId: Int64) -> GetSpaceMembersTransaction {
    GetSpaceMembersTransaction(spaceId: spaceId)
  }
}
