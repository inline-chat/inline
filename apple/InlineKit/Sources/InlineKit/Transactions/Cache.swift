import Foundation
import Logger

struct PersistedTransaction: Codable, Sendable {
  var transaction: TransactionType

  /// Maintain order of transactions
  var order: Int

  /// When this transaction was added originally
  var date: Date
}

/// Stores legacy transactions for the current authenticated runtime.
///
/// The historical `transactions.json` format has no account identity, so it is
/// intentionally quarantined in place and never loaded or overwritten. Durable
/// transactions use the account-scoped RealtimeV2 persistence path instead.
class TransactionsCache {
  private var log = Log.scoped("TransactionsCache")
  private let queue = DispatchQueue(label: "com.app.TransactionsCache", attributes: [])

  private(set) var transactions: [PersistedTransaction] = []
  private(set) var maxOrder: Int = 0

  public convenience init() {
    self.init(stateFileURL: FileHelpers.getApplicationStateFileURL(named: "transactions.json"))
  }

  init(stateFileURL: URL) {
    self.stateFileURL = stateFileURL
    transactions = loadAll()
    maxOrder = transactions.map(\.order).max() ?? 0
  }

  public func add(transaction: TransactionType) throws {
    try queue.sync {
      guard !transactions.contains(where: { $0.transaction.id == transaction.id }) else {
        throw TransactionError.duplicate
      }
      
      maxOrder += 1
      
      transactions.append(
        PersistedTransaction(
          transaction: transaction,
          order: maxOrder,
          date: Date()
        )
      )
      
      persistAll()
    }
  }

  public func remove(transactionId: String) {
    queue.sync {
      
      // FIXME: has thread issues
      transactions.removeAll { persistedTransaction in
        persistedTransaction.transaction.id == transactionId
      }
      
      persistAll()
    }
  }

  // MARK: - Private

  private let fileManager = FileManager.default
  private nonisolated let stateFileURL: URL

  private func persistAll() {
    // Fail closed until the legacy transaction format carries an account owner.
    // Keep the pre-upgrade file untouched so pending work remains recoverable by
    // an explicit future migration instead of being silently assigned to a user.
  }

  private nonisolated func loadAll() -> [PersistedTransaction] {
    guard fileManager.fileExists(atPath: stateFileURL.path) else { return [] }
    log.warning("Ignoring unscoped legacy transaction cache")
    return []
  }

  func clearAll() {
    queue.sync {
      
      transactions = []
      persistAll()
    }
  }
}
