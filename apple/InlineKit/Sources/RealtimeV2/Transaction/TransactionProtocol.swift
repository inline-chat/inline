import Foundation
import InlineProtocol
import Logger

public enum TransactionExecutionError: Error {
  case invalid
}

public enum TransactionBlocker: Hashable, Codable, Sendable {
  case chatCreated(chatId: Int64)
}

public enum TransactionBlockerState: Sendable {
  case blocked
  case satisfied
  case failed
}

/// A persisted, client-local serialization lane.
///
/// Transactions with the same key execute one at a time while unrelated keys
/// continue to drain. Ownership lasts until the transaction reaches a terminal
/// result, including across dispatch retries and in-process reconnects. This is
/// not a server ordering/version guarantee across process death.
public struct TransactionExecutionKey: Hashable, Codable, Sendable {
  public let namespace: String
  public let value: String

  public init(namespace: String, value: String) {
    self.namespace = namespace
    self.value = value
  }
}

public protocol TransactionBlockerResolver: Sendable {
  func state(for blocker: TransactionBlocker) async -> TransactionBlockerState
}

public struct QueryConfig: Sendable {
  public init() {}
}

public struct MutationConfig: Sendable {
  public var transient: Bool = false
  public var retryAfterAck: Bool = false

  public init(transient: Bool = false, retryAfterAck: Bool = false) {
    self.transient = transient
    self.retryAfterAck = retryAfterAck
  }
}

public enum TransactionKindType: Sendable {
  /// Query is a transaction that will not be persisted to disk
  case query(QueryConfig = QueryConfig())

  /// Mutations will be persisted to disk for the duration of the timeout
  case mutation(MutationConfig = MutationConfig())
}

public protocol Transaction: Sendable, Codable {
  var method: InlineProtocol.Method { get set }
  var type: TransactionKindType { get set }

  associatedtype Context: Sendable, Codable

  var context: Context { get set }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input?

  /// Apply the result of the query to database
  /// Error propagated to the caller of the query
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError)

  /// Optimistically update the database
  func optimistic() async

  /// Called when the transaction fails to execute
  func failed(error: TransactionError) async

  /// Called when the transaction is cancelled
  func cancelled() async

  /// Dependencies that must be satisfied before this transaction can run remotely.
  var blockers: [TransactionBlocker] { get }

  /// Dependencies that become satisfied after a successful apply.
  var satisfiedBlockersOnSuccess: [TransactionBlocker] { get }

  /// Transactions sharing this key execute serially until terminal completion.
  var executionKey: TransactionExecutionKey? { get }
}

public extension Transaction {
  var debugDescription: String {
    """
    Transaction
    method: \(method)
    input: \(String(describing: input)))
    """
  }
}

public extension Transaction {
  func cancelled() async {}
  func optimistic() async {}
  func failed(error: TransactionError) async {
    Log.shared.error("Transaction failed \(debugDescription)", error: error)
  }
  var blockers: [TransactionBlocker] { [] }
  var satisfiedBlockersOnSuccess: [TransactionBlocker] { [] }
  var executionKey: TransactionExecutionKey? { nil }

  var input: InlineProtocol.RpcCall.OneOf_Input? {
    input(from: context)
  }
}
