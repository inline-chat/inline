import Foundation

/// Runs transactions, retry, etc
actor TransactionsActor {
  // MARK: - Types
  
  typealias CompletionHandler = (any Transaction) -> Void
  
  // MARK: - Private Properties
  
  private var isRunning = false
  private var queue: [any Transaction] = []
  private var currentTask: Task<Void, Never>?
  
  // Use a continuation to signal when new items are added
  private var waitingContinuation: CheckedContinuation<Void, Never>?
  
  // Return when done
  private var completionHandler: CompletionHandler?

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
      await self.processQueue()
    }
  }

  // MARK: - Public Methods
  
  func setCompletionHandler(_ handler: @escaping CompletionHandler) {
    completionHandler = handler
  }
  
  func cancel(transactionId: String) {
    guard let transaction = queue.first(where: { $0.id == transactionId }) else { return }
    
    // Remove from queue if not yet started
    queue.removeAll { $0.id == transactionId }
    
    // Rollback
    Task {
      await transaction.rollback()
      completionHandler?(transaction)
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

  public func run<T: Transaction>(transaction: T) async {
    do {
      // Simple execution
      // let result = try await transaction.execute()
      
      // Basic retry logic
      let result = try await executeWithRetry(transaction)
      
      // TODO: Proper smart retry
      await transaction.didSucceed(result: result)
      completionHandler?(transaction)
      
    } catch {
      await transaction.didFail(error: error)
    }
  }
  
  private func executeWithRetry<T: Transaction>(_ transaction: T) async throws -> T.R {
    var attempts = 0
    
    while attempts < transaction.config.maxRetries {
      do {
        return try await transaction.execute()
      } catch {
        attempts += 1
        if attempts < transaction.config.maxRetries {
          try await Task.sleep(nanoseconds: UInt64(transaction.config.retryDelay * 1_000_000_000))
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
        Task { [self] in
          await self.run(transaction: transaction)
        }
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
