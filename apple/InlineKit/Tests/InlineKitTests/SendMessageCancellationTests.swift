import Foundation
import Testing
@testable import InlineKit

@Suite("Send message cancellation")
struct SendMessageCancellationTests {
  @Test("cancelling an upload wait exits promptly without stopping a shared transfer or sending")
  func cancellationDetachesFromSharedUpload() async throws {
    let probe = UploadCancellationProbe()
    let gate = UploadCompletionGate()
    let upload = Task<UploadResult, any Error> {
      await gate.wait()
      return UploadResult(photoId: 123)
    }
    let send = Task {
      do {
        _ = try await SendMessageUploadCoordinator.waitForUpload(upload)
        await probe.sent()
        await probe.finished()
      } catch {
        await probe.finished()
        throw error
      }
    }
    defer { upload.cancel(); send.cancel() }
    try await waitForUploadCondition { await gate.waiting }

    send.cancel()
    // The transfer is still blocked, so this proves cancellation does not wait
    // for an independently owned upload to finish.
    try await waitForUploadCondition { await probe.didFinish }
    await #expect(throws: CancellationError.self) { try await send.value }
    #expect(await probe.didSend == false)
    #expect(upload.isCancelled == false)
    await gate.release()
    #expect(try await upload.value.photoId == 123)
  }

  @Test("an already cancelled send does not start an upload")
  func cancelledSendDoesNotStartUpload() async {
    let probe = UploadCancellationProbe()
    let send = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await SendMessageUploadCoordinator.beginOrJoinUpload {
        await probe.started()
        return 123
      }
    }

    await #expect(throws: CancellationError.self) { try await send.value }
    #expect(await probe.hasStarted == false)
  }

  @Test("cancellation wins over a transfer that returns success after cancellation")
  func lateUploadSuccessDoesNotSend() async throws {
    let gate = UploadCompletionGate()
    let upload = Task<UploadResult, any Error> {
      await gate.wait()
      // Model a transport that finishes successfully despite cancellation.
      return UploadResult(photoId: 456)
    }
    let send = Task { try await SendMessageUploadCoordinator.waitForUpload(upload) }
    defer { upload.cancel(); send.cancel() }
    try await waitForUploadCondition { await gate.waiting }

    send.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) { try await send.value }
  }

  @Test("successful uploads retain their server media identity")
  func successfulUploadReturnsIdentity() async throws {
    let upload = Task<UploadResult, any Error> { UploadResult(photoId: 789) }
    let result = try await SendMessageUploadCoordinator.waitForUpload(upload)
    #expect(result.photoId == 789)
  }

  @Test("upload failures remain failures")
  func uploadErrorIsPreserved() async {
    let upload = Task<UploadResult, any Error> { throw FileUploadError.invalidPhoto }
    await #expect(throws: FileUploadError.invalidPhoto) {
      try await SendMessageUploadCoordinator.waitForUpload(upload)
    }
  }

  @Test("a cancelled final attempt rolls back instead of marking the message failed")
  func cancelledFinalAttemptRollsBack() async throws {
    let id = UUID().uuidString
    let actor = TransactionsActor()
    let transaction = CancelledTransferTransaction(id: id)
    await actor.queue(transaction: transaction)
    try await waitForUploadCondition { await CancelledTransferProbe.shared.startedIDs.contains(id) }

    await actor.cancel(transactionId: id)
    try await waitForUploadCondition { await CancelledTransferProbe.shared.rolledBackIDs.contains(id) }

    #expect(await CancelledTransferProbe.shared.failedIDs.contains(id) == false)
  }
}

private actor UploadCancellationProbe {
  var hasStarted = false
  var didFinish = false
  var didSend = false
  func started() { hasStarted = true }
  func finished() { didFinish = true }
  func sent() { didSend = true }
}

private actor UploadCompletionGate {
  var waiting = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { continuation in
      waiting = true
      self.continuation = continuation
    }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct CancelledTransferTransaction: Transaction {
  let id: String
  var date = Date()
  var config = TransactionConfig(maxRetries: 0, retryDelay: 0, executionTimeout: 0)

  func optimistic() {}
  func execute() async throws {
    await CancelledTransferProbe.shared.started(id)
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      // Real transports may represent cancellation as URLError rather than CancellationError.
      throw URLError(.cancelled)
    }
  }
  func didSucceed(result _: Void) async {}
  func shouldRetryOnFail(error _: any Error) -> Bool { true }
  func didFail(error _: (any Error)?) async { await CancelledTransferProbe.shared.failed(id) }
  func rollback() async { await CancelledTransferProbe.shared.rolledBack(id) }
}

private actor CancelledTransferProbe {
  static let shared = CancelledTransferProbe()
  var startedIDs: Set<String> = []
  var rolledBackIDs: Set<String> = []
  var failedIDs: Set<String> = []
  func started(_ id: String) { startedIDs.insert(id) }
  func rolledBack(_ id: String) { rolledBackIDs.insert(id) }
  func failed(_ id: String) { failedIDs.insert(id) }
}

private func waitForUploadCondition(_ condition: @escaping @Sendable () async -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(2)
  while await condition() == false {
    guard clock.now < deadline else { throw UploadConditionTimeout() }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private struct UploadConditionTimeout: Error {}
