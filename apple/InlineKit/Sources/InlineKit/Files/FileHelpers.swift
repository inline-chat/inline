import Foundation
import Logger
import UniformTypeIdentifiers

public enum FileLocalCacheDirectory {
  case photos
  case videos
  case documents
}

public enum FileHelpers {
  public static func getToBeUploadedDirectory() -> URL {
    let fileManager = FileManager.default
    let paths = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )
    let applicationSupportDirectory = paths[0]

    let subdirectoryPath = applicationSupportDirectory.appendingPathComponent("UploadCache", isDirectory: true)

    // Create the directory if it doesn't exist
    if !fileManager.fileExists(atPath: subdirectoryPath.path) {
      do {
        try fileManager.createDirectory(
          at: subdirectoryPath,
          withIntermediateDirectories: true,
          attributes: nil
        )
      } catch {
        Log.shared.error("Error creating directory: \(error.localizedDescription)")
        // Fall back to documents directory if creation fails
        return applicationSupportDirectory
      }
    }

    return subdirectoryPath
  }

  public static func getDocumentsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    return paths[0]
  }

  public static func getApplicationSupportDirectory() -> URL {
    let paths = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )
    return paths[0]
  }

  // For truly temporary files
  public static func getTrueTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
  }

  /// Documents directory with media type specific folders appended
  public static func getLocalCacheDirectory(for directory: FileLocalCacheDirectory) -> URL {
    let documentsDirectory = getApplicationSupportDirectory()
    let fileManager = FileManager.default

    // Create a subdirectory based on the specified type
    let subdirectoryPath: URL = switch directory {
    case .photos:
      documentsDirectory.appendingPathComponent("Photos", isDirectory: true)
    case .videos:
      documentsDirectory.appendingPathComponent("Videos", isDirectory: true)
    case .documents:
      documentsDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    // Create the directory if it doesn't exist
    if !fileManager.fileExists(atPath: subdirectoryPath.path) {
      do {
        try fileManager.createDirectory(
          at: subdirectoryPath,
          withIntermediateDirectories: true,
          attributes: nil
        )
      } catch {
        Log.shared.error("Error creating directory:", error: error)
        // Fall back to documents directory if creation fails
        return documentsDirectory
      }
    }

    return subdirectoryPath
  }

  public static func getFileSize(at fileURL: URL) -> Int {
    let fileManager = FileManager.default

    // Check if file exists
    guard fileManager.fileExists(atPath: fileURL.path) else {
      Log.shared.error("File does not exist at path: \(fileURL.path)")
      return 0
    }

    do {
      // Get file attributes
      let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)

      // Get file size in bytes
      guard let fileSize = attributes[.size] as? Int else {
        Log.shared.error("Could not get file size")
        return 0
      }

      return fileSize
    } catch {
      Log.shared.error("Error getting file size: \(error.localizedDescription)")
      return 0
    }
  }

  /// Formats a file size in bytes to a human-readable string
  /// - Parameter bytes: The file size in bytes
  /// - Returns: A formatted string representing the file size (e.g., "1.5 MB")
  public static func formatFileSize(_ bytes: UInt64) -> String {
    let byteCountFormatter = ByteCountFormatter()
    byteCountFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    byteCountFormatter.countStyle = .file
    byteCountFormatter.allowsNonnumericFormatting = false
    return byteCountFormatter.string(fromByteCount: Int64(bytes))
  }

  public static func getMimeType(for url: URL) -> String {
    // Try to get the file extension
    let fileExtension = url.pathExtension.lowercased()

    // Check if we have a file URL with a path on disk
    if url.isFileURL, let uti = UTType(filenameExtension: fileExtension) {
      // Get MIME type from the UTType
      return uti.preferredMIMEType ?? "application/octet-stream"
    }

    // For non-file URLs or if UTType doesn't work, use a dictionary of common MIME types
    let mimeTypes = [
      "html": "text/html",
      "htm": "text/html",
      "css": "text/css",
      "js": "text/javascript",
      "txt": "text/plain",
      "pdf": "application/pdf",
      "jpg": "image/jpeg",
      "jpeg": "image/jpeg",
      "png": "image/png",
      "gif": "image/gif",
      "svg": "image/svg+xml",
      "xml": "application/xml",
      "json": "application/json",
      "zip": "application/zip",
      "mp3": "audio/mpeg",
      "mp4": "video/mp4",
      "mov": "video/quicktime",
      "doc": "application/msword",
      "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      "xls": "application/vnd.ms-excel",
      "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "ppt": "application/vnd.ms-powerpoint",
      "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    ]

    return mimeTypes[fileExtension] ?? "application/octet-stream"
  }
}
