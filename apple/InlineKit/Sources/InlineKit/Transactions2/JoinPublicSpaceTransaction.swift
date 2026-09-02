import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct JoinPublicSpaceTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .joinPublicSpace
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let handle: String
    public let snapshotAdmission: SpaceJoinSnapshotAdmission?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/JoinPublicSpace")

  public init(handle: String, snapshotAdmission: SpaceJoinSnapshotAdmission? = nil) {
    context = Context(handle: handle, snapshotAdmission: snapshotAdmission)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .joinPublicSpace(.with { $0.handle = context.handle })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .joinPublicSpace(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      let token = try context.snapshotAdmission?.mutationToken ?? Auth.shared.handle.beginAccountMutation()
      try await AppDatabase.shared.dbWriter.write { db in
        try Auth.shared.handle.validateAccountMutation(token)
        try SpaceJoinSnapshotAdmission.apply(
          space: response.space, member: response.member,
          admission: context.snapshotAdmission, currentUserID: token.userID, in: db
        )
      }
    } catch {
      log.error("Failed to save joined public space", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == JoinPublicSpaceTransaction {
  static func joinPublicSpace(handle: String) async throws -> JoinPublicSpaceTransaction {
    JoinPublicSpaceTransaction(handle: handle, snapshotAdmission: try await .capture())
  }
}
