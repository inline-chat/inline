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
    canceledTransactionIds.append(transactionId)
    guard let transaction = queue.first(where: { $0.id == transactionId }) else { return }

    // Remove from queue if not yet started
    queue.removeAll { $0.id == transactionId }

    // Rollback
    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
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
    Task.detached { [weak self] in
      guard let self else { return }
      do {
        let result = try await executeWithRetry(transaction)

        await transaction.didSucceed(result: result)
        await completionHandler?(transaction)
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

    while attempts < transaction.config.maxRetries {
      if canceledTransactionIds.contains(transaction.id) {
        throw TransactionError.canceled
      }
      do {
        return try await transaction.execute()
      } catch {
        if transaction.shouldRetryOnFail(error: error) {
          attempts += 1
          if attempts < transaction.config.maxRetries {
            try await Task.sleep(nanoseconds: UInt64(transaction.config.retryDelay * 1_000_000_000))
          } else {
            throw error
          }
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
      waitingContinuation = continuation
    }
  }
}
