import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
public typealias AnimatedMediaImage = UIImage
#elseif os(macOS)
import AppKit
public typealias AnimatedMediaImage = NSImage
#endif

public enum AnimatedImageVideoConversionError: Error, Equatable {
  case invalidSource
  case notAnimated
  case inputTooLarge
  case dimensionsTooLarge
  case tooManyFrames
  case durationTooLong
  case writerSetupFailed
  case writerFailed
  case pixelBufferFailed
  case outputTooLarge
}

public enum AnimatedVideoGIFExportError: Error, Equatable {
  case invalidSource
  case durationTooLong
  case tooManyFrames
  case frameGenerationFailed
  case destinationFailed
  case outputTooLarge
}

public struct AnimatedImageVideoConversionOptions: Sendable {
  public var maxDimension: Int
  public var maxSourceDimension: Int
  public var maxInputBytes: Int64
  public var maxOutputBytes: Int64
  public var maxFrames: Int
  public var maxDurationSeconds: Double
  public var minFrameDelaySeconds: Double
  public var defaultFrameDelaySeconds: Double
  public var targetBitrate: Int
  public var timescale: Int32

  public init(
    maxDimension: Int = 720,
    maxSourceDimension: Int = 1_600,
    maxInputBytes: Int64 = 20_000_000,
    maxOutputBytes: Int64 = 5_000_000,
    maxFrames: Int = 600,
    maxDurationSeconds: Double = 15,
    minFrameDelaySeconds: Double = 0.02,
    defaultFrameDelaySeconds: Double = 0.10,
    targetBitrate: Int = 650_000,
    timescale: Int32 = 600
  ) {
    self.maxDimension = maxDimension
    self.maxSourceDimension = maxSourceDimension
    self.maxInputBytes = maxInputBytes
    self.maxOutputBytes = maxOutputBytes
    self.maxFrames = maxFrames
    self.maxDurationSeconds = maxDurationSeconds
    self.minFrameDelaySeconds = minFrameDelaySeconds
    self.defaultFrameDelaySeconds = defaultFrameDelaySeconds
    self.targetBitrate = targetBitrate
    self.timescale = timescale
  }

  public static let uploadDefault = AnimatedImageVideoConversionOptions()
}

public struct AnimatedVideoGIFExportOptions: Sendable {
  public var maxDimension: Int
  public var maxDurationSeconds: Double
  public var frameRate: Double
  public var maxFrames: Int
  public var maxOutputBytes: Int64

  public init(
    maxDimension: Int = 480,
    maxDurationSeconds: Double = 15,
    frameRate: Double = 12,
    maxFrames: Int = 180,
    maxOutputBytes: Int64 = 15_000_000
  ) {
    self.maxDimension = maxDimension
    self.maxDurationSeconds = maxDurationSeconds
    self.frameRate = frameRate
    self.maxFrames = maxFrames
    self.maxOutputBytes = maxOutputBytes
  }

  public static let saveDefault = AnimatedVideoGIFExportOptions()
}

public struct AnimatedImageVideoConversionResult: @unchecked Sendable {
  public let url: URL
  public let width: Int
  public let height: Int
  public let duration: Int
  public let fileSize: Int64
  public let thumbnail: AnimatedMediaImage?
}

public struct AnimatedVideoGIFExportResult: Sendable {
  public let url: URL
  public let frameCount: Int
  public let duration: Double
  public let fileSize: Int64
}

private struct GIFFrameDescriptor {
  let delay: Double
}

public enum AnimatedImageVideoConverter {
  public static func convertGIF(
    at sourceURL: URL,
    options: AnimatedImageVideoConversionOptions = .uploadDefault
  ) async throws -> AnimatedImageVideoConversionResult {
    let inputSize = fileSize(at: sourceURL)
    guard inputSize > 0 else { throw AnimatedImageVideoConversionError.invalidSource }
    guard inputSize <= options.maxInputBytes else { throw AnimatedImageVideoConversionError.inputTooLarge }

    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
      throw AnimatedImageVideoConversionError.invalidSource
    }

    if let type = CGImageSourceGetType(source),
       UTType(type as String)?.conforms(to: .gif) != true {
      throw AnimatedImageVideoConversionError.invalidSource
    }

    guard CGImageSourceGetStatus(source) == .statusComplete else {
      throw AnimatedImageVideoConversionError.invalidSource
    }

    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 1 else { throw AnimatedImageVideoConversionError.notAnimated }
    guard frameCount <= options.maxFrames else { throw AnimatedImageVideoConversionError.tooManyFrames }

    let canvasSize = try imageSourceCanvasSize(source)
    guard canvasSize.width > 0, canvasSize.height > 0 else {
      throw AnimatedImageVideoConversionError.invalidSource
    }
    let maxSourceDimension = CGFloat(options.maxSourceDimension)
    guard canvasSize.width <= maxSourceDimension, canvasSize.height <= maxSourceDimension else {
      throw AnimatedImageVideoConversionError.dimensionsTooLarge
    }

    let outputSize = targetSize(for: canvasSize, maxDimension: options.maxDimension)
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("animated-\(UUID().uuidString).mp4")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true

    var didFinish = false
    defer {
      if !didFinish {
        writer.cancelWriting()
        if FileManager.default.fileExists(atPath: outputURL.path) {
          try? FileManager.default.removeItem(at: outputURL)
        }
      }
    }

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: outputSize.width,
      AVVideoHeightKey: outputSize.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: options.targetBitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw AnimatedImageVideoConversionError.writerSetupFailed
    }
    writer.add(input)

    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: outputSize.width,
      kCVPixelBufferHeightKey as String: outputSize.height,
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: pixelBufferAttributes
    )

    guard writer.startWriting() else {
      throw writer.error ?? AnimatedImageVideoConversionError.writerFailed
    }
    writer.startSession(atSourceTime: .zero)

    var totalDuration: Double = 0
    var thumbnail: AnimatedMediaImage?

    for frameIndex in 0 ..< frameCount {
      try Task.checkCancellation()

      let descriptor = frameDescriptor(at: frameIndex, source: source, options: options)
      if totalDuration + descriptor.delay > options.maxDurationSeconds {
        throw AnimatedImageVideoConversionError.durationTooLong
      }

      guard let image = CGImageSourceCreateImageAtIndex(
        source,
        frameIndex,
        [kCGImageSourceTypeIdentifierHint as String: UTType.gif.identifier] as CFDictionary
      ) else {
        throw AnimatedImageVideoConversionError.invalidSource
      }

      if thumbnail == nil {
        thumbnail = platformImage(from: image, size: outputSize)
      }

      while !input.isReadyForMoreMediaData {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 10_000_000)
      }

      guard let pixelBuffer = makePixelBuffer(
        from: image,
        outputSize: outputSize,
        pixelBufferPool: adaptor.pixelBufferPool
      ) else {
        throw AnimatedImageVideoConversionError.pixelBufferFailed
      }

      let presentationTime = CMTime(seconds: totalDuration, preferredTimescale: options.timescale)
      guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        throw writer.error ?? AnimatedImageVideoConversionError.writerFailed
      }

      totalDuration += descriptor.delay
    }

    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: totalDuration, preferredTimescale: options.timescale))
    try await finishWriting(writer)

    let outputFileSize = fileSize(at: outputURL)
    guard outputFileSize > 0 else { throw AnimatedImageVideoConversionError.writerFailed }
    guard outputFileSize <= options.maxOutputBytes else { throw AnimatedImageVideoConversionError.outputTooLarge }

    didFinish = true
    return AnimatedImageVideoConversionResult(
      url: outputURL,
      width: outputSize.width,
      height: outputSize.height,
      duration: max(1, Int(totalDuration.rounded())),
      fileSize: outputFileSize,
      thumbnail: thumbnail
    )
  }

  private static func imageSourceCanvasSize(_ source: CGImageSource) throws -> CGSize {
    if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
      if let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
         let width = number(gifProperties[kCGImagePropertyGIFCanvasPixelWidth])?.intValue,
         let height = number(gifProperties[kCGImagePropertyGIFCanvasPixelHeight])?.intValue {
        return CGSize(width: width, height: height)
      }

      if let width = number(properties[kCGImagePropertyPixelWidth])?.intValue,
         let height = number(properties[kCGImagePropertyPixelHeight])?.intValue {
        return CGSize(width: width, height: height)
      }
    }

    guard let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw AnimatedImageVideoConversionError.invalidSource
    }
    return CGSize(width: firstImage.width, height: firstImage.height)
  }

  private static func targetSize(for sourceSize: CGSize, maxDimension: Int) -> (width: Int, height: Int) {
    let width = max(sourceSize.width, 1)
    let height = max(sourceSize.height, 1)
    let scale = min(1, CGFloat(maxDimension) / max(width, height))
    let scaledWidth = max(2, Int((width * scale).rounded(.down)))
    let scaledHeight = max(2, Int((height * scale).rounded(.down)))

    return (
      width: scaledWidth.isMultiple(of: 2) ? scaledWidth : max(2, scaledWidth - 1),
      height: scaledHeight.isMultiple(of: 2) ? scaledHeight : max(2, scaledHeight - 1)
    )
  }

  private static func frameDescriptor(
    at index: Int,
    source: CGImageSource,
    options: AnimatedImageVideoConversionOptions
  ) -> GIFFrameDescriptor {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
      let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    else {
      return GIFFrameDescriptor(
        delay: options.defaultFrameDelaySeconds
      )
    }

    let rawDelay =
      number(gifProperties[kCGImagePropertyGIFUnclampedDelayTime])?.doubleValue
      ?? number(gifProperties[kCGImagePropertyGIFDelayTime])?.doubleValue
      ?? options.defaultFrameDelaySeconds
    let delay = rawDelay.isFinite && rawDelay > 0
      ? max(rawDelay, options.minFrameDelaySeconds)
      : options.defaultFrameDelaySeconds

    return GIFFrameDescriptor(delay: delay)
  }

  private static func makePixelBuffer(
    from image: CGImage,
    outputSize: (width: Int, height: Int),
    pixelBufferPool: CVPixelBufferPool?
  ) -> CVPixelBuffer? {
    let pixelBuffer: CVPixelBuffer?
    if let pixelBufferPool {
      var pooledBuffer: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pooledBuffer) == kCVReturnSuccess else {
        return nil
      }
      pixelBuffer = pooledBuffer
    } else {
      var createdBuffer: CVPixelBuffer?
      let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ]
      guard CVPixelBufferCreate(
        nil,
        outputSize.width,
        outputSize.height,
        kCVPixelFormatType_32ARGB,
        attributes as CFDictionary,
        &createdBuffer
      ) == kCVReturnSuccess else {
        return nil
      }
      pixelBuffer = createdBuffer
    }

    guard let pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: outputSize.width,
        height: outputSize.height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
      )
    else {
      return nil
    }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height))
    return pixelBuffer
  }

  private static func finishWriting(_ writer: AVAssetWriter) async throws {
    let writerBox = AssetWriterBox(writer)
    try await withCheckedThrowingContinuation { continuation in
      writerBox.writer.finishWriting {
        if writerBox.writer.status == .completed {
          continuation.resume()
        } else {
          continuation.resume(throwing: writerBox.writer.error ?? AnimatedImageVideoConversionError.writerFailed)
        }
      }
    }
  }
}

private final class AssetWriterBox: @unchecked Sendable {
  let writer: AVAssetWriter

  init(_ writer: AVAssetWriter) {
    self.writer = writer
  }
}

public enum AnimatedVideoGIFExporter {
  public static func exportGIF(
    fromVideoAt sourceURL: URL,
    options: AnimatedVideoGIFExportOptions = .saveDefault
  ) async throws -> AnimatedVideoGIFExportResult {
    let asset = AVURLAsset(url: sourceURL)
    let duration = try await asset.load(.duration)
    let durationSeconds = CMTimeGetSeconds(duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else {
      throw AnimatedVideoGIFExportError.invalidSource
    }
    guard durationSeconds <= options.maxDurationSeconds else {
      throw AnimatedVideoGIFExportError.durationTooLong
    }

    let frameRate = max(1, options.frameRate)
    let frameDelay = 1 / frameRate
    let frameCount = max(1, Int(ceil(durationSeconds * frameRate)))
    guard frameCount <= options.maxFrames else {
      throw AnimatedVideoGIFExportError.tooManyFrames
    }

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("animated-\(UUID().uuidString).gif")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    var didFinish = false
    defer {
      if !didFinish, FileManager.default.fileExists(atPath: outputURL.path) {
        try? FileManager.default.removeItem(at: outputURL)
      }
    }

    guard let destination = CGImageDestinationCreateWithURL(
      outputURL as CFURL,
      UTType.gif.identifier as CFString,
      frameCount,
      nil
    ) else {
      throw AnimatedVideoGIFExportError.destinationFailed
    }

    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
    )

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: options.maxDimension, height: options.maxDimension)

    let frameProperties = [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: frameDelay,
        kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
      ],
    ] as CFDictionary

    for frameIndex in 0 ..< frameCount {
      try Task.checkCancellation()
      let second = min(Double(frameIndex) * frameDelay, max(0, durationSeconds - 0.001))
      let time = CMTime(seconds: second, preferredTimescale: 600)
      guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else {
        throw AnimatedVideoGIFExportError.frameGenerationFailed
      }
      CGImageDestinationAddImage(destination, frame, frameProperties)
    }

    guard CGImageDestinationFinalize(destination) else {
      throw AnimatedVideoGIFExportError.destinationFailed
    }

    let outputFileSize = fileSize(at: outputURL)
    guard outputFileSize <= options.maxOutputBytes else {
      throw AnimatedVideoGIFExportError.outputTooLarge
    }

    didFinish = true
    return AnimatedVideoGIFExportResult(
      url: outputURL,
      frameCount: frameCount,
      duration: durationSeconds,
      fileSize: outputFileSize
    )
  }
}

private func platformImage(from image: CGImage, size: (width: Int, height: Int)) -> AnimatedMediaImage {
  #if os(iOS)
  return AnimatedMediaImage(cgImage: image)
  #else
  return AnimatedMediaImage(cgImage: image, size: CGSize(width: size.width, height: size.height))
  #endif
}

private func number(_ value: Any?) -> NSNumber? {
  if let number = value as? NSNumber {
    return number
  }
  if let value = value as? Int {
    return NSNumber(value: value)
  }
  if let value = value as? Double {
    return NSNumber(value: value)
  }
  return nil
}

private func fileSize(at url: URL) -> Int64 {
  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
  if let size = attributes?[.size] as? NSNumber {
    return size.int64Value
  }
  return 0
}
