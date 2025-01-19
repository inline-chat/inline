enum TransactionError: Error {
  case duplicate
  case maxRetriesExceeded
}
