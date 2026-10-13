import Foundation

enum TransferPreparationError: LocalizedError, Sendable {
  case timedOut

  var errorDescription: String? { "Preparing this file took too long. Please try attaching it again." }
}

/// The cancellation hook stops the underlying AVFoundation operation, allowing
/// its structured task to settle before a caller releases temporary artifacts.
enum TransferPreparation {
  static func withDeadline<Value: Sendable>(
    seconds: Double,
    cancel: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
          try await Task.sleep(for: .seconds(seconds))
          cancel()
          throw TransferPreparationError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    } onCancel: {
      cancel()
    }
  }
}
