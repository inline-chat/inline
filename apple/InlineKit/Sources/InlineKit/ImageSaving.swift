import Foundation

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

public enum ImageFormat {
  case jpeg
  case png

  var fileExtension: String {
    switch self {
    case .jpeg: return "jpg"
    case .png: return "png"
    }
  }

  var mimeType: String {
    switch self {
    case .jpeg: return "image/jpeg"
    case .png: return "image/png"
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
          self.pngData()
        case .jpeg:
          self.jpegData(compressionQuality: 1.0)
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
extension File {
  public var imageFormat: ImageFormat {
    switch mimeType {
    case "image/png":
      return .png
    case "image/jpeg":
      return .jpeg
    default:
      return .jpeg
    }
  }
}
