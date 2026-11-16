import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

/// Serves a file's parts, holding back the gated offsets until released.
private actor StreamPartMock: NativeFilePartFetching {
  let bytes: Data
  private var gated: Set<UInt64>
  private var gates: [UInt64: CheckedContinuation<Void, Never>] = [:]
  private(set) var requested: [UInt64] = []
  private var requestWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

  init(bytes: Data, gated: Set<UInt64> = []) {
    self.bytes = bytes
    self.gated = gated
  }

  func fetchFilePart(_ input: GetFilePartInput, timeout _: Duration) async throws -> GetFilePartResult {
    requested.append(input.offset)
    requestWaiters.removeValue(forKey: input.offset)?.forEach { $0.resume() }
    if gated.contains(input.offset) {
      await withCheckedContinuation { gates[input.offset] = $0 }
    }
    try Task.checkCancellation()
    var part = GetFilePartResult()
    part.offset = input.offset
    part.totalSize = UInt64(bytes.count)
    let end = min(bytes.count, Int(input.offset) + Int(input.limit))
    part.data = bytes.subdata(in: Int(input.offset) ..< end)
    part.sha256 = Data(SHA256.hash(data: part.data))
    return part
  }

  func waitForRequest(_ offset: UInt64) async {
    if requested.contains(offset) { return }
    await withCheckedContinuation { requestWaiters[offset, default: []].append($0) }
  }

  func release(_ offset: UInt64) {
    gated.remove(offset)
    gates.removeValue(forKey: offset)?.resume()
  }
}

@Suite("Native video stream", .serialized, .timeLimit(.minutes(1)))
struct NativeVideoStreamTests {
  private let part = UInt64(NativeFileDownloader.partSize)

  @Test func readsWaitForTheirPartsWhichGoOutFromTheReadPositionThenMoveToTheFinishedFile() async throws {
    let directory = try streamDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data((0 ..< Int(part) * 3 + 100).map { UInt8($0 % 249) })
    let mock = StreamPartMock(bytes: bytes, gated: [0, part, part * 2, part * 3])
    // One slot, so the order parts go out in is the order the scheduler chose.
    let manager = NativeDownloadManager(window: 1 ... 1)
    let message = messageLocation()
    let destination = directory.appendingPathComponent("video.mp4")
    let download = Task {
      try await manager.download(.init(
        accountID: 1, fileUniqueID: "INP_stream", message: message, destination: destination, transport: mock
      ))
    }
    let target = NativeDownloadManager.StreamTarget(accountID: 1, message: message, directory: directory)
    let reader = UUID()
    let read = Task { try await manager.streamBytes(target, reader: reader, offset: part * 2 + 10, length: 20) }
    await mock.waitForRequest(0)
    while await manager.waitingReads == 0 { await Task.yield() }

    // After the first range, the read's part goes out before the parts it skipped.
    await mock.release(0)
    await mock.waitForRequest(part * 2)
    #expect(await mock.requested == [0, part * 2])
    await mock.release(part * 2)
    let (source, total) = try await read.value
    #expect(total == UInt64(bytes.count))
    guard case let .partial(body) = source else { Issue.record("expected the downloading body"); return }
    let handle = try FileHandle(forReadingFrom: body)
    try handle.seek(toOffset: part * 2 + 10)
    #expect(try handle.read(upToCount: 20) == bytes.subdata(in: Int(part * 2) + 10 ..< Int(part * 2) + 30))
    try handle.close()

    await mock.release(part * 3)
    await mock.waitForRequest(part)
    #expect(await mock.requested == [0, part * 2, part * 3, part])
    await mock.release(part)
    #expect(try await download.value == destination)
    let finished = try await manager.streamBytes(target, reader: reader, offset: 0, length: 10)
    #expect(finished.source == .complete(destination))
    #expect(finished.total == UInt64(bytes.count))
    await manager.endReading(reader)
  }

  @Test func aFailedDownloadFailsItsWaitingReadsAndOnlyThoseOfItsOwnReader() async throws {
    let directory = try streamDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = NativeDownloadManager()
    let target = NativeDownloadManager.StreamTarget(accountID: 1, message: messageLocation(), directory: directory)
    let reader = UUID(), reopened = UUID()
    let read = Task { try await manager.streamBytes(target, reader: reader, offset: 0, length: 0) }
    let other = Task { try await manager.streamBytes(target, reader: reopened, offset: 0, length: 0) }
    while await manager.waitingReads < 2 { await Task.yield() }
    await manager.finishReads(reader, result: .failure(URLError(.notConnectedToInternet)))
    await #expect(throws: URLError.self) { try await read.value }
    // A stream reopened on the same video keeps waiting for its own download.
    #expect(await manager.waitingReads == 1)
    other.cancel()
    await #expect(throws: CancellationError.self) { try await other.value }
  }

  @Test func aDownloadThatEndsBeforeTheFirstReadStillAnswersIt() async throws {
    let directory = try streamDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("video.mp4")
    try Data(repeating: 7, count: 1_000).write(to: file)
    let manager = NativeDownloadManager()
    let target = NativeDownloadManager.StreamTarget(accountID: 1, message: messageLocation(), directory: directory)
    let reader = UUID()
    await manager.finishReads(reader, result: .success(file))
    let answer = try await manager.streamBytes(target, reader: reader, offset: 0, length: 0)
    #expect(answer.source == .complete(file))
    #expect(answer.total == 1_000)
    await manager.endReading(reader)
    #expect(await manager.waitingReads == 0)
  }

  @Test func servingCrossesPartsAndMovesToTheFinishedFileWhenTheBodyIsGone() async throws {
    let directory = try streamDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data((0 ..< Int(part) * 2 + 7).map { UInt8($0 % 251) })
    let file = directory.appendingPathComponent("finished.mp4")
    try bytes.write(to: file)
    let movedBody = directory.appendingPathComponent("gone.inline-partial")
    var asked: [(UInt64, UInt64)] = []
    var served = Data()
    try await NativeVideoStream.serve(
      from: part - 5, to: nil,
      bytes: { offset, length in
        asked.append((offset, length))
        // The first answer names a body that has already moved.
        return (asked.count == 1 ? .partial(movedBody) : .complete(file), UInt64(bytes.count))
      },
      respond: { served.append($0) }
    )
    #expect(served == bytes.subdata(in: Int(part) - 5 ..< bytes.count))
    #expect(asked.map(\.0) == [part - 5, part - 5, part, part * 2])

    var ranged = Data()
    try await NativeVideoStream.serve(
      from: 3, to: 9, bytes: { _, _ in (.complete(file), UInt64(bytes.count)) }, respond: { ranged.append($0) }
    )
    #expect(ranged == bytes.subdata(in: 3 ..< 9))
  }

  @Test func avFoundationLoadsAVideoWhileAMiddlePartIsStillDownloading() async throws {
    let directory = try streamDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mp4")
    try await writeTestVideo(to: source)
    let bytes = try Data(contentsOf: source)
    #expect(bytes.count > Int(part) * 3)
    // Metadata sits at the end of this file, so the player must read past the stalled part.
    let mock = StreamPartMock(bytes: bytes, gated: [part])
    let manager = NativeDownloadManager()
    let message = messageLocation()
    let destination = directory.appendingPathComponent("video.mp4")
    let download = Task {
      try await manager.download(.init(
        accountID: 1, fileUniqueID: "INP_avstream", message: message, destination: destination, transport: mock
      ))
    }
    let stream = NativeVideoStream(
      target: .init(accountID: 1, message: message, directory: directory), manager: manager
    )
    let duration = try await stream.asset.load(.duration)
    #expect(abs(duration.seconds - 2) < 0.1)
    #expect(try await stream.asset.loadTracks(withMediaType: .video).count == 1)
    #expect(!FileManager.default.fileExists(atPath: destination.path))

    await mock.release(part)
    #expect(try await download.value == destination)
    #expect(try Data(contentsOf: destination) == bytes)
    stream.close()
  }

  private func streamDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-video-stream-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func messageLocation() -> FileMessageLocation {
    var message = FileMessageLocation()
    message.chatID = 7
    message.messageID = 8
    return message
  }
}

/// Two seconds of noise at a high bitrate, so the file spans several parts, written with its
/// metadata at the end as a camera would.
private func writeTestVideo(to url: URL) async throws {
  let side = 320
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  writer.shouldOptimizeForNetworkUse = false
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
  ])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
  ])
  writer.add(input)
  guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
  writer.startSession(atSourceTime: .zero)
  var random = SystemRandomNumberGenerator()
  for frame in 0 ..< 48 {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    var created: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
    guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      let words = CVPixelBufferGetDataSize(buffer) / 8
      let pixels = base.bindMemory(to: UInt64.self, capacity: words)
      for index in 0 ..< words { pixels[index] = random.next() }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
      throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
  }
  input.markAsFinished()
  await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}
