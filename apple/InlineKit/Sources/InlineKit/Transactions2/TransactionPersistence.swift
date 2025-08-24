import Foundation
import Logger
import RealtimeV2

/// Simple file-based persistence for transactions
public struct DefaultTransactionPersistenceHandler: TransactionPersistenceHandler {
  private let log = Log.scoped("TransactionPersistence")

  public init() {}

  public func saveTransaction(_ transaction: TransactionWrapper) async throws {
    let data = try encodeTransaction(transaction)
    let url = fileURL(for: transaction.id)
    try data.write(to: url)
  }

  public func deleteTransaction(_ transactionId: TransactionId) async throws {
    let url = fileURL(for: transactionId)
    try FileManager.default.removeItem(at: url)
  }

  public func loadTransactions() async throws -> [TransactionWrapper] {
    let files = try getTransactionFiles()
    var transactions: [TransactionWrapper] = []

    for file in files {
      guard let transaction = loadTransaction(from: file) else { continue }
      transactions.append(transaction)
    }

    return transactions
  }
}

// MARK: - Private Implementation

private extension DefaultTransactionPersistenceHandler {
  func encodeTransaction(_ wrapper: TransactionWrapper) throws -> Data {
    let persistedData = StoredTransaction(
      id: wrapper.id,
      date: wrapper.date,
      type: TransactionTypeRegistry.typeString(for: wrapper.transaction),
      transactionData: try JSONEncoder().encode(wrapper.transaction)
    )
    return try JSONEncoder().encode(persistedData)
  }

  func getTransactionFiles() throws -> [URL] {
    let directory = transactionDirectory()
    return try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
  }

  func loadTransaction(from file: URL) -> TransactionWrapper? {
    do {
      let data = try Data(contentsOf: file)
      let persisted = try JSONDecoder().decode(StoredTransaction.self, from: data)
      let transaction = try decodeTransaction(type: persisted.type, data: persisted.transactionData)
      return TransactionWrapper(id: persisted.id, date: persisted.date, transaction: transaction)
    } catch {
      log.error("Failed to load transaction from \(file.lastPathComponent)", error: error)
      deleteFile(file) // Clean up corrupted file
      return nil
    }
  }

  func decodeTransaction(type: String, data: Data) throws -> any Transaction2 {
    return try TransactionTypeRegistry.decodeTransaction(type: type, data: data)
  }

  func transactionDirectory() -> URL {
    let directory = FileHelpers.getApplicationSupportDirectory()
      .appendingPathComponent("TransactionQueue", isDirectory: true)

    // Create directory if needed
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )

    return directory
  }

  func fileURL(for transactionId: TransactionId) -> URL {
    transactionDirectory().appendingPathComponent("\(transactionId.toString()).json")
  }

  func deleteFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

// MARK: - Simple Data Structure

private struct StoredTransaction: Codable {
  let id: TransactionId
  let date: Date
  let type: String
  let transactionData: Data
}

