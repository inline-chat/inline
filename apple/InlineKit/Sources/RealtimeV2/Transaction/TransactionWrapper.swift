import Foundation

// Wrap automatically generated transaction code
public struct TransactionWrapper: Sendable, Identifiable {
  /// ID of the transaction
  public let id: TransactionId

  /// Date of initial creation
  public let date: Date

  /// Transaction to execute
  public let transaction: any Transaction

  init(transaction: some Transaction) {
    id = .generate()
    date = Date()
    self.transaction = transaction
  }
  
  // Public initializer for deserialization
  public init(id: TransactionId, date: Date, transaction: any Transaction) {
    self.id = id
    self.date = date
    self.transaction = transaction
  }
}
