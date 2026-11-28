import AVFoundation
import CoreVideo
import Foundation
import InlineProtocol
import os
import Testing
@testable import InlineKit

private actor LiveStaging: NativeUploadStaging {
  func stage(logicalID _: String, sourceURL: URL) -> URL { sourceURL }
  func discard(logicalID _: String) {}
}

/// A server that takes a video's size at finish (CreateUploadResult.size_at_finish), checking what
/// a real one does: whole parts while the size is unknown, nothing past the last part, and a finish
/// that names the size the parts add up to.
private struct OldServerRejected: Error {}

private actor LiveServerMock: NativeUploadRPCTransport {
  private var sizeAtFinish: Bool
  /// Behaves as a server rolled back to a release without size at finish.
  func rollBack() { sizeAtFinish = false }
  private(set) var creates: [CreateUploadInput] = []
  private(set) var finishes: [FinishUploadInput] = []
  private(set) var saves: [(part: UInt32, offset: UInt32?, length: Int, at: ContinuousClock.Instant)] = []
  private(set) var cancels = 0
  private var parts: [Data: [UInt32: Data]] = [:]
  private var knownSize: [Data: UInt64] = [:]
  /// The bytes a completed upload assembled to.
  private(set) var completed: [Data] = []
  private var createCount: UInt8 = 0

  init(sizeAtFinish: Bool = true) {
    self.sizeAtFinish = sizeAtFinish
  }

  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout _: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    switch (method, input) {
    case let (.createUpload, .createUpload(create)):
      creates.append(create)
      if !sizeAtFinish, create.sha256.isEmpty || create.byteCount == 0 { throw OldServerRejected() }
      createCount += 1
      var result = CreateUploadResult()
      result.uploadID = create.hasUploadID ? create.uploadID : Data(repeating: 7, count: 15) + Data([createCount])
      result.partSize = 524_288
      result.partCount = UInt32((create.byteCount + 524_287) / 524_288)
      result.pieceGranularity = 16_384
      if sizeAtFinish { result.sizeAtFinish = true }
      if create.byteCount > 0 { knownSize[result.uploadID] = create.byteCount }
      return .createUpload(result)
    case let (.saveUploadPart, .saveUploadPart(save)):
      saves.append((save.partIndex, save.hasOffset ? save.offset : nil, save.data.count, .now))
      if knownSize[save.uploadID] == nil {
        // Size unknown: whole parts only.
        #expect(!save.hasOffset)
      }
      if save.hasOffset {
        var part = parts[save.uploadID]?[save.partIndex] ?? Data()
        let end = Int(save.offset) + save.data.count
        if part.count < end { part.append(Data(count: end - part.count)) }
        part.replaceSubrange(Int(save.offset) ..< end, with: save.data)
        parts[save.uploadID, default: [:]][save.partIndex] = part
      } else {
        parts[save.uploadID, default: [:]][save.partIndex] = save.data
      }
      return .saveUploadPart(SaveUploadPartResult())
    case (.cancelUpload, .cancelUpload):
      cancels += 1
      var result = CancelUploadResult()
      result.canceled = true
      return .cancelUpload(result)
    case let (.getUploadState, .getUploadState(input)):
      var state = GetUploadStateResult()
      state.status = .uploading
      state.acceptedParts = (parts[input.uploadID] ?? [:]).keys.sorted()
      return .getUploadState(state)
    case let (.finishUpload, .finishUpload(input)):
      finishes.append(input)
      let size = knownSize[input.uploadID] ?? (input.hasByteCount ? input.byteCount : 0)
      #expect(size > 0)
      let partCount = UInt32((size + 524_287) / 524_288)
      let held = parts[input.uploadID] ?? [:]
      #expect(held.keys.allSatisfy { $0 < partCount })
      var finish = FinishUploadResult()
      let missing = (0 ..< partCount).filter { held[$0] == nil }
      if !missing.isEmpty {
        var parts = UploadMissingParts()
        parts.partIndices = missing
        finish.missing = parts
        return .finishUpload(finish)
      }
      let assembled = (0 ..< partCount).reduce(into: Data()) { $0.append(held[$1]!) }
      #expect(UInt64(assembled.count) == size)
      completed.append(assembled)
      var complete = UploadComplete()
      complete.fileUniqueID = "INV_live"
      finish.complete = complete
      return .finishUpload(finish)
    default:
      Issue.record("Unexpected upload RPC \(method)")
      return nil
    }
  }
}

private func pattern(_ count: Int, seed: UInt8 = 0) -> Data {
  Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

private func temporaryURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("inline-live-upload-\(UUID().uuidString).mp4")
}

/// Writes `body` to `url` in chunks the way the encoder does: everything in order, the first
/// `header` bytes as zeros, patched to their real value once the rest is written.
private func writeLikeEncoder(
  _ body: Data,
  to url: URL,
  chunk: Int = 200_000,
  header: Int = 40,
  pause: Duration = .milliseconds(30),
  afterWrite: (@Sendable () async throws -> Void)? = nil
) async throws {
  FileManager.default.createFile(atPath: url.path, contents: nil)
  let handle = try FileHandle(forWritingTo: url)
  defer { try? handle.close() }
  var offset = 0
  while offset < body.count {
    let end = min(offset + chunk, body.count)
    var bytes = body.subdata(in: offset ..< end)
    if offset < header { bytes.replaceSubrange(0 ..< min(header - offset, bytes.count), with: Data(count: min(header - offset, bytes.count))) }
    try handle.write(contentsOf: bytes)
    offset = end
    try await Task.sleep(for: pause)
  }
  try await afterWrite?()
  try handle.seek(toOffset: 0)
  try handle.write(contentsOf: body.prefix(header))
}

@Suite("Native live uploads", .serialized)
struct NativeLiveUploadTests {
  private func warmed(_ server: LiveServerMock) async throws -> DurableUploadCoordinator {
    let coordinator = DurableUploadCoordinator(transport: server, staging: LiveStaging(), ownerScope: { "owner" })
    let warm = temporaryURL()
    try pattern(1_000).write(to: warm)
    defer { try? FileManager.default.removeItem(at: warm) }
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:warm", fileURL: warm, fileName: "a.bin", mimeType: "application/octet-stream", kind: .document
    ), progress: { _, _ in })
    return coordinator
  }

  private func videoMetadata() -> CreateUploadInput.OneOf_Metadata {
    var video = UploadVideoMetadata()
    video.width = 1_280
    video.height = 720
    video.duration = 12
    return .video(video)
  }

  @Test("a video uploads while it is written: parts go as they are written, the first last, size at finish")
  func streamsWhileWritten() async throws {
    let server = LiveServerMock()
    let coordinator = try await warmed(server)
    #expect(coordinator.acceptsSizeAtFinish)
    // The first create learned the trait; a file of known size now goes without a digest too.
    #expect(await server.creates.first?.sha256.count == 32)
    let plain = temporaryURL()
    try pattern(2_000).write(to: plain)
    defer { try? FileManager.default.removeItem(at: plain) }
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:plain", fileURL: plain, fileName: "p.bin", mimeType: "application/octet-stream", kind: .document
    ), progress: { _, _ in })
    let plainCreate = await server.creates.last!
    #expect(plainCreate.sha256.isEmpty)
    #expect(plainCreate.byteCount == 2_000)
    let body = pattern(524_288 * 6 + 12_345, seed: 3)
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let source = NativeLiveUploadSource()
    let writtenAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    let writer = Task {
      do {
        try await writeLikeEncoder(body, to: url)
        writtenAt.withLock { $0 = .now }
        source.finish()
      } catch {
        source.fail(error)
      }
    }
    let savesBefore = await server.saves.count
    // The upload starts as soon as the encode does.
    try await Task.sleep(for: .milliseconds(20))
    let progress = ProgressRecorder()
    let complete = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "video:live", fileURL: url, fileName: "live.mp4", mimeType: "video/mp4", kind: .video,
      metadata: videoMetadata(), liveSource: source
    ), progress: { sent, total in progress.record(sent, total) })
    _ = await writer.value
    #expect(complete.fileUniqueID == "INV_live")
    #expect(await server.completed.last == body)
    let create = await server.creates.last!
    #expect(create.byteCount == 0)
    #expect(create.sha256.isEmpty)
    #expect(await server.finishes.last?.byteCount == UInt64(body.count))
    let saves = Array(await server.saves.dropFirst(savesBefore))
    // Part 0 (its first bytes rewritten at the end) goes only once the file is final, and once;
    // full parts went while it was still being written.
    let written = try #require(writtenAt.withLock { $0 })
    let zeros = saves.filter { $0.part == 0 }
    #expect(zeros.count == 1)
    #expect(zeros.allSatisfy { $0.at > written })
    #expect(saves.contains { $0.part > 0 && $0.at < written })
    #expect(saves.allSatisfy { $0.offset == nil })
    // Progress ends at the real size.
    #expect(progress.last?.total == Int64(body.count))
  }

  @Test("a sent part the writer changed fails the live upload, which cancels it")
  func changedPartFails() async throws {
    let server = LiveServerMock()
    let coordinator = try await warmed(server)
    let body = pattern(524_288 * 4 + 100, seed: 5)
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let source = NativeLiveUploadSource()
    let writer = Task {
      do {
        try await writeLikeEncoder(body, to: url, afterWrite: {
          // Wait for part 2 to be sent, then rewrite a byte in it.
          while !(await server.saves.contains { $0.part == 2 }) { try await Task.sleep(for: .milliseconds(5)) }
          let handle = try FileHandle(forWritingTo: url)
          try handle.seek(toOffset: UInt64(524_288 * 2 + 10))
          try handle.write(contentsOf: Data([0xFF]))
          try handle.close()
        })
        source.finish()
      } catch {
        source.fail(error)
      }
    }
    await #expect(throws: NativeMediaUploadError.self) {
      _ = try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "video:changed", fileURL: url, fileName: "c.mp4", mimeType: "video/mp4", kind: .video,
        metadata: videoMetadata(), liveSource: source
      ), progress: { _, _ in })
    }
    _ = await writer.value
    #expect(await server.cancels == 1)
    #expect(await server.completed.count == 1) // the warm-up only
  }

  @Test("an encode that fails fails the live upload with its error")
  func writerFailure() async throws {
    struct EncodeFailed: Error {}
    let server = LiveServerMock()
    let coordinator = try await warmed(server)
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try pattern(524_288 * 2).write(to: url)
    let source = NativeLiveUploadSource()
    Task {
      try await Task.sleep(for: .milliseconds(150))
      source.fail(EncodeFailed())
    }
    await #expect(throws: EncodeFailed.self) {
      _ = try await coordinator.upload(NativeMediaUploadRequest(
        logicalID: "video:failed", fileURL: url, fileName: "f.mp4", mimeType: "video/mp4", kind: .video,
        metadata: videoMetadata(), liveSource: source
      ), progress: { _, _ in })
    }
    #expect(await server.cancels == 1)
  }

  @Test("a server without size at finish gets the finished file, the usual way")
  func oldServerWaitsForTheEncode() async throws {
    let server = LiveServerMock(sizeAtFinish: false)
    let coordinator = try await warmed(server)
    #expect(!coordinator.acceptsSizeAtFinish)
    let body = pattern(524_288 * 3 + 7, seed: 9)
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let source = NativeLiveUploadSource()
    let writer = Task {
      try await writeLikeEncoder(body, to: url)
      source.finish()
    }
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "video:old-server", fileURL: url, fileName: "o.mp4", mimeType: "video/mp4", kind: .video,
      metadata: videoMetadata(), liveSource: source
    ), progress: { _, _ in })
    try await writer.value
    let create = await server.creates.last!
    #expect(create.byteCount == UInt64(body.count))
    #expect(create.sha256.count == 32)
    #expect(await server.completed.last == body)
  }
}

/// A source video for the encoder: moving noise, so it spends real bits, in H.264 at a bitrate
/// over the upload limit (so it is re-encoded, not remuxed).
private func makeSourceVideo(seconds: Int, width: Int = 1_280, height: Int = 720) async throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("inline-live-source-\(UUID().uuidString).mp4")
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
  ])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
  ])
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  var generator = SystemRandomNumberGenerator()
  for frame in 0 ..< 30 * seconds {
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let count = CVPixelBufferGetBytesPerRow(pixels) * height
    for index in stride(from: 0, to: count, by: 4) {
      let value = UInt8(truncatingIfNeeded: (index / 4 + frame * 7) % 251) &+ UInt8.random(in: 0 ... 40, using: &generator)
      base[index] = value; base[index + 1] = value &* 3; base[index + 2] = value &+ 90; base[index + 3] = 255
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
  }
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
  return url
}

@Suite("Native live uploads with the real encoder", .serialized)
struct NativeLiveEncodeTests {
  @Test("a re-encode uploads while it is written and arrives byte for byte, header at the end")
  func realEncoderStreams() async throws {
    let source = try await makeSourceVideo(seconds: 8)
    defer { try? FileManager.default.removeItem(at: source) }
    let options = VideoCompressionOptions(maxDimension: 1_280, videoBitrateKbps: 5_000, forceTranscode: true)
    let encode = try #require(try await VideoCompressor.shared.startLiveCompression(at: source, options: options))
    defer { try? FileManager.default.removeItem(at: encode.url) }
    #expect(encode.width == 1_280)
    #expect(encode.height == 720)
    #expect(encode.duration == 8)
    let live = NativeLiveUploadSource()
    let finishedAt = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    Task.detached {
      do {
        _ = try await encode.result.value
        finishedAt.withLock { $0 = .now }
        live.finish()
      } catch {
        live.fail(error)
      }
    }
    let server = LiveServerMock()
    let coordinator = DurableUploadCoordinator(transport: server, staging: LiveStaging(), ownerScope: { "owner" })
    let warm = temporaryURL()
    try pattern(1_000).write(to: warm)
    defer { try? FileManager.default.removeItem(at: warm) }
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "document:warm", fileURL: warm, fileName: "a.bin", mimeType: "application/octet-stream", kind: .document
    ), progress: { _, _ in })
    let savesBefore = await server.saves.count
    var video = UploadVideoMetadata()
    video.width = UInt32(encode.width)
    video.height = UInt32(encode.height)
    video.duration = UInt32(encode.duration)
    _ = try await coordinator.upload(NativeMediaUploadRequest(
      logicalID: "video:real", fileURL: encode.url, fileName: "real.mp4", mimeType: "video/mp4", kind: .video,
      metadata: .video(video), liveSource: live
    ), progress: { _, _ in })
    let result = try await encode.result.value
    let final = try Data(contentsOf: encode.url)
    #expect(await server.completed.last == final)
    #expect(result.width == encode.width && result.height == encode.height && result.duration == encode.duration)
    // Several parts went before the encoder finished.
    let finished = try #require(finishedAt.withLock { $0 })
    let early = Array(await server.saves.dropFirst(savesBefore)).filter { $0.at < finished }
    #expect(final.count > 524_288 * 4)
    #expect(early.count >= 2)
    #expect(!early.contains { $0.part == 0 })
    // The header (moov) is at the end: the file plays from byte ranges like any MP4.
    let atoms = topLevelAtoms(final)
    #expect(atoms.first == "ftyp")
    #expect(atoms.last == "moov")
  }
}

private func topLevelAtoms(_ data: Data) -> [String] {
  var atoms: [String] = []
  var offset = 0
  while offset + 8 <= data.count {
    var size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    atoms.append(String(bytes: data[(offset + 4) ..< (offset + 8)], encoding: .ascii) ?? "?")
    if size == 1, offset + 16 <= data.count { size = (8 ..< 16).reduce(0) { $0 << 8 | Int(data[offset + $1]) } }
    if size == 0 { break }
    guard size >= 8 else { break }
    offset += size
  }
  return atoms
}

@Suite("Native uploads after a server rollback")
struct NativeUploadRollbackTests {
  @Test("a create without a digest that fails forgets the trait, so the next upload sends one")
  func rollbackForgetsSizeAtFinish() async throws {
    let server = LiveServerMock()
    let coordinator = DurableUploadCoordinator(transport: server, staging: LiveStaging(), ownerScope: { "owner" })
    let file = temporaryURL()
    try pattern(3_000).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let request = { (id: String) in
      NativeMediaUploadRequest(
        logicalID: id, fileURL: file, fileName: "r.bin", mimeType: "application/octet-stream", kind: .document
      )
    }
    _ = try await coordinator.upload(request("document:learn"), progress: { _, _ in })
    #expect(coordinator.acceptsSizeAtFinish)
    await server.rollBack()
    await #expect(throws: (any Error).self) {
      _ = try await coordinator.upload(request("document:rejected"), progress: { _, _ in })
    }
    #expect(!coordinator.acceptsSizeAtFinish)
    _ = try await coordinator.upload(request("document:retry"), progress: { _, _ in })
    #expect(await server.creates.last?.sha256.count == 32)
    #expect(await server.completed.count == 2)
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [(sent: Int64, total: Int64)] = []

  func record(_ sent: Int64, _ total: Int64) {
    lock.withLock { values.append((sent, total)) }
  }

  var last: (sent: Int64, total: Int64)? { lock.withLock { values.last } }
}
