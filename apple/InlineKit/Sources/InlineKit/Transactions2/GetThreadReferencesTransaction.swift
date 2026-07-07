import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetThreadReferencesTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetThreadReferences")

  public var method: InlineProtocol.Method = .getThreadReferences
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var chatID: Int64
    public var offsetID: Int64?
    public var limit: Int32?
  }

  public init(
    chatID: Int64,
    offsetID: Int64? = nil,
    limit: Int32? = nil
  ) {
    context = Context(
      chatID: chatID,
      offsetID: offsetID,
      limit: limit
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getThreadReferences(.with {
      $0.chatID = context.chatID
      if let offsetID = context.offsetID {
        $0.offsetID = offsetID
      }
      if let limit = context.limit { $0.limit = limit }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {
    log.debug("GetThreadReferences transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getThreadReferences(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await saveThreadRelationshipSidecars(chats: response.chats, dialogs: response.dialogs)
    } catch {
      log.error("Failed to save getThreadReferences sidecars", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get thread references", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getThreadReferences transaction")
  }
}

public extension Transaction2 where Self == GetThreadReferencesTransaction {
  static func getThreadReferences(
    chatID: Int64,
    offsetID: Int64? = nil,
    limit: Int32? = nil
  ) -> GetThreadReferencesTransaction {
    GetThreadReferencesTransaction(
      chatID: chatID,
      offsetID: offsetID,
      limit: limit
    )
  }
}

public struct GetThreadSubthreadsTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetThreadSubthreads")

  public var method: InlineProtocol.Method = .getThreadSubthreads
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var chatID: Int64
    public var offsetID: Int64?
    public var limit: Int32?
  }

  public init(
    chatID: Int64,
    offsetID: Int64? = nil,
    limit: Int32? = nil
  ) {
    context = Context(
      chatID: chatID,
      offsetID: offsetID,
      limit: limit
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getThreadSubthreads(.with {
      $0.chatID = context.chatID
      if let offsetID = context.offsetID {
        $0.offsetID = offsetID
      }
      if let limit = context.limit { $0.limit = limit }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {
    log.debug("GetThreadSubthreads transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getThreadSubthreads(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await saveThreadRelationshipSidecars(chats: response.chats, dialogs: response.dialogs)
    } catch {
      log.error("Failed to save getThreadSubthreads sidecars", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get thread subthreads", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getThreadSubthreads transaction")
  }
}

public extension Transaction2 where Self == GetThreadSubthreadsTransaction {
  static func getThreadSubthreads(
    chatID: Int64,
    offsetID: Int64? = nil,
    limit: Int32? = nil
  ) -> GetThreadSubthreadsTransaction {
    GetThreadSubthreadsTransaction(
      chatID: chatID,
      offsetID: offsetID,
      limit: limit
    )
  }
}

private func saveThreadRelationshipSidecars(
  chats: [InlineProtocol.Chat],
  dialogs: [InlineProtocol.Dialog]
) async throws {
  try await AppDatabase.shared.dbWriter.write { db in
    for chat in chats {
      _ = try Chat(from: chat).saveFull(db)
    }

    for dialog in dialogs {
      _ = try dialog.saveFull(db)
    }
  }
}
