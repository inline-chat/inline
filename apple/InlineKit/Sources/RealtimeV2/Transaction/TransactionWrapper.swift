import Foundation

// Wrap automatically generated transaction code
struct TransactionWrapper: Sendable, Identifiable {
  /// ID of the transaction
  let id: TransactionId

  /// Date of initial creation
  var date: Date

  /// Transaction to execute
  var transaction: any Transaction

  init(transaction: some Transaction) {
    id = .generate()
    date = Date()
    self.transaction = transaction
  }
}
