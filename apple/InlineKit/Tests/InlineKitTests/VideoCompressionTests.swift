import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import InlineKit

@Suite("Video Compression")
struct VideoCompressionTests {
  @Test("returns compressionNotNeeded when thresholds are high")
  func testCompressionNotNeededForSmallVideo() async throws {
    let videoURL = try await makeTestVideoURL()
    defer { try? FileManager.default.removeItem(at: videoURL) }

    let options = VideoCompressionOptions(
      maxDimension: 4096,
      minFileSizeBytes: Int64.max,
      maxBitrateMbps: 1000,
      minimumCompressionRatio: 0.99,
      forceTranscode: false
    )

    do {
      _ = try await VideoCompressor.shared.compressVideo(at: videoURL, options: options)
      #expect(Bool(false))
    } catch VideoCompressionError.compressionNotNeeded {
      // Expected
    } catch {
      #expect(Bool(false))
    }
  }

  @Test("throws for empty file")
  func testInvalidAssetThrows() async throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inlinekit_empty_\(UUID().uuidString).mp4")
    try Data().write(to: tempURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    do {
      _ = try await VideoCompressor.shared.compressVideo(
        at: tempURL,
        options: VideoCompressionOptions.uploadDefault(forceTranscode: true)
      )
      #expect(Bool(false))
    } catch VideoCompressionError.compressionNotNeeded {
      #expect(Bool(false))
    } catch {
      // Expected: invalid input should fail compression.
    }
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
  fps: Int32 = 10
) async throws -> URL {
  let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("inlinekit_test_\(UUID().uuidString).mp4")
  if FileManager.default.fileExists(atPath: outputURL.path) {
    try FileManager.default.removeItem(at: outputURL)
  }

  let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
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
