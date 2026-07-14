import AppKit
import Foundation

public enum PasteboardAttachment {
  case image(NSImage, URL?)
  case animatedImage(URL)
  case video(URL, thumbnail: NSImage?)
  case file(URL, thumbnail: NSImage?)
  case text(String)
}

public enum PasteboardAttachmentFailure: Equatable, Sendable {
  case directory(URL)
  case materializationFailed
  case unreadableFile(url: URL, isSymlink: Bool, isTelegram: Bool)

  public var isDirectory: Bool {
    if case .directory = self { return true }
    return false
  }

  public var isTelegramSource: Bool {
    if case let .unreadableFile(_, _, isTelegram) = self { return isTelegram }
    return false
  }

  public var isSymlink: Bool {
    if case let .unreadableFile(_, isSymlink, _) = self { return isSymlink }
    return false
  }

  public var userFacingMessage: String {
    switch self {
    case .directory:
      "Folders aren't supported yet."
    case .materializationFailed:
      "Couldn't prepare that item."
    case let .unreadableFile(_, isSymlink, isTelegram):
      if isTelegram {
        "Telegram copies images as private files. Drag the image or use Save Media."
      } else if isSymlink {
        "That file is a private symlink and can't be read."
      } else {
        "Couldn't read that file."
      }
    }
  }
}

public struct PasteboardAttachmentResult {
  public let attachments: [PasteboardAttachment]
  public let failures: [PasteboardAttachmentFailure]
}

public enum InlinePasteboard {
  private static let preferredImageTypes: [NSPasteboard.PasteboardType] = [
    .png,
    NSPasteboard.PasteboardType("public.jpeg"),
    NSPasteboard.PasteboardType("public.heic"),
    NSPasteboard.PasteboardType("public.heif"),
    NSPasteboard.PasteboardType("public.avif"),
    NSPasteboard.PasteboardType("org.webmproject.webp"),
    NSPasteboard.PasteboardType("public.webp"),
    NSPasteboard.PasteboardType("com.compuserve.gif"),
    NSPasteboard.PasteboardType("public.gif"),
    .tiff,
    NSPasteboard.PasteboardType("public.image"),
  ]

  private static let preferredVideoTypes: [NSPasteboard.PasteboardType] = [
    NSPasteboard.PasteboardType("public.mpeg-4"),
    NSPasteboard.PasteboardType("com.apple.quicktime-movie"),
    NSPasteboard.PasteboardType("com.apple.m4v-video"),
    NSPasteboard.PasteboardType("public.movie"),
    NSPasteboard.PasteboardType("public.video"),
    NSPasteboard.PasteboardType("public.avi"),
    NSPasteboard.PasteboardType("public.3gpp"),
    NSPasteboard.PasteboardType("org.webmproject.webm"),
    NSPasteboard.PasteboardType("public.webm"),
  ]

  public static let draggedTypes: [NSPasteboard.PasteboardType] = [
    .fileURL,
    .pdf,
  ] + preferredImageTypes + preferredVideoTypes

  public static let draggedTypeIdentifiers = draggedTypes.map(\.rawValue)

  public static func canImportAttachments(
    from pasteboard: NSPasteboard,
    includeText: Bool = true
  ) -> Bool {
    let decodedFileURLs = readFileURLs(from: pasteboard)

    for item in pasteboard.pasteboardItems ?? [] {
      let types = item.types

      if types.contains(.fileURL),
         let value = item.string(forType: .fileURL),
         let url = resolveFileURL(value, decodedFileURLs: decodedFileURLs) {
        let failure = fileURLFailure(url)
        if failure?.isDirectory == true {
          continue
        }
        if failure == nil {
          return true
        }
      }

      if types.contains(.pdf) ||
        preferredVideoTypes.contains(where: types.contains) ||
        preferredImageTypes.contains(where: types.contains) {
        return true
      }

      if includeText, types.contains(.string) {
        return true
      }
    }

    return false
  }

  public static func findAttachmentsResult(
    from pasteboard: NSPasteboard,
    includeText: Bool = true
  ) -> PasteboardAttachmentResult {
    let decodedFileURLs = readFileURLs(from: pasteboard)

    var attachments: [PasteboardAttachment] = []
    var failures: [PasteboardAttachmentFailure] = []

    for item in pasteboard.pasteboardItems ?? [] {
      let result = findBestAttachment(
        for: item,
        decodedFileURLs: decodedFileURLs,
        includeText: includeText
      )
      if let attachment = result.attachment {
        attachments.append(attachment)
      }
      failures.append(contentsOf: result.failures)
    }

    return PasteboardAttachmentResult(
      attachments: attachments,
      failures: failures
    )
  }

  public static func findAttachments(
    from pasteboard: NSPasteboard,
    includeText: Bool = true
  ) -> [PasteboardAttachment] {
    findAttachmentsResult(
      from: pasteboard,
      includeText: includeText
    ).attachments
  }

  public static func findAttachmentsResult(
    from transfers: [IncomingAttachmentTransfer]
  ) -> PasteboardAttachmentResult {
    var attachments: [PasteboardAttachment] = []
    var failures: [PasteboardAttachmentFailure] = []

    for transfer in transfers {
      switch transfer.payload {
      case let .stagedFile(url, _):
        let result = handleFileURL(url)
        if let attachment = result.attachment {
          attachments.append(attachment)
        }
        failures.append(contentsOf: result.failures)
      case let .failure(failure):
        failures.append(failure)
      }
    }

    return PasteboardAttachmentResult(
      attachments: attachments,
      failures: failures
    )
  }

  private struct ItemAttachmentResult {
    let attachment: PasteboardAttachment?
    let failures: [PasteboardAttachmentFailure]
  }

  private static func findBestAttachment(
    for item: NSPasteboardItem,
    decodedFileURLs: [URL],
    includeText: Bool
  ) -> ItemAttachmentResult {
    let types = item.types
    var failures: [PasteboardAttachmentFailure] = []

    if types.contains(.fileURL),
       let value = item.string(forType: .fileURL),
       let url = resolveFileURL(value, decodedFileURLs: decodedFileURLs) {
      let result = handleFileURL(url)
      if result.attachment != nil {
        return result
      }
      if result.failures.contains(where: \.isDirectory) {
        return result
      }
      failures.append(contentsOf: result.failures)
    }

    if types.contains(.pdf), let data = item.data(forType: .pdf) {
      do {
        let url = try createTempFileURL(data: data, extension: "pdf")
        return ItemAttachmentResult(
          attachment: .file(url, thumbnail: nil),
          failures: []
        )
      } catch {
        failures.append(.materializationFailed)
      }
    }

    if let videoType = preferredVideoTypes.first(where: types.contains),
       let data = item.data(forType: videoType) {
      do {
        let url = try createTempFileURL(
          data: data,
          extension: fileExtension(for: videoType)
        )
        return ItemAttachmentResult(
          attachment: .video(url, thumbnail: nil),
          failures: []
        )
      } catch {
        failures.append(.materializationFailed)
      }
    }

    if let imageType = preferredImageTypes.first(where: types.contains),
       let data = item.data(forType: imageType) {
      let sourceURL: URL?
      if types.contains(.fileURL), let value = item.string(forType: .fileURL) {
        sourceURL = resolveFileURL(value, decodedFileURLs: decodedFileURLs).flatMap { url in
          fileURLFailure(url) == nil ? url : nil
        }
      } else {
        sourceURL = nil
      }

      if isAnimatedImageType(imageType) {
        do {
          let url = try sourceURL ?? createTempFileURL(
            data: data,
            extension: fileExtension(for: imageType)
          )
          return ItemAttachmentResult(
            attachment: .animatedImage(url),
            failures: []
          )
        } catch {
          failures.append(.materializationFailed)
        }
      } else if let image = NSImage(data: data) {
        return ItemAttachmentResult(
          attachment: .image(image, sourceURL),
          failures: []
        )
      }
    }

    if includeText, types.contains(.string), let text = item.string(forType: .string) {
      return ItemAttachmentResult(
        attachment: .text(text),
        failures: []
      )
    }

    return ItemAttachmentResult(
      attachment: nil,
      failures: failures
    )
  }

  private static func handleFileURL(_ url: URL) -> ItemAttachmentResult {
    if let failure = fileURLFailure(url) {
      return ItemAttachmentResult(
        attachment: nil,
        failures: [failure]
      )
    }

    let fileExtension = url.pathExtension.lowercased()

    if isVideoFileExtension(fileExtension) {
      return ItemAttachmentResult(
        attachment: .video(url, thumbnail: nil),
        failures: []
      )
    }

    if fileExtension == "gif" {
      return ItemAttachmentResult(
        attachment: .animatedImage(url),
        failures: []
      )
    }

    if isImageFileExtension(fileExtension), let image = NSImage(contentsOf: url) {
      return ItemAttachmentResult(
        attachment: .image(image, url),
        failures: []
      )
    }

    if fileExtension == "pdf" {
      return ItemAttachmentResult(
        attachment: .file(url, thumbnail: nil),
        failures: []
      )
    }

    return ItemAttachmentResult(
      attachment: .file(url, thumbnail: nil),
      failures: []
    )
  }

  private static func fileURLFailure(_ url: URL) -> PasteboardAttachmentFailure? {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      return .directory(url)
    }

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: url.path) || !fileManager.isReadableFile(atPath: url.path) {
      return .unreadableFile(
        url: url,
        isSymlink: isSymbolicLink(url),
        isTelegram: isLikelyTelegramContainerURL(url)
      )
    }

    return nil
  }

  private static func isAnimatedImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
    [
      "com.compuserve.gif",
      "public.gif",
    ].contains(type.rawValue)
  }

  private static func isVideoFileExtension(_ value: String) -> Bool {
    [
      "3gp", "avi", "flv", "m4v", "mkv", "mov", "mp4", "webm", "wmv",
    ].contains(value)
  }

  private static func isImageFileExtension(_ value: String) -> Bool {
    [
      "avif", "bmp", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ].contains(value)
  }

  private static func fileExtension(for type: NSPasteboard.PasteboardType) -> String {
    switch type.rawValue {
    case "public.mpeg-4": "mp4"
    case "com.apple.quicktime-movie", "public.movie": "mov"
    case "com.apple.m4v-video": "m4v"
    case "public.avi": "avi"
    case "public.3gpp": "3gp"
    case "org.webmproject.webm", "public.webm": "webm"
    case "public.png": "png"
    case "public.jpeg": "jpg"
    case "public.heic": "heic"
    case "public.heif": "heif"
    case "public.avif": "avif"
    case "org.webmproject.webp", "public.webp": "webp"
    case "public.gif", "com.compuserve.gif": "gif"
    case "public.tiff": "tiff"
    default: "dat"
    }
  }

  private static func createTempFileURL(data: Data, extension value: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(value)
    try data.write(to: url)
    return url
  }

  private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    // NSPasteboardReading consumes the sandbox extensions granted by drag/drop.
    // Reading only the raw file-url string can make a valid external file look unreadable.
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true,
    ]
    let objects = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: options
    ) ?? []
    return objects.compactMap { object in
      if let url = object as? URL { return url }
      if let url = object as? NSURL { return url as URL }
      return nil
    }
  }

  private static func resolveFileURL(
    _ value: String,
    decodedFileURLs: [URL]
  ) -> URL? {
    guard let parsedURL = parseFileURL(value) else { return nil }
    return decodedFileURLs.first { decodedURL in
      decodedURL.standardizedFileURL.path == parsedURL.standardizedFileURL.path
    } ?? parsedURL
  }

  private static func parseFileURL(_ value: String) -> URL? {
    if value.hasPrefix("file://") {
      return URL(string: value)
    }
    return URL(fileURLWithPath: value)
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private static func isLikelyTelegramContainerURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    guard path.contains("telegram") else { return false }
    return path.contains("/library/group containers/") || path.contains("/library/containers/")
  }

}
