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

public enum TransactionReconnectPolicy: Equatable, Sendable {
  /// The request must not be attempted again once dispatch may have reached the server.
  case neverReplay

  /// The application contract has its own stable idempotency key or equivalent set semantics.
  case replaySafe
}

public struct MutationConfig: Sendable {
  public var transient: Bool = false

  public init(transient: Bool = false) {
    self.transient = transient
  }
}

/// Short-lived work whose result is useful only near the time it was requested.
///
/// Ephemeral transactions are never persisted or replayed across a disconnect.
/// They may wait briefly behind the bounded application-request window, but are
/// discarded instead of being dispatched after `maxQueueAge` has elapsed.
public struct EphemeralTransactionConfig: Sendable {
  public var maxQueueAge: TimeInterval

  public init(maxQueueAge: TimeInterval = 5) {
    self.maxQueueAge = max(0, maxQueueAge)
  }
}

public enum TransactionKindType: Sendable {
  /// Query is a transaction that will not be persisted to disk
  case query(QueryConfig = QueryConfig())

  /// Mutations will be persisted to disk for the duration of the timeout
  case mutation(MutationConfig = MutationConfig())

  /// Best-effort work that must not accumulate or cross a reconnect boundary.
  case ephemeral(EphemeralTransactionConfig = EphemeralTransactionConfig())
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

  /// Called when execution may have committed but no authoritative result was received.
  /// This must not perform the rollback used for a definitive pre-execution failure.
  func commitOutcomeUnknown() async

  /// Called when the transaction is cancelled
  func cancelled() async

  /// Dependencies that must be satisfied before this transaction can run remotely.
  var blockers: [TransactionBlocker] { get }

  /// Dependencies that become satisfied after a successful apply.
  var satisfiedBlockersOnSuccess: [TransactionBlocker] { get }

  /// Transactions sharing this key execute serially until terminal completion.
  var executionKey: TransactionExecutionKey? { get }

  /// Overrides the query/mutation compatibility default for reconnect replay.
  ///
  /// Use this only when the exact application operation is known to be replay-safe
  /// or execution-sensitive. A nil value preserves the legacy default: queries
  /// replay and mutations do not.
  var reconnectReplayPolicy: TransactionReconnectPolicy? { get }

  /// Coalesces queued ephemeral work with the same method and key.
  /// In-flight work is never cancelled because it may already be executing.
  var ephemeralCoalescingKey: String? { get }

  /// The policy the transaction owner must use when deciding whether work may
  /// cross a reconnect boundary again. Keep the compatibility fallback here so
  /// every owner path applies the same conservative query/mutation default.
  var effectiveReconnectReplayPolicy: TransactionReconnectPolicy { get }
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
  func commitOutcomeUnknown() async {}
  var blockers: [TransactionBlocker] { [] }
  var satisfiedBlockersOnSuccess: [TransactionBlocker] { [] }
  var executionKey: TransactionExecutionKey? { nil }
  var reconnectReplayPolicy: TransactionReconnectPolicy? { nil }
  var ephemeralCoalescingKey: String? { nil }
  var effectiveReconnectReplayPolicy: TransactionReconnectPolicy {
    if let reconnectReplayPolicy {
      return reconnectReplayPolicy
    }

    switch type {
    case .query:
      return .replaySafe
    case .mutation:
      return .neverReplay
    case .ephemeral:
      return .neverReplay
    }
  }

  var ephemeralConfig: EphemeralTransactionConfig? {
    guard case let .ephemeral(config) = type else { return nil }
    return config
  }

  var input: InlineProtocol.RpcCall.OneOf_Input? {
    input(from: context)
  }
}
