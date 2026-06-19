import Foundation
import InlineProtocol
import Logger
import RealtimeV2

public struct GetSpaceUrlPreviewExclusionsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getSpaceURLPreviewExclusions
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64) {
    context = Context(spaceId: spaceId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getSpaceURLPreviewExclusions(.with { $0.spaceID = context.spaceId })
  }

  public func apply(_: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

public struct AddSpaceUrlPreviewExclusionTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/AddSpaceUrlPreviewExclusion")

  public var method: InlineProtocol.Method = .addSpaceURLPreviewExclusion
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
    let host: String
    let pathPrefix: String?
    let peerId: Peer?
    let messageId: Int64?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64, host: String, pathPrefix: String? = nil, peerId: Peer? = nil, messageId: Int64? = nil) {
    context = Context(spaceId: spaceId, host: host, pathPrefix: pathPrefix, peerId: peerId, messageId: messageId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .addSpaceURLPreviewExclusion(.with {
      $0.spaceID = context.spaceId
      $0.host = context.host
      if let pathPrefix = context.pathPrefix {
        $0.pathPrefix = pathPrefix
      }
      if let peerId = context.peerId {
        $0.peerID = peerId.toInputPeer()
      }
      if let messageId = context.messageId {
        $0.messageID = messageId
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .addSpaceURLPreviewExclusion(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("AddSpaceUrlPreviewExclusion transaction failed", error: error)
  }
}

public struct RemoveSpaceUrlPreviewExclusionTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .removeSpaceURLPreviewExclusion
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
    let exclusionId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64, exclusionId: Int64) {
    context = Context(spaceId: spaceId, exclusionId: exclusionId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .removeSpaceURLPreviewExclusion(.with {
      $0.spaceID = context.spaceId
      $0.exclusionID = context.exclusionId
    })
  }

  public func apply(_: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

public extension Transaction2 where Self == GetSpaceUrlPreviewExclusionsTransaction {
  static func getSpaceUrlPreviewExclusions(spaceId: Int64) -> GetSpaceUrlPreviewExclusionsTransaction {
    GetSpaceUrlPreviewExclusionsTransaction(spaceId: spaceId)
  }
}

public extension Transaction2 where Self == AddSpaceUrlPreviewExclusionTransaction {
  static func addSpaceUrlPreviewExclusion(
    spaceId: Int64,
    host: String,
    pathPrefix: String? = nil,
    peerId: Peer? = nil,
    messageId: Int64? = nil
  ) -> AddSpaceUrlPreviewExclusionTransaction {
    AddSpaceUrlPreviewExclusionTransaction(
      spaceId: spaceId,
      host: host,
      pathPrefix: pathPrefix,
      peerId: peerId,
      messageId: messageId
    )
  }
}

public extension Transaction2 where Self == RemoveSpaceUrlPreviewExclusionTransaction {
  static func removeSpaceUrlPreviewExclusion(spaceId: Int64, exclusionId: Int64) -> RemoveSpaceUrlPreviewExclusionTransaction {
    RemoveSpaceUrlPreviewExclusionTransaction(spaceId: spaceId, exclusionId: exclusionId)
  }
}
