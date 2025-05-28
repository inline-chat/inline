import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum PasteboardAttachment {
  case image(NSImage, URL?)
  case video(URL, thumbnail: NSImage?)
  case file(URL, thumbnail: NSImage?)
  case text(String)
}

class InlinePasteboard {
  static func findAttachments(from pasteboard: NSPasteboard) -> [PasteboardAttachment] {
    var attachments: [PasteboardAttachment] = []

    for item in pasteboard.pasteboardItems ?? [] {
      if let attachment = findBestAttachment(for: item) {
        attachments.append(attachment)
      }
    }

    return attachments
  }

  private static func findBestAttachment(for item: NSPasteboardItem) -> PasteboardAttachment? {
    let types = item.types

    // Priority order: file URLs > specific content types > raw data > text

    // 1. Check for file URLs first (highest priority)
    if types.contains(.fileURL) {
      if let urlString = item.string(forType: .fileURL),
         let url = URL(string: urlString)
      {
        return handleFileURL(url)
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
        let url = createTempFileURL(data: pdfData, extension: "pdf")
        return .file(url, thumbnail: thumbnail)
      }
    }

    // 3. Check for video content
    if let videoType = types.first(where: { isVideoType($0) }) {
      if let videoData = item.data(forType: videoType) {
        let url = createTempFileURL(data: videoData, extension: getFileExtension(for: videoType))
        if let thumbnail = generateVideoThumbnail(from: url) {
          return .video(url, thumbnail: thumbnail)
        } else {
          return .file(url, thumbnail: nil)
        }
      }
    }

    // 4. Check for images (including public.image and specific formats)
    if let imageType = types.first(where: { isImageType($0) }) {
      if let imageData = item.data(forType: imageType),
         let image = NSImage(data: imageData)
      {
        // Check if this is a file URL image vs raw image data
        var sourceURL: URL? = nil
        if types.contains(.fileURL),
           let urlString = item.string(forType: .fileURL),
           let url = URL(string: urlString)
        {
          sourceURL = url
        }

        return .image(image, sourceURL)
      }
    }

    return nil
  }

  private static func handleFileURL(_ url: URL) -> PasteboardAttachment? {
    let fileExtension = url.pathExtension.lowercased()

    // Check if it's a video file
    if isVideoFileExtension(fileExtension) {
      return .video(url, thumbnail: nil)
      // Until we encode video to our custom mp4 format, we won't generate thumbnails
//      if let thumbnail = generateVideoThumbnail(from: url) {
//        return .video(url, thumbnail: thumbnail)
//      }
    }

    // Check if it's an image file
    if isImageFileExtension(fileExtension) {
      if let image = NSImage(contentsOf: url) {
        return .image(image, url)
      }
    }

    // Check if it's a PDF
    if fileExtension == "pdf" {
      if let thumbnail = generatePDFThumbnail(from: url) {
        return .file(url, thumbnail: thumbnail)
      }
    }

    return .file(url, thumbnail: nil)
  }

  private static func isVideoType(_ type: NSPasteboard.PasteboardType) -> Bool {
    let videoTypes: [String] = [
      "public.movie", "public.video", "public.mpeg-4",
      "com.apple.quicktime-movie", "public.avi", "public.3gpp",
    ]
    return videoTypes.contains(type.rawValue)
  }

  private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
    let imageTypes: [String] = [
      "public.image", "public.png", "public.jpeg", "public.tiff",
      "com.apple.pict", "public.gif", "com.compuserve.gif",
      "public.heic", "public.webp",
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
      case "com.apple.quicktime-movie": "mov"
      case "public.png": "png"
      case "public.jpeg": "jpg"
      case "public.tiff": "tiff"
      default: "dat"
    }
  }

  private static func createTempFileURL(data: Data, extension ext: String) -> URL {
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = UUID().uuidString + "." + ext
    let url = tempDir.appendingPathComponent(fileName)

    try? data.write(to: url)
    return url
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
