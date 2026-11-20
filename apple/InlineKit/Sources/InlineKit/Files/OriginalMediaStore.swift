import Foundation
import Logger

/// Keeps the untouched file behind an attached photo or video until its message goes out, so
/// the composer's Original toggle can send that file instead of the compressed copy. Copies are
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

public extension FileMediaItem {
  /// Whether the composer's Original toggle changes how this item is sent.
  var canSendAsOriginal: Bool {
    switch self {
    case .photo, .video: true
    case .document, .voice: false
    }
  }

  /// The composer's send with Original on: each photo and video is swapped for its untouched
  /// file, in order. An item whose original is gone is sent as it is.
  static func withOriginals(_ items: [FileMediaItem]) async -> [FileMediaItem] {
    var result: [FileMediaItem] = []
    result.reserveCapacity(items.count)
    for item in items {
      guard item.canSendAsOriginal else {
        result.append(item)
        continue
      }
      do {
        result.append(try await item.replacedWithOriginalDocument() ?? item)
      } catch {
        Log.shared.error("Couldn't send the original file; sending the compressed one", error: error)
        result.append(item)
      }
    }
    return result
  }

  /// The untouched file behind a photo or video, saved as a document to send in its place, the
  /// way Telegram's Send as File works: same bytes, same metadata. The compressed item is
  /// removed. Returns nil when there is no original to send (the item is then sent as it is).
  func replacedWithOriginalDocument() async throws -> FileMediaItem? {
    switch self {
    case let .photo(photoInfo):
      guard let original = OriginalMediaStore.original(for: self) else { return nil }
      let document = try await FileCache.saveDocumentWithThumbnail(url: original)
      OriginalMediaStore.discard(for: self)
      await FileCache.discardLocalPhoto(photoInfo)
      return .document(document)
    case let .video(videoInfo):
      // The cached video is already an untouched copy; a kept original adds its real file name.
      let original = OriginalMediaStore.original(for: self) ?? localFileURL()
      guard let original, FileManager.default.fileExists(atPath: original.path) else { return nil }
      let document = try await FileCache.saveDocumentWithThumbnail(url: original)
      OriginalMediaStore.discard(for: self)
      await FileCache.discardLocalVideo(videoInfo)
      return .document(document)
    case .document, .voice:
      return nil
    }
  }
}
