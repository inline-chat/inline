import Foundation

/// Runs transactions, retry, etc
actor TransactionsActor {
  // MARK: - Types

  typealias CompletionHandler = @Sendable (any Transaction) -> Void

  // MARK: - Private Properties

  private var isRunning = false
  private var queue: [any Transaction] = []
  private var currentTask: Task<Void, Never>?

  // Use a continuation to signal when new items are added
  private var waitingContinuation: CheckedContinuation<Void, Never>?

  // Return when done
  private var completionHandler: CompletionHandler?

  var canceledTransactionIds: [String] = []

  // MARK: - Lifecycle

  init() {
    Task { await start() }
  }

  deinit {
    isRunning = false
    currentTask?.cancel()

    // Resume any waiting continuation
    waitingContinuation?.resume()
    waitingContinuation = nil

    // Clear the queue
    queue.removeAll()
  }

  private func start() {
    guard !isRunning else { return }
    isRunning = true

    currentTask = Task { [self] in
      await processQueue()
    }
  }

  // MARK: - Public Methods

  public func clearAll() {
    queue.removeAll()
  }

  func setCompletionHandler(_ handler: @escaping CompletionHandler) {
    completionHandler = handler
  }

  func cancel(transactionId: String) async {
    if !canceledTransactionIds.contains(transactionId) {
      canceledTransactionIds.append(transactionId)
    }
    guard let transaction = queue.first(where: { $0.id == transactionId }) else { return }

    // Remove from queue if not yet started
    queue.removeAll { $0.id == transactionId }

    // Rollback
    Task.detached(priority: .userInitiated) { [self] in
      await transaction.rollback()
      Task {
        await completionHandler?(transaction)
      }
    }
  }

  public func queue(transaction: consuming any Transaction) {
    queue.append(transaction)

    // Signal that new work is available
    if let continuation = waitingContinuation {
      waitingContinuation = nil
      continuation.resume()
    }
  }

  public func run(transaction: some Transaction) async {
    Task.detached { [self] in // capture strongly; actor instance lives for app lifetime
      do {
        let result = try await executeWithRetry(transaction)

        await transaction.didSucceed(result: result)
        await completionHandler?(transaction)
        // Cleanup any cancel markers
        await self.removeCancelMarker(transaction.id)
      } catch TransactionError.canceled {
        await transaction.rollback()
        await completionHandler?(transaction)
        return
      } catch {
        await transaction.didFail(error: error)
        await completionHandler?(transaction)
      }
    }
  }

  private func executeWithRetry<T: Transaction>(_ transaction: T) async throws -> T.R {
    var attempts = 0
    // Always allow at least one attempt even if maxRetries == 0
    let maxAttempts = max(transaction.config.maxRetries, 0) + 1

    while attempts < maxAttempts {
      // Early-exit if user canceled
      if canceledTransactionIds.contains(transaction.id) {
        throw TransactionError.canceled
      }

      do {
        // Wrap execute() in a timeout if a positive timeout is configured
        let result: T.R
        if transaction.config.executionTimeout > 0 {
          result = try await withThrowingTaskGroup(of: T.R.self) { group in
            // Task that performs the actual execution
            group.addTask {
              try await transaction.execute()
            }

            // Task that enforces the timeout
            group.addTask {
              try await Task.sleep(nanoseconds: UInt64(transaction.config.executionTimeout * 1_000_000_000))
              throw TransactionError.timeout
            }

            // Return the first finished child (throws if it threw)
            let value = try await group.next()!
            group.cancelAll()
            return value
          }
        } else {
          // No timeout requested
          result = try await transaction.execute()
        }

        return result
      } catch {
        // If error is cancel/timeout just propagate – no retry.
        if case TransactionError.canceled = error {
          throw error
        }
        if case TransactionError.timeout = error {
          throw error
        }

        // Decide if we should retry
        if transaction.shouldRetryOnFail(error: error), attempts + 1 < maxAttempts {
          attempts += 1
          try await Task.sleep(nanoseconds: UInt64(transaction.config.retryDelay * 1_000_000_000))
          continue
        } else {
          throw error
        }
      }
    }

    throw TransactionError.maxRetriesExceeded
  }

  // MARK: - Private Methods

  private func dequeue() -> (any Transaction)? {
    guard !queue.isEmpty else { return nil }
    return queue.removeFirst()
  }

  private func processQueue() async {
    while isRunning, !Task.isCancelled {
      try? Task.checkCancellation()

      if let transaction = dequeue() {
        // TODO: make it batches of 20 or sth
        // This task paralellizes the transactions
        await run(transaction: transaction)
        continue
      }

      // No work available, wait for new items
      await waitForWork()

      // Check if we were stopped while waiting
      guard isRunning else { break }
    }
  }

  private func waitForWork() async {
    await withCheckedContinuation { continuation in
      // If work arrived between the dequeue check and setting the continuation, resume immediately.
      if !queue.isEmpty {
        continuation.resume()
        return
      }

      waitingContinuation = continuation
    }
  }

  private func removeCancelMarker(_ id: String) {
    canceledTransactionIds.removeAll { $0 == id }
  }
}
