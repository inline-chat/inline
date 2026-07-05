import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnimatedMedia

@Suite("Animated image video converter")
struct AnimatedImageVideoConverterTests {
  @Test("converts an animated GIF to a silent MP4")
  func convertsAnimatedGIFToSilentMP4() async throws {
    let gifURL = try makeTestGIF(frameCount: 3)
    let options = AnimatedImageVideoConversionOptions(
      maxDimension: 64,
      maxSourceDimension: 128,
      maxInputBytes: 2_000_000,
      maxOutputBytes: 1_000_000,
      maxFrames: 10,
      maxDurationSeconds: 3,
      targetBitrate: 220_000
    )

    let result = try await AnimatedImageVideoConverter.convertGIF(at: gifURL, options: options)

    #expect(result.url.pathExtension == "mp4")
    #expect(result.fileSize > 0)
    #expect(result.fileSize <= options.maxOutputBytes)
    #expect(result.width == 64)
    #expect(result.height == 48)
    #expect(result.duration >= 1)
    #expect(result.thumbnail != nil)

    let asset = AVURLAsset(url: result.url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.isEmpty)
  }

  @Test("rejects static GIF input")
  func rejectsStaticGIFInput() async throws {
    let gifURL = try makeTestGIF(frameCount: 1)

    await #expect(throws: AnimatedImageVideoConversionError.notAnimated) {
      _ = try await AnimatedImageVideoConverter.convertGIF(at: gifURL)
    }
  }

  @Test("exports a converted animated video back to GIF")
  func exportsConvertedVideoBackToGIF() async throws {
    let gifURL = try makeTestGIF(frameCount: 4)
    let video = try await AnimatedImageVideoConverter.convertGIF(
      at: gifURL,
      options: AnimatedImageVideoConversionOptions(
        maxDimension: 64,
        maxSourceDimension: 128,
        maxInputBytes: 2_000_000,
        maxOutputBytes: 1_000_000,
        maxFrames: 10,
        maxDurationSeconds: 3,
        targetBitrate: 220_000
      )
    )

    let gif = try await AnimatedVideoGIFExporter.exportGIF(
      fromVideoAt: video.url,
      options: AnimatedVideoGIFExportOptions(
        maxDimension: 64,
        maxDurationSeconds: 3,
        frameRate: 8,
        maxFrames: 24,
        maxOutputBytes: 2_000_000
      )
    )

    #expect(gif.url.pathExtension == "gif")
    #expect(gif.fileSize > 0)
    #expect(gif.fileSize <= 2_000_000)
    #expect(gif.frameCount > 1)

    let source = try #require(CGImageSourceCreateWithURL(gif.url as CFURL, nil))
    #expect(CGImageSourceGetCount(source) > 1)
    #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
  }
}

private func makeTestGIF(frameCount: Int) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("animated-media-test-\(UUID().uuidString).gif")
  let destination = try #require(CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.gif.identifier as CFString,
    frameCount,
    nil
  ))

  CGImageDestinationSetProperties(
    destination,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
  )

  let frameProperties = [
    kCGImagePropertyGIFDictionary: [
      kCGImagePropertyGIFDelayTime: 0.12,
      kCGImagePropertyGIFUnclampedDelayTime: 0.12,
    ],
  ] as CFDictionary

  for index in 0 ..< frameCount {
    CGImageDestinationAddImage(destination, try makeFrame(index: index), frameProperties)
  }

  #expect(CGImageDestinationFinalize(destination))
  return url
}

private func makeFrame(index: Int) throws -> CGImage {
  let width = 64
  let height = 48
  let context = try #require(CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ))

  let colors = [
    CGColor(red: 0.95, green: 0.18, blue: 0.22, alpha: 1),
    CGColor(red: 0.18, green: 0.62, blue: 0.96, alpha: 1),
    CGColor(red: 0.20, green: 0.75, blue: 0.36, alpha: 1),
    CGColor(red: 0.95, green: 0.72, blue: 0.15, alpha: 1),
  ]

  context.setFillColor(colors[index % colors.count])
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(gray: 1, alpha: 0.9))
  context.fill(CGRect(x: 8 + index * 4, y: 10, width: 18, height: 18))

  return try #require(context.makeImage())
}
