import Combine
import Foundation
import Testing
@testable import InlineKit

@Suite("Upload Progress Event")
struct UploadProgressEventTests {
  @Test("fraction is zero when total bytes is zero")
  func zeroTotalFraction() {
    let event = UploadProgressEvent(
      id: "video_1",
      phase: .uploading,
      bytesSent: 500,
      totalBytes: 0
    )

    #expect(event.fraction == 0)
  }

  @Test("fraction is clamped between 0 and 1")
  func fractionClamping() {
    let negative = UploadProgressEvent(
      id: "video_1",
      phase: .uploading,
      bytesSent: -10,
      totalBytes: 100
    )
    #expect(negative.fraction == 0)

    let over = UploadProgressEvent(
      id: "video_1",
      phase: .uploading,
      bytesSent: 200,
      totalBytes: 100
    )
    #expect(over.fraction == 1)
  }

  @MainActor
  @Test("progress center publishes latest event")
  func progressCenterPublishesLatestEvent() {
    let id = "video_\(UUID().uuidString)"
    var seen: [UploadProgressEvent] = []

    let cancellable = UploadProgressCenter.shared
      .publisher(for: id)
      .sink { event in
        seen.append(event)
      }
    defer {
      cancellable.cancel()
      UploadProgressCenter.shared.clear(id: id)
    }

    let next = UploadProgressEvent(
      id: id,
      phase: .processing,
      bytesSent: 0,
      totalBytes: 100
    )
    UploadProgressCenter.shared.publish(next)

    #expect(seen.contains(next))
  }
}
