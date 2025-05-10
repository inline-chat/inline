import Foundation
import Logger

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum ImageCompressionError: Error {
  case invalidImage
  case compressionFailed
  case fileCreationFailed
  case compressionNotEffective
}

public struct ImageCompressionOptions: Sendable {
  public let maxDimension: CGFloat
  public let compressionQuality: CGFloat
  public let isPNG: Bool
  public let minimumCompressionRatio: Double // Minimum ratio of compressed size to original size

  public static let defaultPhoto = ImageCompressionOptions(
    maxDimension: 1_600,
    compressionQuality: 0.87,
    isPNG: false,
    minimumCompressionRatio: 0.8
  )
  public static let defaultPNG = ImageCompressionOptions(
    maxDimension: 1_280,
    compressionQuality: 0.9,
    isPNG: true,
    minimumCompressionRatio: 0.9
  )
}

public actor ImageCompressor {
  public static let shared = ImageCompressor()
  private let log = Log.scoped("ImageCompressor")

  private init() {}

  public func compressImage(at sourceURL: URL, options: ImageCompressionOptions) async throws -> URL {
    log.debug("Starting image compression for \(sourceURL.lastPathComponent)")

    // Get original file size
    let originalSize = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64 ?? 0
    log.debug("Original file size: \(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file))")

    #if canImport(AppKit)
    guard let image = NSImage(contentsOf: sourceURL) else {
      log.error("Failed to load image from URL", error: ImageCompressionError.invalidImage)
      throw ImageCompressionError.invalidImage
    }
    #elseif canImport(UIKit)
    guard let image = UIImage(contentsOfFile: sourceURL.path) else {
      log.error("Failed to load image from URL", error: ImageCompressionError.invalidImage)
      throw ImageCompressionError.invalidImage
    }
    #endif

    log.debug("Original image size: \(image.size.width)x\(image.size.height)")

    // Resize image if needed
    let resizedImage = try await resizeImage(image, maxDimension: options.maxDimension)
    log.debug("Resized image size: \(resizedImage.size.width)x\(resizedImage.size.height)")

    // Create temporary file URL
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = "compressed_\(UUID().uuidString).\(options.isPNG ? "png" : "jpg")"
    let outputURL = tempDir.appendingPathComponent(fileName)
    log.debug("Created temporary file at: \(outputURL.path)")

    // Compress and save
    #if canImport(AppKit)
    // Create bitmap representation with exact dimensions
    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(resizedImage.size.width),
      pixelsHigh: Int(resizedImage.size.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      log.error("Failed to create bitmap representation", error: ImageCompressionError.compressionFailed)
      throw ImageCompressionError.compressionFailed
    }

    // Draw the image into the bitmap context with high quality
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    NSGraphicsContext.current?.imageInterpolation = .high
    resizedImage.draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    // Get the data in the specified format with optimized properties
    let properties: [NSBitmapImageRep.PropertyKey: Any] = [
      .compressionFactor: options.compressionQuality,
      .interlaced: false
    ]

    guard let imageData = bitmapRep.representation(
      using: options.isPNG ? .png : .jpeg,
      properties: properties
    ) else {
      log.error("Failed to generate image data", error: ImageCompressionError.compressionFailed)
      throw ImageCompressionError.compressionFailed
    }

    try imageData.write(to: outputURL)
    #elseif canImport(UIKit)
    if options.isPNG {
      guard let pngData = resizedImage.pngData() else {
        log.error("Failed to compress PNG image", error: ImageCompressionError.compressionFailed)
        throw ImageCompressionError.compressionFailed
      }
      try pngData.write(to: outputURL)
    } else {
      guard let jpegData = resizedImage.jpegData(compressionQuality: options.compressionQuality) else {
        log.error("Failed to compress JPEG image", error: ImageCompressionError.compressionFailed)
        throw ImageCompressionError.compressionFailed
      }
      try jpegData.write(to: outputURL)
    }
    #endif

    // Check if compression was effective
    let compressedSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
    let compressionRatio = Double(compressedSize) / Double(originalSize)

    log.debug("""
    Compression results:
    - Original size: \(ByteCountFormatter.string(fromByteCount: originalSize, countStyle: .file))
    - Compressed size: \(ByteCountFormatter.string(fromByteCount: compressedSize, countStyle: .file))
    - Compression ratio: \(String(format: "%.2f", compressionRatio))
    """)

    // If compression didn't reduce size enough, return original
    if compressionRatio > options.minimumCompressionRatio {
      log
        .warning(
          "Compression not effective enough (ratio: \(String(format: "%.2f", compressionRatio))), using original image"
        )
      try? FileManager.default.removeItem(at: outputURL)
      throw ImageCompressionError.compressionNotEffective
    }

    log.debug("Successfully compressed \(options.isPNG ? "PNG" : "JPEG") image to \(outputURL.path)")
    return outputURL
  }

  private func resizeImage(_ image: PlatformImage, maxDimension: CGFloat) async throws -> PlatformImage {
    let size = image.size
    let widthRatio = maxDimension / size.width
    let heightRatio = maxDimension / size.height
    let ratio = min(widthRatio, heightRatio)

    // If image is already smaller than max dimension, return original
    if ratio >= 1 {
      log.debug("Image already smaller than max dimension (\(maxDimension)), skipping resize")
      return image
    }

    let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
    log.debug("Resizing image from \(size.width)x\(size.height) to \(newSize.width)x\(newSize.height)")

    #if canImport(AppKit)
    // Create a new image with the desired size
    let resizedImage = NSImage(size: newSize)

    // Create bitmap representation with exact dimensions
    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(newSize.width),
      pixelsHigh: Int(newSize.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      log.error("Failed to create bitmap representation for resizing", error: ImageCompressionError.compressionFailed)
      throw ImageCompressionError.compressionFailed
    }

    // Draw the image into the bitmap context with high quality
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
      in: NSRect(origin: .zero, size: newSize),
      from: NSRect(origin: .zero, size: size),
      operation: .copy,
      fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    // Create final image from bitmap
    let finalImage = NSImage(size: newSize)
    finalImage.addRepresentation(bitmapRep)

    log.debug("Resized image size: \(finalImage.size.width)x\(finalImage.size.height)")
    return finalImage
    #elseif canImport(UIKit)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0 // Force 1:1 scale to ensure exact dimensions
    format.preferredRange = .standard

    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    let resizedImage = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }

    log.debug("Resized image scale: \(resizedImage.scale), size: \(resizedImage.size)")
    return resizedImage
    #endif
  }
}
