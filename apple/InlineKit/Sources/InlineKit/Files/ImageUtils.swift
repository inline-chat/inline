import Foundation
import InlineProtocol

#if os(iOS)
public typealias PlatformImage = UIImage
import UIKit
#else
public typealias PlatformImage = NSImage
import AppKit
#endif

public enum ImageFormat: String, Codable, Sendable {
  case jpeg
  case png

  var fileExtension: String {
    switch self {
      case .jpeg: "jpg"
      case .png: "png"
    }
  }

  var mimeType: String {
    switch self {
      case .jpeg: "image/jpeg"
      case .png: "image/png"
    }
  }

  public func toProtocol() -> InlineProtocol.Photo.Format {
    switch self {
      case .jpeg:
        .jpeg
      case .png:
        .png
    }
  }

  public func toExt() -> String {
    switch self {
      case .jpeg: ".jpg"
      case .png: ".png"
    }
  }

  public func toMimeType() -> String {
    switch self {
      case .jpeg: "image/jpeg"
      case .png: "image/png"
    }
  }
}

public protocol ImageSaving {
  func save(to directory: URL, withName fileName: String, format: ImageFormat) -> String?
}

#if os(iOS)
extension UIImage: ImageSaving {
  public func save(to directory: URL, withName fileName: String, format: ImageFormat) -> String? {
    let path = fileName.isEmpty ? UUID().uuidString + "." + format.fileExtension : fileName
    let fileUrl = directory.appendingPathComponent(path)

    let imageData: Data? =
      switch format {
        case .png:
          pngData()
        case .jpeg:
          jpegData(compressionQuality: 1.0)
      }

    guard let data = imageData else { return nil }

    do {
      try data.write(to: fileUrl)
      return path
    } catch {
      return nil
    }
  }
}
#else
extension NSImage: ImageSaving {
  public func save(to directory: URL, withName fileName: String, format: ImageFormat) -> String? {
    let path = fileName.isEmpty ? UUID().uuidString + "." + format.fileExtension : fileName
    let fileUrl = directory.appendingPathComponent(path)

    guard let data = tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data)
    else {
      return nil
    }

    let imageData: Data? =
      switch format {
        case .png:
          bitmap.representation(using: .png, properties: [:])
        case .jpeg:
          bitmap.representation(using: .jpeg, properties: [:])
      }

    guard let data = imageData else { return nil }

    do {
      try data.write(to: fileUrl)
      return path
    } catch {
      return nil
    }
  }
}
#endif

// Helper extension for File type
public extension File {
  var imageFormat: ImageFormat {
    switch mimeType {
      case "image/png":
        .png
      case "image/jpeg":
        .jpeg
      default:
        .jpeg
    }
  }
}

func hasAlphaChannel(image: PlatformImage) -> Bool {
  let cgImage: CGImage?

  #if canImport(UIKit)
  cgImage = image.cgImage
  #elseif canImport(AppKit)
  cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
  #endif

  guard let cgImage else { return false }

  let alphaInfo = cgImage.alphaInfo
  switch alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
      return true
    case .none, .noneSkipFirst, .noneSkipLast:
      return false
    @unknown default:
      return false
  }
}
