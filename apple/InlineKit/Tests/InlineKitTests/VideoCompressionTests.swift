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
      #expect(false)
    } catch VideoCompressionError.compressionNotNeeded {
      // Expected
    } catch {
      #expect(false)
    }
  }

  @Test("throws invalidAsset for empty file")
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
      #expect(false)
    } catch VideoCompressionError.invalidAsset {
      // Expected
    } catch {
      #expect(false)
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

  let queue = DispatchQueue(label: "inlinekit.video.writer")
  return try await withCheckedThrowingContinuation { continuation in
    var frame = 0
    var didComplete = false

    input.requestMediaDataWhenReady(on: queue) {
      guard !didComplete else { return }
      while input.isReadyForMoreMediaData && frame < frameCount {
        guard let pool = adaptor.pixelBufferPool else {
          didComplete = true
          writer.cancelWriting()
          continuation.resume(throwing: VideoTestError.pixelBufferPoolUnavailable)
          return
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
          didComplete = true
          writer.cancelWriting()
          continuation.resume(throwing: VideoTestError.pixelBufferCreationFailed)
          return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
          let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
          memset(baseAddress, 0x7F, bytesPerRow * Int(size.height))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let time = CMTime(value: CMTimeValue(frame), timescale: fps)
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
          didComplete = true
          writer.cancelWriting()
          continuation.resume(throwing: VideoTestError.appendFailed)
          return
        }

        frame += 1
      }

      if frame >= frameCount && !didComplete {
        didComplete = true
        input.markAsFinished()
        writer.finishWriting {
          if writer.status == .completed {
            continuation.resume(returning: outputURL)
          } else {
            continuation.resume(throwing: writer.error ?? VideoTestError.finishFailed)
          }
        }
      }
    }
  }
}
