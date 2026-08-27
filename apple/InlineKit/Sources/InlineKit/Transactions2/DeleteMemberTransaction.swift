import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteMemberTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/DeleteMember")

  public var method: InlineProtocol.Method = .deleteMember
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
    let userId: Int64
    let blockJoin: Bool

    private enum CodingKeys: String, CodingKey {
      case spaceId
      case userId
      case blockJoin
    }

    init(spaceId: Int64, userId: Int64, blockJoin: Bool) {
      self.spaceId = spaceId
      self.userId = userId
      self.blockJoin = blockJoin
    }

    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      spaceId = try values.decode(Int64.self, forKey: .spaceId)
      userId = try values.decode(Int64.self, forKey: .userId)
      blockJoin = try values.decodeIfPresent(Bool.self, forKey: .blockJoin) ?? false
    }
  }

  public init(spaceId: Int64, userId: Int64, blockJoin: Bool = false) {
    context = Context(spaceId: spaceId, userId: userId, blockJoin: blockJoin)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteMember(.with {
      $0.spaceID = context.spaceId
      $0.userID = context.userId
      $0.blockJoin = context.blockJoin
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func optimistic() async throws(TransactionExecutionError) {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        _ = try Member
          .filter(Column("spaceId") == context.spaceId)
          .filter(Column("userId") == context.userId)
          .deleteAll(db)
      }
    } catch {
      log.error("Failed to optimistically delete member", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .deleteMember(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }
}

// MARK: - Helper

public extension Transaction2 where Self == DeleteMemberTransaction {
  static func deleteMember(spaceId: Int64, userId: Int64, blockJoin: Bool = false) -> DeleteMemberTransaction {
    DeleteMemberTransaction(spaceId: spaceId, userId: userId, blockJoin: blockJoin)
  }
}
