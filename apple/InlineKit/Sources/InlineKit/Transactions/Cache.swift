import Foundation

struct PersistedTransaction: Codable {
  var transaction: TransactionType

  /// Maintain order of transactions
  var order: Int

  /// When this transaction was added originally
  var date: Date
}

/// Stores transactions and persists them to disk
class TransactionsCache {
  private var log = Log.scoped("TransactionsCache")

  private(set) var transactions: [PersistedTransaction] = []
  private(set) var maxOrder: Int = 0

  public init() {
    documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("transactions.json")
    transactions = loadAll()
    maxOrder = transactions.map(\.order).max() ?? 0
  }

  public func add(transaction: TransactionType) throws {
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

  public func remove(transactionId: String) {
    transactions.removeAll { persistedTransaction in
      persistedTransaction.transaction.id == transactionId
    }

    persistAll()
  }

  // MARK: - Private

  private let fileManager = FileManager.default
  private nonisolated let documentsURL: URL

  private func persistAll() {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601

      let data = try encoder.encode(transactions)
      try data.write(to: documentsURL, options: .atomic)
    } catch {
      log.error("Failed to persist transactions: \(error)")
      // In a production app, you might want to use proper error handling
    }
  }

  private nonisolated func loadAll() -> [PersistedTransaction] {
    do {
      guard fileManager.fileExists(atPath: documentsURL.path) else {
        return []
      }

      let data = try Data(contentsOf: documentsURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601

      let loadedTransactions = try decoder.decode([PersistedTransaction].self, from: data)
      log.info("Loaded \(loadedTransactions.count) transactions")
      return loadedTransactions.sorted { $0.order < $1.order }
    } catch {
      log.error("Failed to load transactions", error: error)
      return []
    }
  }
  
  func clearAll() {
    transactions = []
    persistAll()
  }
}
