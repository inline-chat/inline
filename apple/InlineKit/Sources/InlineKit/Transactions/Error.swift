enum TransactionError: Error {
  case duplicate
  case maxRetriesExceeded
  case canceled
  case timeout
}
