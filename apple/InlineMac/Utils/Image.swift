
import AppKit
import InlineKit

extension NSImage {
  func prepareForUpload() -> SendMessageAttachment? {
    let maxSize = 5_024 * 1_024 // 5MB

    guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }

    let hasAlpha = cgImage.alphaInfo != .none
    let preferredFormat: NSBitmapImageRep.FileType = hasAlpha ? .png : .jpeg

//    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    // Create bitmap with proper pixel format
    let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: cgImage.width,
      pixelsHigh: cgImage.height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bitmapFormat: .alphaFirst,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )

    guard let bitmapRep else {
//      throw ImageSavingError.bitmapCreationFailed
      return nil
    }

    // Draw the image into the bitmap
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
      // throw ImageSavingError.bitmapCreationFailed
      return nil
    }
    NSGraphicsContext.current = context

    let rect = NSRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    var compression: Float = 0.9
    var imageData: Data?
    var format: SendMessageAttachment.ImageFormat = .jpeg

    // For JPEG, try different compression levels if needed
    if preferredFormat == .jpeg {
      while compression > 0.1 {
        let properties: [NSBitmapImageRep.PropertyKey: Any] = [
          .compressionFactor: compression,
        ]

        imageData = bitmapRep.representation(using: preferredFormat, properties: properties)

        if let data = imageData, data.count <= maxSize {
          break
        }

        compression -= 0.1
      }
      format = .jpeg
    } else {
      // For PNG, just create the data
      // For PNG, use specific properties
      let properties: [NSBitmapImageRep.PropertyKey: Any] = [
        .interlaced: false,
      ]
      imageData = bitmapRep.representation(using: .png, properties: properties)
      format = .png
    }

    guard let finalImageData = imageData else {
      return nil
    }

    // Create temporary file path
    let temporaryDirectory = FileHelpers.getDocumentsDirectory()
    let fileName = UUID().uuidString + (format == .jpeg ? ".jpg" : ".png")
    let path = fileName
    let temporaryFileURL = temporaryDirectory.appendingPathComponent(path)

    do {
      // Write the image data to temporary file
      try finalImageData.write(to: temporaryFileURL)

      return SendMessageAttachment.photo(
        format: format,
        width: Int(size.width),
        height: Int(size.height),
        path: path,
        fileSize: finalImageData.count,
        fileName: fileName
      )
    } catch {
      print("Failed to write image to temporary file: \(error)")
      return nil
    }
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
