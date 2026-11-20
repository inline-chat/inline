import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import InlineKit

@Suite("Video Compression")
struct VideoCompressionTests {
  @Test("normalizes mov input to mp4 without changing dimensions")
  func testNormalizeToMP4() async throws {
    let videoURL = try await makeTestVideoURL(frameCount: 20, fileType: .mov)
    defer { try? FileManager.default.removeItem(at: videoURL) }

    let result = try await VideoCompressor.shared.normalizeToMP4(at: videoURL)
    defer { try? FileManager.default.removeItem(at: result.url) }

    #expect(result.url.pathExtension.lowercased() == "mp4")
    #expect(result.width == 64)
    #expect(result.height == 64)
    #expect(result.duration > 0)
    #expect(result.fileSize > 0)
  }

  @Test("an H.264 video within limits is remuxed, not re-encoded, and loses its location")
  func remuxesWithinLimits() async throws {
    let videoURL = try await makeTestVideoURL(fileType: .mov, metadata: cameraMetadata())
    defer { try? FileManager.default.removeItem(at: videoURL) }
    #expect(await VideoCompressor.content(of: videoURL) == .camera)

    let result = try await VideoCompressor.shared.compressVideo(at: videoURL, options: .upload(for: .camera))
    defer { try? FileManager.default.removeItem(at: result.url) }

    #expect(result.url != videoURL)
    #expect(result.url.pathExtension == "mp4")
    #expect(result.width == 64)
    #expect(try await identifyingMetadata(at: result.url).isEmpty)
  }

  @Test("a video over the size limit is re-encoded smaller and loses its location")
  func reencodesOversize() async throws {
    let videoURL = try await makeTestVideoURL(
      size: CGSize(width: 1600, height: 896),
      fileType: .mov,
      metadata: cameraMetadata()
    )
    defer { try? FileManager.default.removeItem(at: videoURL) }

    let result = try await VideoCompressor.shared.compressVideo(at: videoURL, options: .upload(for: .camera))
    defer { try? FileManager.default.removeItem(at: result.url) }

    #expect(max(result.width, result.height) <= 1_280)
    #expect(try await identifyingMetadata(at: result.url).isEmpty)
  }

  @Test("a video with no camera recorded is treated as a screen recording")
  func screenRecordingContent() async throws {
    let videoURL = try await makeTestVideoURL()
    defer { try? FileManager.default.removeItem(at: videoURL) }

    #expect(await VideoCompressor.content(of: videoURL) == .screenRecording)
    #expect(VideoCompressionOptions.upload(for: .screenRecording).maxDimension == 1_920)
    #expect(VideoCompressionOptions.upload(for: .camera).maxDimension == 1_280)
  }

  @Test("throws for empty file")
  func testInvalidAssetThrows() async throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inlinekit_empty_\(UUID().uuidString).mp4")
    try Data().write(to: tempURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    await #expect(throws: (any Error).self) {
      _ = try await VideoCompressor.shared.compressVideo(at: tempURL, options: .upload(for: .camera))
    }
  }
}

private func cameraMetadata() -> [AVMetadataItem] {
  func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }
  return [
    item(.quickTimeMetadataLocationISO6709, "+35.7000+051.4000/"),
    item(.quickTimeMetadataMake, "Apple"),
    item(.quickTimeMetadataModel, "iPhone 17 Pro"),
  ]
}

private func identifyingMetadata(at url: URL) async throws -> [AVMetadataItem] {
  let items = try await AVURLAsset(url: url).load(.metadata)
  return items.filter {
    $0.identifier == .quickTimeMetadataLocationISO6709
      || $0.identifier == .quickTimeMetadataMake
      || $0.identifier == .quickTimeMetadataModel
      || $0.commonKey == .commonKeyLocation
      || $0.commonKey == .commonKeyMake
      || $0.commonKey == .commonKeyModel
  }
}

private enum VideoTestError: Error {
  case writerSetupFailed
  case pixelBufferPoolUnavailable
  case pixelBufferCreationFailed
  case appendFailed
  case finishFailed
}

private final class AssetWriterBox: @unchecked Sendable {
  let writer: AVAssetWriter

  init(_ writer: AVAssetWriter) {
    self.writer = writer
  }
}

private func makeTestVideoURL(
  size: CGSize = CGSize(width: 64, height: 64),
  frameCount: Int = 2,
  fps: Int32 = 10,
  fileType: AVFileType = .mp4,
  metadata: [AVMetadataItem] = []
) async throws -> URL {
  let pathExtension = fileType == .mov ? "mov" : "mp4"
  let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("inlinekit_test_\(UUID().uuidString).\(pathExtension)")
  if FileManager.default.fileExists(atPath: outputURL.path) {
    try FileManager.default.removeItem(at: outputURL)
  }

  let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
  writer.metadata = metadata
  let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(size.width),
    AVVideoHeightKey: Int(size.height)
  ]

  let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
  input.expectsMediaDataInRealTime = false

  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height)
    ]
  )

  guard writer.canAdd(input) else { throw VideoTestError.writerSetupFailed }
  writer.add(input)

  guard writer.startWriting() else { throw VideoTestError.writerSetupFailed }
  writer.startSession(atSourceTime: .zero)

  guard let pool = adaptor.pixelBufferPool else {
    writer.cancelWriting()
    throw VideoTestError.pixelBufferPoolUnavailable
  }

  for frame in 0 ..< frameCount {
    while !input.isReadyForMoreMediaData {
      try await Task.sleep(for: .milliseconds(1))
    }

    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
      writer.cancelWriting()
      throw VideoTestError.pixelBufferCreationFailed
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
      let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
      memset(baseAddress, 0x7F, bytesPerRow * Int(size.height))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let time = CMTime(value: CMTimeValue(frame), timescale: fps)
    guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
      writer.cancelWriting()
      throw VideoTestError.appendFailed
    }
  }

  input.markAsFinished()
  try await finishWriting(writer)
  return outputURL
}

private func finishWriting(_ writer: AVAssetWriter) async throws {
  let writerBox = AssetWriterBox(writer)
  try await withCheckedThrowingContinuation { continuation in
    writerBox.writer.finishWriting {
      if writerBox.writer.status == .completed {
        continuation.resume()
      } else {
        continuation.resume(throwing: writerBox.writer.error ?? VideoTestError.finishFailed)
      }
    }
  }
}
