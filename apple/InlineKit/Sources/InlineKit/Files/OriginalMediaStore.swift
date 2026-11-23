import AVFoundation
import Foundation
import ImageIO
import Logger
import UniformTypeIdentifiers

/// Keeps the untouched file behind an attached photo or video until its message goes out, so
/// Send as Original can switch the item to that file instead of the compressed copy. Copies are
/// clones on APFS, so keeping them costs almost no space. They live in the temporary directory:
/// if the system clears it, the item is simply sent compressed.
public enum OriginalMediaStore {
  public static var directory: URL {
    FileHelpers.getTrueTemporaryDirectory().appendingPathComponent("inline-originals", isDirectory: true)
  }

  /// Originals older than this belong to drafts nobody sent.
  static let maximumAge: TimeInterval = 3 * 24 * 60 * 60

  private static let log = Log.scoped("OriginalMediaStore")

  /// The folder for one attachment: named after its local file, which is unique per attachment.
  static func folder(for media: FileMediaItem, in root: URL = directory) -> URL? {
    guard let localPath = media.getLocalPath() else { return nil }
    let stem = ((localPath as NSString).lastPathComponent as NSString).deletingPathExtension
    guard !stem.isEmpty, !stem.contains("/") else { return nil }
    return root.appendingPathComponent(stem, isDirectory: true)
  }

  /// Keeps a copy of `url` as the original behind `media`, under its own file name.
  static func retain(copyOf url: URL, fileName: String? = nil, for media: FileMediaItem, in root: URL = directory) throws {
    guard let folder = folder(for: media, in: root) else { return }
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    let destination = try prepareFolder(folder).appendingPathComponent(safeFileName(fileName ?? url.lastPathComponent))
    try FileManager.default.copyItem(at: url, to: destination)
  }

  /// Keeps encoded bytes as the original behind `media`.
  static func retain(data: Data, fileName: String, for media: FileMediaItem, in root: URL = directory) throws {
    guard let folder = folder(for: media, in: root) else { return }
    let destination = try prepareFolder(folder).appendingPathComponent(safeFileName(fileName))
    try data.write(to: destination, options: .atomic)
  }

  /// The kept original for `media`, if there is one.
  public static func original(for media: FileMediaItem, in root: URL = directory) -> URL? {
    guard let folder = folder(for: media, in: root),
          let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else {
      return nil
    }
    return names.sorted().first { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
  }

  public static func discard(for media: FileMediaItem, in root: URL = directory) {
    guard let folder = folder(for: media, in: root) else { return }
    try? FileManager.default.removeItem(at: folder)
  }

  /// Removes originals left behind by drafts that were never sent.
  static func sweep(now: Date = Date(), in root: URL = directory) {
    let fileManager = FileManager.default
    guard let folders = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }
    for folder in folders {
      let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, now.timeIntervalSince(modified) > maximumAge {
        try? fileManager.removeItem(at: folder)
      }
    }
  }

  private static func prepareFolder(_ folder: URL) throws -> URL {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: folder.path) {
      try fileManager.removeItem(at: folder)
    }
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  static func safeFileName(_ name: String) -> String {
    let cleaned = (name as NSString).lastPathComponent
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "original" : cleaned
  }
}

/// What sending one photo or video as its original would send, for the menu that offers it.
public struct OriginalMediaSummary: Sendable, Equatable {
  public var byteCount: Int64
  public var includesLocation: Bool

  public init(byteCount: Int64, includesLocation: Bool) {
    self.byteCount = byteCount
    self.includesLocation = includesLocation
  }

  /// "2.8 MB · Includes location"
  public var detailText: String {
    let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    return includesLocation ? "\(size) · Includes location" : size
  }
}

public extension OriginalMediaStore {
  /// The size of the untouched file behind `media` and whether it carries a location. Nil when
  /// there is nothing to send as original. Reads only file headers.
  @concurrent
  static func summary(for media: FileMediaItem) async -> OriginalMediaSummary? {
    let url: URL?
    switch media {
    case .photo:
      url = original(for: media)
    case .video:
      url = media.originalVideoFile
    case .document:
      // An image or video file that Send as Original switched to (or that was attached as one).
      guard media.canSwitchOriginal else { return nil }
      url = media.localFileURL()
    case .voice:
      return nil
    }
    guard let url,
          let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
    else {
      return nil
    }
    let includesLocation = if media.isVideoForOriginal {
      await videoIncludesLocation(url)
    } else {
      imageIncludesLocation(url)
    }
    return OriginalMediaSummary(byteCount: size.int64Value, includesLocation: includesLocation)
  }

  internal static func imageIncludesLocation(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
          as? [CFString: Any],
          let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    else {
      return false
    }
    return gps[kCGImagePropertyGPSLatitude] != nil
  }

  /// Whether a video file carries camera, place or time details, or can't be read to tell.
  internal static func videoMayCarryIdentifyingMetadata(_ url: URL) async -> Bool {
    guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return true }
    let keys: Set<AVMetadataKey> = [
      .commonKeyLocation, .commonKeyMake, .commonKeyModel, .commonKeySoftware, .commonKeyCreationDate,
    ]
    let words = ["location", "make", "model", "creationdate", "software"]
    return items.contains { item in
      if let key = item.commonKey, keys.contains(key) { return true }
      let identifier = item.identifier?.rawValue.lowercased() ?? ""
      return words.contains { identifier.contains($0) }
    }
  }

  internal static func videoIncludesLocation(_ url: URL) async -> Bool {
    guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return false }
    return items.contains { item in
      item.commonKey == .commonKeyLocation
        || (item.identifier?.rawValue.localizedCaseInsensitiveContains("location") ?? false)
    }
  }
}

public extension FileMediaItem {
  /// Whether the item's menu offers Send as Original. A photo or video switches to its untouched
  /// file; an image or video file switches back to a compressed photo or video.
  var canSwitchOriginal: Bool {
    switch self {
    case .photo, .video:
      true
    case let .document(info):
      Self.switchableFileTypes(mimeType: info.document.mimeType, fileName: info.document.fileName)
        .contains { $0.conforms(to: .movie) || $0.conforms(to: .gif) || Self.isCompressibleImage($0) }
    case .voice:
      false
    }
  }

  /// True when the item goes as a file, unchanged: Send as Original is on.
  var isSentAsFile: Bool {
    if case .document = self { true } else { false }
  }

  /// The other form of this attachment, made without touching this item's files. A photo or
  /// video becomes a document of its untouched file; an image or video document becomes a
  /// compressed photo or video. Nil when it can't switch: no original was kept, or the image
  /// can only go as a file. The caller keeps one form and discards the other with
  /// `discardUnsent()`.
  func switchedForOriginal() async throws -> FileMediaItem? {
    switch self {
    case .photo:
      guard let original = OriginalMediaStore.original(for: self) else { return nil }
      return .document(try await FileCache.saveDocumentWithThumbnail(url: original))
    case .video:
      guard let original = originalVideoFile, FileManager.default.fileExists(atPath: original.path) else { return nil }
      return .document(try await FileCache.saveDocumentWithThumbnail(url: original))
    case let .document(info):
      guard canSwitchOriginal, let url = localFileURL(), FileManager.default.fileExists(atPath: url.path) else {
        return nil
      }
      let media = if isVideoForOriginal {
        try await AttachmentMediaMaterializer.video(url, originalFileName: info.document.fileName)
      } else if isGIFForOriginal {
        try await AttachmentMediaMaterializer.animatedImage(url, originalFileName: info.document.fileName)
      } else {
        try await AttachmentMediaMaterializer.photo(.file(url), originalFileName: info.document.fileName)
      }
      guard !media.isSentAsFile else {
        await media.discardUnsent()
        return nil
      }
      return media
    case .voice:
      return nil
    }
  }

  /// Removes the local files and rows of an attachment that leaves the composer unsent, such as
  /// the form Send as Original switched away from.
  func discardUnsent() async {
    switch self {
    case let .photo(info):
      OriginalMediaStore.discard(for: self)
      await FileCache.discardLocalPhoto(info)
    case let .video(info):
      OriginalMediaStore.discard(for: self)
      await FileCache.discardLocalVideo(info)
    case let .document(info):
      await FileCache.discardLocalDocument(info)
    case .voice:
      break
    }
  }

  /// The file Send as Original sends for a video. The cached video is an untouched copy too (a
  /// kept original adds its real file name), but an animation's cached video was converted from
  /// its GIF, so only the kept GIF will do.
  internal var originalVideoFile: URL? {
    guard case let .video(info) = self else { return nil }
    if let original = OriginalMediaStore.original(for: self) { return original }
    return info.video.isAnimated ? nil : localFileURL()
  }

  internal var isGIFForOriginal: Bool {
    guard case let .document(info) = self else { return false }
    return Self.switchableFileTypes(mimeType: info.document.mimeType, fileName: info.document.fileName)
      .contains { $0.conforms(to: .gif) }
  }

  internal var isVideoForOriginal: Bool {
    switch self {
    case .video:
      true
    case let .document(info):
      Self.switchableFileTypes(mimeType: info.document.mimeType, fileName: info.document.fileName)
        .contains { $0.conforms(to: .movie) }
    case .photo, .voice:
      false
    }
  }

  internal static func switchableFileTypes(mimeType: String?, fileName: String?) -> [UTType] {
    let fromMime = mimeType.flatMap { UTType(mimeType: $0) }
    let fromName = fileName.flatMap { name -> UTType? in
      let ext = (name as NSString).pathExtension
      return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }
    return [fromMime, fromName].compactMap { $0 }
  }

  /// A still image the photo preparer can compress. GIFs switch to an animation instead (as a
  /// photo they'd lose their motion), and vector art stays a file.
  internal static func isCompressibleImage(_ type: UTType) -> Bool {
    type.conforms(to: .image) && !type.conforms(to: .gif) && !type.conforms(to: .svg)
  }
}
