/// This should persist changes that need to be retried even if app quits
/// Each transaction will have an option to specifiy how long it should be preserved.
/// eg.
/// - transient updates like setOnline or typing don't need retry at all.
/// - message send should be kept in cache for 30 min even on quit (?)
/// - archiving a channel should be retried indefinitely until success.
///
/// Failure case should be handled in the transaction to revert the change in cache or something custom eg. for sending
/// message we will mark the message as failed to send and show a resend button.
///
/// We will mark a transaction as done when API responds `ok`: true
/// If API responds `ok`: false, we will retry the transaction after a delay if the error is type FLOOD or INTERNAL. for
/// a certain amount of time.
///
/// How about conflicts?
/// eg. we leave a group, our change isn't synced, user leaves and joins back from another client. then once our device
/// comes online we will try to leave again and it will do something unexpected. We could see which to apply with the OG
/// action time and compare it with joined at.
///

import Foundation

public class Transactions: @unchecked Sendable {
  public static let shared = Transactions()

  let actor = TransactionsActor()
  let cache = TransactionsCache()

  private var log = Log.scoped("Transactions")

  init() {
    // TODO: Fill out actor with persisted transactions from cache
    // TODO: Hook actor to cache via clousure so when a task is finished, we remove it from cache as well

    // Restore persisted transactions to actor
    Task {
      await actor.setCompletionHandler { [weak self] transaction in
        guard let self else { return }
        cache.remove(transactionId: transaction.id)
      }

      for persistedTransaction in cache.transactions {
        log.debug("loading transaction \(persistedTransaction.transaction.id) into queue")

        // Queue for execution
        await actor.queue(transaction: persistedTransaction.transaction.transaction)
      }
    }
  }

  /// Start a transaction
  public func mutate(transaction transaction_: TransactionType) {
    // TODO: Wait for initialization first

    let transaction = transaction_
    let transactionCopy = transaction.transaction

    log.debug("Mutating transaction: \(transaction.id)")
    // Immediately run optimistic
    transactionCopy.optimistic()

    // First persist to cache
    do {
      try cache.add(transaction: transaction)
    } catch {
      // TODO: Handle error
      return
    }

    Task {
      // Then queue for execution
      await actor.queue(transaction: transactionCopy)
    }
  }

  /// Immediately triggers rollback and removes transaction from cache
  func cancel(transactionId: String) {
    Task {
      // Remove from cache
      cache.remove(transactionId: transactionId)
      // Cancel in actor and trigger rollback
      await actor.cancel(transactionId: transactionId)
    }
  }
}

public enum TransactionType: Codable {
  case sendMessage(TransactionSendMessage)
  case mockMessage(MockMessageTransaction)

  var id: String {
    transaction.id
    //    switch self {
    //    case .sendMessage(let transaction):
    //      return transaction.id
    //    }
  }

  var transaction: any Transaction {
    switch self {
      case let .sendMessage(t):
        t
      case let .mockMessage(t):
        t
    }
  }

  // Hmm
  //  var transaction: any Transaction {
  //    let mirror = Mirror(reflecting: self)
  //    guard let associated = mirror.children.first?.value as? any Transaction else {
  //      fatalError("Invalid state")
  //    }
  //    return associated
  //  }

  // MARK: - Codable Implementation

  private enum CodingKeys: String, CodingKey {
    case type
    case transaction
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
      case let .sendMessage(transaction):
        try container.encode("sendMessage", forKey: .type)
        try container.encode(transaction, forKey: .transaction)
      case let .mockMessage(transaction):
        try container.encode("mockMessage", forKey: .type)
        try container.encode(transaction, forKey: .transaction)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
      case "sendMessage":
        let transaction = try container.decode(TransactionSendMessage.self, forKey: .transaction)
        self = .sendMessage(transaction)
      case "mockMessage":
        let transaction = try container.decode(MockMessageTransaction.self, forKey: .transaction)
        self = .mockMessage(transaction)
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .type,
          in: container,
          debugDescription: "Invalid transaction type: \(type)"
        )
    }
  }
}

struct TransactionConfig: Codable {
  let maxRetries: Int
  let retryDelay: TimeInterval
  let executionTimeout: TimeInterval

  static let `default` = TransactionConfig(maxRetries: 30, retryDelay: 5, executionTimeout: 10)
  static let noRetry = TransactionConfig(maxRetries: 0, retryDelay: 0, executionTimeout: 10)
}

protocol Transaction: Codable, Sendable, Identifiable {
  associatedtype R: Sendable

  // ID for transaction
  var id: String { get }

  var date: Date { get }

  var config: TransactionConfig { get }

  /// Make remote calls, etc
  func execute() async throws -> R
  /// Make local changes before execute
  func optimistic()
  /// Optionally apply additional changes in cache after success. For example mark an status as completed.
  func didSucceed(result: R) async

  /// If execute fails, apply appropriate logic. By default it calls `rollback()` method
  func didFail(error: Error?) async

  /// Rollback changes from local cache that happened in optimistic
  func rollback() async
}

extension Transaction {
  // TODO: Figure out a way to provide a default impl
  //  func didFail() async {
  //    await rollback()
  //  }
}
