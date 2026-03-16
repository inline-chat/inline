import Foundation
import Testing
@testable import InlineKit

@Suite("Notion task progress tracker")
struct NotionTaskProgressTrackerTests {
  @Test("stops emitting progress updates after completion and cancellation")
  func stopsAfterCompletionAndCancellation() async {
    let delegate = RecordingNotionTaskDelegate()
    let tracker = NotionTaskProgressTracker(delegate: delegate)

    let progressTask = Task {
      await tracker.startProgress()
    }

    try? await Task.sleep(nanoseconds: 20_000_000)
    await tracker.completeProgress()
    progressTask.cancel()

    let countAfterCancel = delegate.progressEvents.count
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(countAfterCancel >= 1)
    #expect(delegate.progressEvents.count == countAfterCancel)
  }

  @Test("stops emitting progress updates after failure and cancellation")
  func stopsAfterFailureAndCancellation() async {
    let delegate = RecordingNotionTaskDelegate()
    let tracker = NotionTaskProgressTracker(delegate: delegate)

    let progressTask = Task {
      await tracker.startProgress()
    }

    try? await Task.sleep(nanoseconds: 20_000_000)
    await tracker.failProgress()
    progressTask.cancel()

    let countAfterCancel = delegate.progressEvents.count
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(countAfterCancel >= 1)
    #expect(delegate.progressEvents.count == countAfterCancel)
  }
}

private final class RecordingNotionTaskDelegate: NotionTaskManagerDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "NotionTaskProgressTrackerTests.delegate")
  private var progressEventsStorage: [String] = []

  var progressEvents: [String] {
    queue.sync { progressEventsStorage }
  }

  func showErrorToast(_ message: String, systemImage: String) {}

  func showSuccessToast(_ message: String, systemImage: String, url: String) {}

  func showSpaceSelectionSheet(spaces: [NotionSpace], completion: @escaping @Sendable (Int64) -> Void) {}

  func showProgressStep(_ step: Int, message: String, systemImage: String) {
    queue.sync {
      progressEventsStorage.append("step:\(step):\(message)")
    }
  }

  func updateProgressToast(message: String, systemImage: String) {
    queue.sync {
      progressEventsStorage.append("update:\(message)")
    }
  }
}
