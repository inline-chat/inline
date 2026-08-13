import Foundation
import Logger
import RealtimeV2

/// Simple file-based persistence for transactions
public struct DefaultTransactionPersistenceHandler: TransactionPersistenceHandler {
  private let log = Log.scoped("TransactionPersistence")
  private let baseDirectory: URL?

  public init() {
    baseDirectory = nil
  }

  init(baseDirectory: URL) {
    self.baseDirectory = baseDirectory
  }

  public func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    let data = try encodeTransaction(transaction)
    let url = fileURL(for: transaction.id, owner: owner)
    try data.write(to: url, options: .atomic)
  }

  public func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {
    let url = fileURL(for: transactionId, owner: owner)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  public func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] {
    let unscopedLegacyCount = try unscopedLegacyTransactionCount()
    if unscopedLegacyCount > 0 {
      log.warning("Ignoring \(unscopedLegacyCount) unscoped legacy transaction file(s)")
    }

    let files = try getTransactionFiles(owner: owner)
    var transactions: [TransactionWrapper] = []

    for file in files {
      guard let transaction = loadTransaction(from: file) else { continue }
      transactions.append(transaction)
    }

    return transactions
  }

  public func deleteAllTransactions(for owner: TransactionOwner) async throws {
    let directory = transactionDirectory(owner: owner, createIfNeeded: false)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }
}

// MARK: - Private Implementation

private extension DefaultTransactionPersistenceHandler {
  func encodeTransaction(_ wrapper: TransactionWrapper) throws -> Data {
    let persistedData = StoredTransaction(
      id: wrapper.id,
      date: wrapper.date,
      rpcErrorRetryCount: wrapper.rpcErrorRetryCount,
      type: TransactionTypeRegistry.typeString(for: wrapper.transaction),
      transactionData: try JSONEncoder().encode(wrapper.transaction)
    )
    return try JSONEncoder().encode(persistedData)
  }

  func getTransactionFiles(owner: TransactionOwner) throws -> [URL] {
    let directory = transactionDirectory(owner: owner, createIfNeeded: true)
    return try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
  }

  func loadTransaction(from file: URL) -> TransactionWrapper? {
    do {
      let data = try Data(contentsOf: file)
      let persisted = try JSONDecoder().decode(StoredTransaction.self, from: data)
      let transaction = try decodeTransaction(type: persisted.type, data: persisted.transactionData)
      return TransactionWrapper(
        id: persisted.id,
        date: persisted.date,
        transaction: transaction,
        rpcErrorRetryCount: persisted.rpcErrorRetryCount ?? 0
      )
    } catch {
      log.error("Failed to load transaction from \(file.lastPathComponent)", error: error)
      deleteFile(file) // Clean up corrupted file
      return nil
    }
  }

  func decodeTransaction(type: String, data: Data) throws -> any Transaction2 {
    return try TransactionTypeRegistry.decodeTransaction(type: type, data: data)
  }

  func transactionDirectory(owner: TransactionOwner, createIfNeeded: Bool) -> URL {
    let directory = transactionRootDirectory()
      .appendingPathComponent("account-\(owner.accountID)", isDirectory: true)

    if createIfNeeded {
      try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    return directory
  }

  func transactionRootDirectory() -> URL {
    baseDirectory ?? FileHelpers.getApplicationSupportDirectory()
      .appendingPathComponent("TransactionQueue", isDirectory: true)
  }

  func unscopedLegacyTransactionCount() throws -> Int {
    let rootDirectory = transactionRootDirectory()
    guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return 0 }

    return try FileManager.default
      .contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
      .count { $0.pathExtension == "json" }
  }

  func fileURL(for transactionId: TransactionId, owner: TransactionOwner) -> URL {
    transactionDirectory(owner: owner, createIfNeeded: true)
      .appendingPathComponent("\(transactionId.toString()).json")
  }

  func deleteFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

// MARK: - Simple Data Structure

private struct StoredTransaction: Codable {
  let id: TransactionId
  let date: Date
  let rpcErrorRetryCount: Int?
  let type: String
  let transactionData: Data
}
