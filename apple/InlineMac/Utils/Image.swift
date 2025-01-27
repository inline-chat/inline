
import AppKit
import CoreServices
import ImageIO
import InlineKit
import UniformTypeIdentifiers

// MARK: - Helper Extensions

extension NSBitmapImageRep {
  var png: Data? { representation(using: .png, properties: [:]) }
  var jpeg: Data? { representation(using: .jpeg, properties: [:]) }
}

extension Data {
  var bitmap: NSBitmapImageRep? { NSBitmapImageRep(data: self) }
}

extension NSImage {
  var png: Data? { tiffRepresentation?.bitmap?.png }
  var jpeg: Data? { tiffRepresentation?.bitmap?.jpeg }

  private var alphaComponent: Int {
    guard let tiffData = tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData)
    else {
      return 0
    }
    return bitmap.hasAlpha ? 1 : 0
  }
}

extension NSBitmapImageRep.FileType {
  var pathExtension: String {
    switch self {
      case .bmp:
        "bmp"
      case .gif:
        "gif"
      case .jpeg:
        "jpg"
      case .jpeg2000:
        "jp2"
      case .png:
        "png"
      case .tiff:
        "tif"
      default:
        "jpg"
    }
  }
}

// MARK: - Main Extension

extension NSImage {
  func prepareForUpload() -> SendMessageAttachment? {
    let maxSize = 5_024 * 1_024

    // Step 1: Create a proper image source from our NSImage
    guard let tiffData = tiffRepresentation else {
      return nil
    }

    let hasAlpha = alphaComponent > 0

    // Step 3: Prepare destination format and options
    let (format, fileType) = hasAlpha ?
      (SendMessageAttachment.ImageFormat.png, NSBitmapImageRep.FileType.png) :
      (SendMessageAttachment.ImageFormat.jpeg, NSBitmapImageRep.FileType.jpeg)

    let fileName = UUID().uuidString + (format == .png ? ".png" : ".jpg")
    let temporaryDirectory = FileHelpers.getDocumentsDirectory()
    let temporaryFileURL = temporaryDirectory.appendingPathComponent(fileName)
    let fileSize = tiffData.count
    _ = saveImage(
      to: temporaryFileURL,
      fileType: fileType,
      properties: [.compressionFactor: 0.9]
    )

    return SendMessageAttachment.photo(
      format: format,
      width: Int(size.width),
      height: Int(size.height),
      path: fileName,
      fileSize: fileSize,
      fileName: fileName
    )
  }

  // Optional: Resize image if needed
  func resized(to newSize: NSSize) -> NSImage {
    let newImage = NSImage(size: newSize)

    newImage.lockFocus()
    draw(
      in: NSRect(origin: .zero, size: newSize),
      from: NSRect(origin: .zero, size: size),
      operation: .copy,
      fraction: 1.0
    )
    newImage.unlockFocus()

    return newImage
  }
}

extension NSImage {
  func saveImage(
    to url: URL,
    fileType: NSBitmapImageRep.FileType,
    properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
  ) -> Bool {
    let image = self
    // Ensure the image has a valid size
    guard !image.size.width.isZero, !image.size.height.isZero else {
      print("Image size is zero")
      return false
    }

    // Create a bitmap representation by drawing the image
    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(image.size.width),
      pixelsHigh: Int(image.size.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      print("Failed to create bitmap representation")
      return false
    }

    // Draw the image into the bitmap context
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
    image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    // Get the data in the specified format
    guard let imageData = bitmapRep.representation(using: fileType, properties: properties) else {
      print("Failed to generate image data")
      return false
    }

    // Write the data to the destination URL
    do {
      try imageData.write(to: url)
      return true
    } catch {
      print("Error saving image: \(error.localizedDescription)")
      return false
    }
  }
}
