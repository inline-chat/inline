import Combine
import Foundation
@testable import InlineKit
import Testing

private struct UploadProgressPublisherBox: @unchecked Sendable {
  let publisher: AnyPublisher<UploadProgressSnapshot, Never>
}

private extension FileUploader {
  func documentProgressPublisherBox(documentLocalId: Int64) -> UploadProgressPublisherBox {
    UploadProgressPublisherBox(publisher: documentProgressPublisher(documentLocalId: documentLocalId))
  }
}

@Suite("Media session lifetime", .serialized)
struct MediaSessionLifetimeTests {
  @Test("terminal state keys stay bounded and refresh recency")
  func terminalStateKeysStayBounded() {
    var keys = BoundedTerminalStateKeys(limit: 2)

    #expect(keys.record("photo_1").isEmpty)
    #expect(keys.record("photo_2").isEmpty)
    #expect(keys.record("photo_1").isEmpty)
    #expect(keys.record("photo_3") == ["photo_2"])
    #expect(keys.keys == ["photo_1", "photo_3"])
  }

  @Test("download progress recognizes both cancellation representations")
  func downloadCancellationClassification() {
    #expect(DownloadProgress.failed(id: "doc_1", error: CancellationError()).isCancellation)
    #expect(DownloadProgress.failed(id: "doc_2", error: URLError(.cancelled)).isCancellation)
    #expect(!DownloadProgress.failed(id: "doc_3", error: URLError(.timedOut)).isCancellation)
  }

  @Test("download progress callbacks are capped")
  func downloadProgressIsThrottled() {
    let throttler = DownloadProgressThrottler(maxUpdatesPerSecond: 10)

    #expect(throttler.shouldPublish(id: "doc_1", now: 1))
    #expect(!throttler.shouldPublish(id: "doc_1", now: 1.05))
    #expect(throttler.shouldPublish(id: "doc_1", now: 1.1))
    #expect(throttler.shouldPublish(id: "doc_2", now: 1.05))
  }

  @Test("transport progress stays nonterminal until finalization")
  func downloadTransportProgressIsNonterminal() {
    let progress = DownloadProgress.transferring(id: "doc_1", bytesReceived: 100, totalBytes: 100)

    #expect(progress.progress == 1)
    #expect(!progress.isComplete)
    #expect(progress.error == nil)
  }

  @Test("missing remote photo URL never retains a message")
  func missingPhotoURLDoesNotRetainMessage() async {
    let photoID: Int64 = 9_900_001
    let photo = PhotoInfo(
      photo: Photo(photoId: photoID, format: .jpeg),
      sizes: [PhotoSize(photoId: photoID, type: "f", width: 10, height: 10)]
    )

    await FileCache.shared.download(photo: photo, reloadMessageOnFinish: .preview)

    #expect(await FileCache.shared.retainedReloadMessageCount(photoId: photoID) == 0)
  }

  @Test("publisher-only media IDs stay bounded")
  @MainActor
  func publisherOnlyMediaIDsStayBounded() async {
    await FileUploader.shared.cancelAll()
    await FileDownloader.shared.resetSession()

    for id in 0 ..< 300 {
      _ = await FileUploader.shared.documentProgressPublisherBox(documentLocalId: Int64(9_910_000 + id))
      _ = FileDownloader.shared.documentProgressPublisher(documentId: Int64(9_920_000 + id))
    }

    #expect(
      await FileUploader.shared.retainedProgressPublisherCount()
        <= FileUploader.inactivePublisherRetentionLimit
    )
    #expect(
      FileDownloader.shared.retainedProgressPublisherCount()
        <= FileDownloader.inactivePublisherRetentionLimit
    )

    await FileUploader.shared.cancelAll()
    await FileDownloader.shared.resetSession()
  }

  @Test("rapid media publisher resubscription stays connected")
  @MainActor
  func rapidMediaPublisherResubscriptionStaysConnected() async {
    await FileUploader.shared.cancelAll()
    await FileDownloader.shared.resetSession()

    let uploadPublisher = await FileUploader.shared
      .documentProgressPublisherBox(documentLocalId: 9_930_001)
      .publisher
    var uploadSubscription: AnyCancellable? = uploadPublisher.sink { _ in }
    let downloadPublisher = FileDownloader.shared.documentProgressPublisher(documentId: 9_940_001)
    var downloadSubscription: AnyCancellable? = downloadPublisher.sink { _ in }

    await waitForSubscriberBookkeeping()
    #expect(await FileUploader.shared.retainedProgressPublisherCount() == 1)
    #expect(FileDownloader.shared.retainedProgressPublisherCount() == 1)

    uploadSubscription?.cancel()
    uploadSubscription = nil
    downloadSubscription?.cancel()
    downloadSubscription = nil

    uploadSubscription = uploadPublisher.sink { _ in }
    downloadSubscription = downloadPublisher.sink { _ in }

    await waitForSubscriberBookkeeping()
    #expect(await FileUploader.shared.retainedProgressPublisherCount() == 1)
    #expect(FileDownloader.shared.retainedProgressPublisherCount() == 1)

    uploadSubscription?.cancel()
    downloadSubscription?.cancel()
    await FileUploader.shared.cancelAll()
    await FileDownloader.shared.resetSession()
  }

  @MainActor
  private func waitForSubscriberBookkeeping() async {
    for _ in 0 ..< 20 {
      await Task.yield()
    }
  }
}
