import Testing
@testable import InlineKit

@Suite("File Upload Progress")
struct FileUploadProgressTests {
  @Test("uploading snapshot clamps bytes and computes fraction")
  func testUploadingSnapshotClamp() {
    let snapshot = UploadProgressSnapshot.uploading(
      id: "video_1",
      bytesSent: 2_500,
      totalBytes: 2_000
    )

    #expect(snapshot.stage == .uploading)
    #expect(snapshot.bytesSent == 2_000)
    #expect(snapshot.totalBytes == 2_000)
    #expect(snapshot.fractionCompleted == 1.0)
  }

  @Test("transport progress clamps invalid values")
  func testTransferProgressClamp() {
    let progress = ApiClient.UploadTransferProgress(
      bytesSent: -5,
      totalBytes: -10,
      fractionCompleted: 1.5
    )

    #expect(progress.bytesSent == 0)
    #expect(progress.totalBytes == 0)
    #expect(progress.fractionCompleted == 1.0)
  }

  @Test("mapTransferProgress uses logical total bytes when available")
  func testMapTransferProgressUsesLogicalTotal() {
    let transfer = ApiClient.UploadTransferProgress(
      bytesSent: 1_000,
      totalBytes: 10_000,
      fractionCompleted: 0.25
    )

    let snapshot = FileUploader.mapTransferProgress(
      uploadId: "video_42",
      transferProgress: transfer,
      logicalTotalBytes: 2_000_000
    )

    #expect(snapshot.stage == .uploading)
    #expect(snapshot.bytesSent == 500_000)
    #expect(snapshot.totalBytes == 2_000_000)
    #expect(snapshot.fractionCompleted == 0.25)
  }

  @Test("mapTransferProgress falls back to transport totals without logical size")
  func testMapTransferProgressFallbackToTransportTotals() {
    let transfer = ApiClient.UploadTransferProgress(
      bytesSent: 3_000,
      totalBytes: 2_000,
      fractionCompleted: 0.5
    )

    let snapshot = FileUploader.mapTransferProgress(
      uploadId: "video_43",
      transferProgress: transfer,
      logicalTotalBytes: 0
    )

    #expect(snapshot.stage == .uploading)
    #expect(snapshot.bytesSent == 3_000)
    #expect(snapshot.totalBytes == 3_000)
    #expect(snapshot.fractionCompleted == 1.0)
  }
}
