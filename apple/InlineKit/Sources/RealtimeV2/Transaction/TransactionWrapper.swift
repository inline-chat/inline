import Foundation

// Wrap automatically generated transaction code
struct TransactionWrapper: Sendable, Identifiable {
  /// ID of the transaction
  let id: TransactionId

  /// Date of initial creation
  var date: Date

  /// Transaction to execute
  var transaction: Transaction

  init(transaction: Transaction) {
    id = .generate()
    date = Date()
    self.transaction = transaction
  }
}
