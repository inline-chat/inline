import CoreServices
import ImageIO
import InlineKit
import InlineProtocol
import UIKit
import UniformTypeIdentifiers

// MARK: - Helper Extensions

extension Data {
  var uiImage: UIImage? { UIImage(data: self) }
}

extension UIImage {
  var png: Data? { pngData() }
  var jpeg: Data? { jpegData(compressionQuality: 0.9) }

  private var hasAlpha: Bool {
    guard let cgImage else { return false }
    let alpha = cgImage.alphaInfo
    return alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
  }
}

// MARK: - Main Extension

extension UIImage {
  /// Returns locally stored path
  func save(file: InlineKit.File) -> String? {
    let ext = switch file.mimeType {
    case "image/png":
      ".png"
    case "image/jpeg":
      ".jpg"
    default:
      ".jpg"
    }

    let dir = FileHelpers.getDocumentsDirectory()
    let path = file.fileName ?? UUID().uuidString + ext
    let fileUrl = dir.appendingPathComponent(path)

    guard let imageData = switch file.mimeType {
    case "image/png":
      png
    case "image/jpeg":
      jpeg
    default:
      jpeg
    } else { return nil }

    do {
      try imageData.write(to: fileUrl)
      return path
    } catch {
      return nil
    }
  }
}

extension UIImage {
//  func prepareForUpload() -> SendMessageAttachment? {
//    let maxSize = 5_024 * 1_024
//
//    guard let imageData = hasAlpha ? png : jpeg else {
//      return nil
//    }
//
//    let format: SendMessageAttachment.ImageFormat = hasAlpha ? .png : .jpeg
//    let fileName = UUID().uuidString + (format == .png ? ".png" : ".jpg")
//    let temporaryDirectory = FileHelpers.getDocumentsDirectory()
//    let temporaryFileURL = temporaryDirectory.appendingPathComponent(fileName)
//    let fileSize = imageData.count
//
//    do {
//      try imageData.write(to: temporaryFileURL)
//    } catch {
//      return nil
//    }
//
//    return SendMessageAttachment.photo(
//      format: format,
//      width: Int(size.width),
//      height: Int(size.height),
//      path: fileName,
//      fileSize: fileSize,
//      fileName: fileName
//    )
//  }

  // Optional: Resize image if needed
  func resized(to newSize: CGSize) -> UIImage? {
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in
      draw(in: CGRect(origin: .zero, size: newSize))
    }
  }
}

extension UIImage {
  func saveImage(
    to url: URL,
    format: InlineProtocol.Photo.Format,
    compressionQuality: CGFloat = 0.9
  ) -> Bool {
    guard let imageData = format == .png ? png : jpeg else {
      return false
    }

    do {
      try imageData.write(to: url)
      return true
    } catch {
      print("Error saving image: \(error.localizedDescription)")
      return false
    }
  }
}

struct File {
  let mimeType: String
  let fileName: String?
}
