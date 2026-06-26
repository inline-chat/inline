import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

enum MacDevtoolsMediaCacheDirectory: String, CaseIterable, Identifiable, Sendable {
  case photos
  case videos
  case documents
  case voices

  var id: Self { self }

  var title: String {
    switch self {
    case .photos: "Photos"
    case .videos: "Videos"
    case .documents: "Documents"
    case .voices: "Voices"
    }
  }

  var systemImage: String {
    switch self {
    case .photos: "photo"
    case .videos: "film"
    case .documents: "doc"
    case .voices: "waveform"
    }
  }

  var folderName: String {
    switch self {
    case .photos: "Photos"
    case .videos: "Videos"
    case .documents: "Documents"
    case .voices: "Voices"
    }
  }
}

enum MacDevtoolsMediaCacheScope: String, CaseIterable, Identifiable, Sendable {
  case all
  case photos
  case videos
  case documents
  case voices

  var id: Self { self }

  var title: String {
    switch self {
    case .all: "All"
    case .photos: "Photos"
    case .videos: "Videos"
    case .documents: "Documents"
    case .voices: "Voices"
    }
  }

  var directory: MacDevtoolsMediaCacheDirectory? {
    switch self {
    case .all: nil
    case .photos: .photos
    case .videos: .videos
    case .documents: .documents
    case .voices: .voices
    }
  }
}

struct MacDevtoolsMediaCacheItem: Identifiable, Hashable, Sendable {
  let id: String
  let directory: MacDevtoolsMediaCacheDirectory
  let url: URL
  let fileName: String
  let byteCount: Int64
  let modifiedAt: Date?
  let typeDescription: String?
  let mimeType: String?
  let pixelWidth: Int?
  let pixelHeight: Int?
  let isImage: Bool

  var sizeText: String {
    MacDevtoolsMediaCacheFormat.fileSize(byteCount)
  }

  var dimensionsText: String {
    guard let pixelWidth, let pixelHeight else { return "-" }
    return "\(pixelWidth)x\(pixelHeight)"
  }

  var modifiedText: String {
    guard let modifiedAt else { return "-" }
    return modifiedAt.formatted(.dateTime.month().day().hour().minute())
  }

  var detailTypeText: String {
    if let mimeType, let typeDescription {
      return "\(typeDescription) (\(mimeType))"
    }
    return typeDescription ?? mimeType ?? "Unknown"
  }

  var path: String {
    url.path
  }
}

@MainActor
@Observable
final class MacDevtoolsMediaCacheStore {
  var items: [MacDevtoolsMediaCacheItem] = []
  var scope: MacDevtoolsMediaCacheScope = .all
  var filter = ""
  var selectedIDs: Set<MacDevtoolsMediaCacheItem.ID> = []
  var focusedItemID: MacDevtoolsMediaCacheItem.ID?
  var isLoading = false
  var statusMessage: String?

  @ObservationIgnored private var loadTask: Task<Void, Never>?

  deinit {
    loadTask?.cancel()
  }

  var filteredItems: [MacDevtoolsMediaCacheItem] {
    let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    return items.filter { item in
      if let directory = scope.directory, item.directory != directory {
        return false
      }

      guard query.isEmpty == false else { return true }

      return item.fileName.lowercased().contains(query)
        || item.directory.title.lowercased().contains(query)
        || item.path.lowercased().contains(query)
        || item.dimensionsText.lowercased().contains(query)
        || (item.mimeType?.lowercased().contains(query) ?? false)
        || (item.typeDescription?.lowercased().contains(query) ?? false)
    }
  }

  var selectedItem: MacDevtoolsMediaCacheItem? {
    let items = selectedItems
    if let focusedItemID,
       let item = items.first(where: { $0.id == focusedItemID })
    {
      return item
    }

    return items.first
  }

  var selectedItems: [MacDevtoolsMediaCacheItem] {
    guard selectedIDs.isEmpty == false else { return [] }
    return filteredItems.filter { selectedIDs.contains($0.id) }
  }

  var summaryText: String {
    let files = filteredItems
    let bytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
    let size = MacDevtoolsMediaCacheFormat.fileSize(bytes)

    guard files.count != items.count else {
      return "\(items.count) files, \(size)"
    }

    return "\(files.count) of \(items.count) files, \(size)"
  }

  func refresh() {
    loadTask?.cancel()
    isLoading = true
    statusMessage = nil

    loadTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        MacDevtoolsMediaCacheScanner.scan()
      }.value

      guard Task.isCancelled == false, let self else { return }

      items = result.sorted {
        if $0.directory != $1.directory {
          return $0.directory.rawValue < $1.directory.rawValue
        }
        return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
      }

      pruneSelection()

      isLoading = false
      statusMessage = "Loaded \(items.count) cached media files"
    }
  }

  func cancelRefresh() {
    loadTask?.cancel()
    loadTask = nil
    isLoading = false
  }

  func updateSelectionFocus() {
    let items = selectedItems
    guard items.isEmpty == false else {
      focusedItemID = nil
      return
    }

    if let focusedItemID,
       items.contains(where: { $0.id == focusedItemID })
    {
      return
    }

    focusedItemID = items.first?.id
  }

  func revealSelected() {
    let urls = selectedItems.map(\.url)
    guard urls.isEmpty == false else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func openSelected() {
    let urls = selectedItems.map(\.url)
    guard urls.isEmpty == false else { return }

    for url in urls {
      NSWorkspace.shared.open(url)
    }
  }

  func copySelectedPaths() {
    let items = selectedItems
    guard items.isEmpty == false else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    statusMessage = items.count == 1 ? "Copied \(items[0].fileName) path" : "Copied \(items.count) paths"
  }

  func delete(_ itemsToDelete: [MacDevtoolsMediaCacheItem]) {
    guard itemsToDelete.isEmpty == false else { return }

    var deletedIDs = Set<MacDevtoolsMediaCacheItem.ID>()
    var failedCount = 0

    for item in itemsToDelete {
      do {
        try FileManager.default.removeItem(at: item.url)
        deletedIDs.insert(item.id)
      } catch {
        failedCount += 1
      }
    }

    if deletedIDs.isEmpty == false {
      items.removeAll { deletedIDs.contains($0.id) }
      selectedIDs.subtract(deletedIDs)
      updateSelectionFocus()
    }

    if failedCount > 0 {
      statusMessage = "Pruned \(deletedIDs.count) files, \(failedCount) failed"
    } else {
      statusMessage = deletedIDs.count == 1 ? "Pruned 1 cached file" : "Pruned \(deletedIDs.count) cached files"
    }
  }

  private func pruneSelection() {
    let ids = Set(items.map(\.id))
    selectedIDs.formIntersection(ids)

    if let focusedItemID,
       selectedIDs.contains(focusedItemID)
    {
      return
    }

    focusedItemID = selectedIDs.first
  }
}

private enum MacDevtoolsMediaCacheScanner {
  static func scan() -> [MacDevtoolsMediaCacheItem] {
    MacDevtoolsMediaCacheDirectory.allCases.flatMap { directory in
      scan(directory)
    }
  }

  private static func scan(_ directory: MacDevtoolsMediaCacheDirectory) -> [MacDevtoolsMediaCacheItem] {
    let root = MacDevtoolsMediaCachePaths.directory(for: directory)
    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .fileSizeKey,
      .contentModificationDateKey,
      .typeIdentifierKey,
    ]

    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return urls.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true
      else {
        return nil
      }

      let typeIdentifier = values.typeIdentifier
      let contentType = typeIdentifier.flatMap { UTType($0) }
      let isImage = contentType?.conforms(to: .image) ?? false
      let dimensions = isImage ? imageDimensions(for: url) : nil
      let byteCount = Int64(values.fileSize ?? 0)

      return MacDevtoolsMediaCacheItem(
        id: "\(directory.rawValue):\(url.path)",
        directory: directory,
        url: url,
        fileName: url.lastPathComponent,
        byteCount: byteCount,
        modifiedAt: values.contentModificationDate,
        typeDescription: contentType?.localizedDescription,
        mimeType: contentType?.preferredMIMEType,
        pixelWidth: dimensions?.width,
        pixelHeight: dimensions?.height,
        isImage: isImage
      )
    }
  }

  private static func imageDimensions(for url: URL) -> (width: Int, height: Int)? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      return nil
    }

    return (width.intValue, height.intValue)
  }
}

private enum MacDevtoolsMediaCachePaths {
  static func directory(for directory: MacDevtoolsMediaCacheDirectory) -> URL {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    let url = appSupport.appendingPathComponent(directory.folderName, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private enum MacDevtoolsMediaCacheFormat {
  static func fileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: max(bytes, 0))
  }
}
