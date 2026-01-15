import AppKit
import AVFoundation
import Foundation
import Logger

enum PasteboardAttachment {
  case image(NSImage, URL?)
  case video(URL, thumbnail: NSImage?)
  case file(URL, thumbnail: NSImage?)
  case text(String)
}

enum PasteboardAttachmentFailure: Equatable {
  case unreadableFile(url: URL, isSymlink: Bool, isTelegram: Bool)

  var isTelegramSource: Bool {
    switch self {
      case let .unreadableFile(_, _, isTelegram):
        return isTelegram
    }
  }

  var isSymlink: Bool {
    switch self {
      case let .unreadableFile(_, isSymlink, _):
        return isSymlink
    }
  }
}

struct PasteboardAttachmentResult {
  let attachments: [PasteboardAttachment]
  let failures: [PasteboardAttachmentFailure]
}

class InlinePasteboard {
  private static let preferredImageTypes: [NSPasteboard.PasteboardType] = [
    .png,
    NSPasteboard.PasteboardType("image/png"),
    NSPasteboard.PasteboardType("public.jpeg"),
    NSPasteboard.PasteboardType("image/jpeg"),
    NSPasteboard.PasteboardType("public.heic"),
    NSPasteboard.PasteboardType("image/heic"),
    NSPasteboard.PasteboardType("public.webp"),
    NSPasteboard.PasteboardType("image/webp"),
    NSPasteboard.PasteboardType("public.gif"),
    NSPasteboard.PasteboardType("image/gif"),
    .tiff, // keep TIFF last; it's often much larger than PNG/JPEG
    NSPasteboard.PasteboardType("public.image"),
  ]

  private static let preferredVideoTypes: [NSPasteboard.PasteboardType] = [
    NSPasteboard.PasteboardType("public.mpeg-4"),
    NSPasteboard.PasteboardType("video/mp4"),
    NSPasteboard.PasteboardType("com.apple.quicktime-movie"),
    NSPasteboard.PasteboardType("public.movie"),
    NSPasteboard.PasteboardType("public.video"),
  ]

  static func findAttachmentsResult(
    from pasteboard: NSPasteboard,
    includeText: Bool = true
  ) -> PasteboardAttachmentResult {
    var attachments: [PasteboardAttachment] = []
    var failures: [PasteboardAttachmentFailure] = []

    for item in pasteboard.pasteboardItems ?? [] {
      let result = findBestAttachment(for: item, includeText: includeText)
      if let attachment = result.attachment {
        attachments.append(attachment)
      }
      failures.append(contentsOf: result.failures)
    }

    return PasteboardAttachmentResult(attachments: attachments, failures: failures)
  }

  static func findAttachments(from pasteboard: NSPasteboard, includeText: Bool = true) -> [PasteboardAttachment] {
    findAttachmentsResult(from: pasteboard, includeText: includeText).attachments
  }

  private struct ItemAttachmentResult {
    let attachment: PasteboardAttachment?
    let failures: [PasteboardAttachmentFailure]
  }

  private static func findBestAttachment(for item: NSPasteboardItem, includeText: Bool) -> ItemAttachmentResult {
    let types = item.types
    var failures: [PasteboardAttachmentFailure] = []

    // Priority order: file URLs > specific content types > raw data > text

    // 1. Check for file URLs first (highest priority)
    if types.contains(.fileURL) {
      if let urlString = item.string(forType: .fileURL),
         let url = parseFileURL(urlString)
      {
        let result = handleFileURL(url)
        if result.attachment != nil {
          return result
        }
        failures.append(contentsOf: result.failures)
      }
    }

    // 2. Check for PDF (should be treated as file with thumbnail)
    if types.contains(.pdf) {
      if let pdfData = item.data(forType: .pdf),
         let pdfRep = NSPDFImageRep(data: pdfData)
      {
        let thumbnail = NSImage()
        thumbnail.addRepresentation(pdfRep)

        // Try to get URL if available, otherwise create temp file
        do {
          let url = try createTempFileURL(data: pdfData, extension: "pdf")
          return ItemAttachmentResult(attachment: .file(url, thumbnail: thumbnail), failures: failures)
        } catch {
          Log.shared.error("Failed to write temp PDF for pasteboard", error: error)
          return ItemAttachmentResult(attachment: nil, failures: failures)
        }
      }
    }

    // 3. Check for video content
    if let videoType = preferredVideoTypes.first(where: { types.contains($0) }) ??
      types.first(where: { isVideoType($0) })
    {
      if let videoData = item.data(forType: videoType) {
        do {
          let url = try createTempFileURL(data: videoData, extension: getFileExtension(for: videoType))
          // Thumbnail generation can be expensive; defer to later pipeline.
          return ItemAttachmentResult(attachment: .video(url, thumbnail: nil), failures: failures)
        } catch {
          Log.shared.error("Failed to write temp video for pasteboard", error: error)
          return ItemAttachmentResult(attachment: nil, failures: failures)
        }
      }
    }

    // 4. Check for images (including public.image and specific formats)
    if let imageType = preferredImageTypes.first(where: { types.contains($0) }) ??
      types.first(where: { isImageType($0) })
    {
      if let imageData = item.data(forType: imageType),
         let image = NSImage(data: imageData)
      {
        // Check if this is a file URL image vs raw image data
        var sourceURL: URL? = nil
        if types.contains(.fileURL),
           let urlString = item.string(forType: .fileURL),
           let url = parseFileURL(urlString)
        {
          sourceURL = url
        }

        return ItemAttachmentResult(attachment: .image(image, sourceURL), failures: failures)
      }
    }

    // 5. Check for text
    if includeText, types.contains(.string) {
      if let text = item.string(forType: .string) {
        return ItemAttachmentResult(attachment: .text(text), failures: failures)
      }
    }

    return ItemAttachmentResult(attachment: nil, failures: failures)
  }

  private static func handleFileURL(_ url: URL) -> ItemAttachmentResult {
    let fileExtension = url.pathExtension.lowercased()
    let path = url.path
    let fileManager = FileManager.default
    let exists = fileManager.fileExists(atPath: path)
    let isReadable = fileManager.isReadableFile(atPath: path)

    if !exists || !isReadable {
      let isSymlink = isSymbolicLink(url)
      let isTelegram = isLikelyTelegramContainerURL(url)
      return ItemAttachmentResult(
        attachment: nil,
        failures: [.unreadableFile(url: url, isSymlink: isSymlink, isTelegram: isTelegram)]
      )
    }

    // Check if it's a video file
    if isVideoFileExtension(fileExtension) {
      return ItemAttachmentResult(attachment: .video(url, thumbnail: nil), failures: [])
      // Until we encode video to our custom mp4 format, we won't generate thumbnails
//      if let thumbnail = generateVideoThumbnail(from: url) {
//        return .video(url, thumbnail: thumbnail)
//      }
    }

    // Check if it's an image file
    if isImageFileExtension(fileExtension) {
      if let image = NSImage(contentsOf: url) {
        return ItemAttachmentResult(attachment: .image(image, url), failures: [])
      }
    }

    // Check if it's a PDF
    if fileExtension == "pdf" {
      if let thumbnail = generatePDFThumbnail(from: url) {
        return ItemAttachmentResult(attachment: .file(url, thumbnail: thumbnail), failures: [])
      }
    }

    return ItemAttachmentResult(attachment: .file(url, thumbnail: nil), failures: [])
  }

  private static func isVideoType(_ type: NSPasteboard.PasteboardType) -> Bool {
    let videoTypes: [String] = [
      "public.movie", "public.video", "public.mpeg-4",
      "com.apple.quicktime-movie", "public.avi", "public.3gpp",
      "video/mp4",
    ]
    return videoTypes.contains(type.rawValue)
  }

  private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
    let imageTypes: [String] = [
      "public.image", "public.png", "public.jpeg", "public.tiff",
      "com.apple.pict", "public.gif", "com.compuserve.gif",
      "public.heic", "public.webp",
      "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic",
    ]
    return imageTypes.contains(type.rawValue)
  }

  private static func isVideoFileExtension(_ ext: String) -> Bool {
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "3gp"]
    return videoExtensions.contains(ext)
  }

  private static func isImageFileExtension(_ ext: String) -> Bool {
    let imageExtensions = ["jpg", "jpeg", "png", "gif", "tiff", "tif", "bmp", "heic", "webp"]
    return imageExtensions.contains(ext)
  }

  private static func getFileExtension(for type: NSPasteboard.PasteboardType) -> String {
    switch type.rawValue {
      case "public.mpeg-4": "mp4"
      case "video/mp4": "mp4"
      case "com.apple.quicktime-movie": "mov"
      case "public.png": "png"
      case "image/png": "png"
      case "public.jpeg": "jpg"
      case "image/jpeg": "jpg"
      case "public.tiff": "tiff"
      default: "dat"
    }
  }

  private static func createTempFileURL(data: Data, extension ext: String) throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = UUID().uuidString + "." + ext
    let url = tempDir.appendingPathComponent(fileName)

    // Avoid `.atomic` here to prevent doubling write work for large pasteboard payloads.
    try data.write(to: url)
    return url
  }

  private static func parseFileURL(_ urlString: String) -> URL? {
    if urlString.hasPrefix("file://") {
      return URL(string: urlString)
    }

    // Some producers provide a path-like string instead of a file URL.
    return URL(fileURLWithPath: urlString)
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    do {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      return values.isSymbolicLink ?? false
    } catch {
      return false
    }
  }

  private static func isLikelyTelegramContainerURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    guard path.contains("telegram") else { return false }
    return path.contains("/library/group containers/") || path.contains("/library/containers/")
  }

  private static func generateVideoThumbnail(from url: URL) -> NSImage? {
    let asset = AVAsset(url: url)
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true

    do {
      let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
      return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    } catch {
      return nil
    }
  }

  private static func generatePDFThumbnail(from url: URL) -> NSImage? {
    guard let pdfData = try? Data(contentsOf: url),
          let pdfRep = NSPDFImageRep(data: pdfData)
    else {
      return nil
    }

    let thumbnail = NSImage()
    thumbnail.addRepresentation(pdfRep)
    return thumbnail
  }
}
