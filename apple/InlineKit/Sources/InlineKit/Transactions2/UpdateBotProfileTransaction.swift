import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateBotProfileTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/UpdateBotProfile")

  public var method: InlineProtocol.Method = .updateBotProfile
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let botUserId: Int64
    public let name: String?
    public let photoFileUniqueId: String?
  }

  public init(botUserId: Int64, name: String? = nil, photoFileUniqueId: String? = nil) {
    context = Context(botUserId: botUserId, name: name, photoFileUniqueId: photoFileUniqueId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateBotProfile(.with {
      $0.botUserID = context.botUserId
      if let name = context.name {
        $0.name = name
      }
      if let photoFileUniqueId = context.photoFileUniqueId {
        $0.photoFileUniqueID = photoFileUniqueId
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .updateBotProfile = result else {
      throw TransactionExecutionError.invalid
    }
    log.trace("updateBotProfile succeeded")
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateBotProfile transaction failed", error: error)
  }
}

public extension Transaction2 where Self == UpdateBotProfileTransaction {
  static func updateBotProfile(
    botUserId: Int64,
    name: String? = nil,
    photoFileUniqueId: String? = nil
  ) -> UpdateBotProfileTransaction {
    UpdateBotProfileTransaction(botUserId: botUserId, name: name, photoFileUniqueId: photoFileUniqueId)
  }
}

