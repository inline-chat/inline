@testable import InlineKit
import XCTest

final class TransactionsTests: XCTestCase {
  var transactions: Transactions!

  override func setUp() async throws {
    transactions = Transactions.shared
  }

  override func tearDown() async throws {
    // Clean up persisted transactions
    let fileManager = FileManager.default
    let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("transactions.json")
    try? fileManager.removeItem(at: documentsURL)
  }

  func testOptimisticExecution() async throws {
    // Given
    let expectation = XCTestExpectation(description: "Message status updated")

    let transaction = MockMessageTransaction(
      id: "test-1",
      text: "Hello"
    )

    // When
    transactions.mutate(transaction: .mockMessage(transaction))

    // Then
    XCTAssertEqual(MockMessageCache.shared.messages.count, 1)
    XCTAssertEqual(MockMessageCache.shared.messages.first?.status, .sending)
  }

  func testTransactionSuccess() async throws {
    // Given
    let transaction = MockMessageTransaction(
      id: "test-2",
      text: "Hello",
      shouldSucceed: true
    )

    // When
    transactions.mutate(transaction: .mockMessage(transaction))

    // Wait for async execution
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Then
    XCTAssertEqual(MockMessageCache.shared.messages.count, 1)
    XCTAssertEqual(MockMessageCache.shared.messages.first?.status, .sent)
  }

  func testTransactionFailure() async throws {
    // Given
    let transaction = MockMessageTransaction(
      id: "test-3",
      text: "Hello",
      shouldSucceed: false
    )

    // When
    transactions.mutate(transaction: .mockMessage(transaction))

    // Wait for async execution
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Then
    XCTAssertEqual(MockMessageCache.shared.messages.count, 1)
    XCTAssertEqual(MockMessageCache.shared.messages.first?.status, .failed)
  }

  func testTransactionCancellation() async throws {
    // Given
    let transaction = MockMessageTransaction(
      id: "test-4",
      text: "Hello",
      executionDelay: 2
    )

    // When
    transactions.mutate(transaction: .mockMessage(transaction))

    // Cancel immediately
    transactions.cancel(transactionId: "test-4")

    // Wait for async execution
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Then
    XCTAssertTrue(MockMessageCache.shared.messages.isEmpty)
  }

//
//  func testDuplicateTransaction() async throws {
//    // Given
//    let messageCache = MockMessageCache()
//    let transaction = MockMessageTransaction(
//      id: "test-5",
//      text: "Hello",
  ////    )
//
//    // When
//    transactions.mutate(transaction: transaction)
//
//    // Then
//    await XCTAssertThrowsError(transactions.mutate(transaction: transaction)) { error in
//      XCTAssertEqual(error as? TransactionError, .duplicate)
//    }
//  }

  func testPersistence() async throws {
    // Given
    let transaction = MockMessageTransaction(
      id: "test-6",
      text: "Hello",
      executionDelay: 2
    )

    // When
    transactions.mutate(transaction: .mockMessage(transaction))

    // Create new instance to test loading from disk
    let newTransactions = Transactions()

    // Then
    let count = newTransactions.cache.transactions.count
    let firstId = newTransactions.cache.transactions.first?.transaction.id
    XCTAssertEqual(count, 1)
    XCTAssertEqual(firstId, "test-6")
  }
}

// MARK: - Test Doubles
