import AppKit
import InlineKit
import Logger
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// Shared pieces of the chat info resource tabs: month sections, cached formatters,
// Quick Look and file actions.

// MARK: - Sections

/// Items of one calendar month, newest first.
struct ChatInfoResourceSection<Item>: Identifiable {
  /// `year * 100 + month`, stable across pages.
  let id: Int
  let monthStart: Date
  var items: [Item]
}

enum ChatInfoResourceSections {
  /// Groups rows (ordered newest first) by month in one pass. A month boundary is
  /// computed only when a row leaves the current month, so this is cheap enough to run
  /// in `body` for thousands of rows.
  static func byMonth<Item>(_ items: [Item], date: (Item) -> Date) -> [ChatInfoResourceSection<Item>] {
    guard !items.isEmpty else { return [] }
    let calendar = Calendar.current
    var sections: [ChatInfoResourceSection<Item>] = []
    var indexByMonth: [Int: Int] = [:]
    var current: (interval: DateInterval, index: Int)?

    for item in items {
      let itemDate = date(item)
      if let current, current.interval.start <= itemDate, itemDate < current.interval.end {
        sections[current.index].items.append(item)
        continue
      }
      guard let interval = calendar.dateInterval(of: .month, for: itemDate) else { continue }
      let components = calendar.dateComponents([.year, .month], from: interval.start)
      let id = (components.year ?? 0) * 100 + (components.month ?? 0)
      let index: Int
      if let existing = indexByMonth[id] {
        index = existing
        sections[index].items.append(item)
      } else {
        index = sections.count
        indexByMonth[id] = index
        sections.append(ChatInfoResourceSection(id: id, monthStart: interval.start, items: [item]))
      }
      current = (interval, index)
    }

    // Rows arrive newest first; out-of-order dates only reorder whole months.
    if sections.count > 1, zip(sections, sections.dropFirst()).contains(where: { $0.id < $1.id }) {
      sections.sort { $0.id > $1.id }
    }
    return sections
  }
}

// MARK: - Formatting

enum ChatInfoResourceFormat {
  private static let monthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMM")
    return formatter
  }()

  private static let monthYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMMy")
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  private static let dayYearFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("yMMMd")
    return formatter
  }()

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  static let weekdayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEE")
    return formatter
  }()

  static let longDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter
  }()

  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  /// "November" in the current year, "November 2025" before.
  static func monthTitle(_ monthStart: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDate(monthStart, equalTo: Date(), toGranularity: .year) {
      return monthFormatter.string(from: monthStart)
    }
    return monthYearFormatter.string(from: monthStart)
  }

  /// A row's date: the time today, "Yesterday", "Nov 3", or "Nov 3, 2025".
  static func rowDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return timeFormatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
      return String(localized: "Yesterday")
    }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
      return dayFormatter.string(from: date)
    }
    return dayYearFormatter.string(from: date)
  }

  static func fileSize(_ bytes: Int?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    return byteFormatter.string(fromByteCount: Int64(bytes))
  }

  static func duration(_ seconds: Int) -> String {
    let clamped = max(seconds, 0)
    let hours = clamped / 3_600
    let minutes = (clamped % 3_600) / 60
    let remainder = clamped % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
  }
}

/// A day label for grouped resources: "Today", "Yesterday", a weekday this week, or a long date.
func chatInfoDateLabel(_ date: Date) -> String {
  let calendar = Calendar.current
  if calendar.isDateInToday(date) {
    return String(localized: "Today")
  }
  if calendar.isDateInYesterday(date) {
    return String(localized: "Yesterday")
  }
  if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
    return ChatInfoResourceFormat.weekdayFormatter.string(from: date)
  }
  return ChatInfoResourceFormat.longDateFormatter.string(from: date)
}

// MARK: - Local files

@MainActor
enum ChatInfoResourceFiles {
  /// The cache folders, resolved once per pass over many rows.
  struct Directories {
    let photos = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
    let videos = FileHelpers.getLocalCacheDirectory(for: .videos, createIfNeeded: false)
    let documents = FileHelpers.getLocalCacheDirectory(for: .documents, createIfNeeded: false)

    func url(_ directory: FileLocalCacheDirectory, path: String?) -> URL? {
      guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
      switch directory {
        case .photos: return photos.appendingPathComponent(path)
        case .videos: return videos.appendingPathComponent(path)
        case .documents: return documents.appendingPathComponent(path)
        case .voices: return FileHelpers.getLocalCacheDirectory(for: .voices, createIfNeeded: false)
          .appendingPathComponent(path)
      }
    }

    /// The recorded local file of a photo or video, without touching disk.
    func recordedURL(for media: MediaMessage) -> URL? {
      if let photo = media.photo {
        return url(.photos, path: photo.localPhotoSizeCandidates().first?.localPath)
      }
      if let video = media.video {
        return url(.videos, path: video.video.localPath)
      }
      return nil
    }

    func recordedURL(for document: DocumentInfo) -> URL? {
      url(.documents, path: document.document.localPath)
    }
  }

  static func localURL(_ directory: FileLocalCacheDirectory, path: String?) -> URL? {
    Directories().url(directory, path: path)
  }

  static func recordedURL(for media: MediaMessage) -> URL? {
    Directories().recordedURL(for: media)
  }

  static func recordedURL(for document: DocumentInfo) -> URL? {
    localURL(.documents, path: document.document.localPath)
  }

  static func fileExists(_ url: URL?) async -> Bool {
    guard let url else { return false }
    return await Task.detached(priority: .userInitiated) {
      var isDirectory = ObjCBool(false)
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }.value
  }

  /// An existing local photo file, downloading it when there is none.
  static func ensurePhoto(_ photo: PhotoInfo, message: Message) async -> URL? {
    let existing = await Task.detached(priority: .userInitiated) {
      FileCache.cachedLocalURLCandidates(photo: photo).first
    }.value
    if let existing { return existing }
    return await FileCache.shared.downloadAndWait(photo: photo, reloadMessageOnFinish: message)
  }

  static func ensureVideo(
    _ video: VideoInfo,
    message: Message,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> URL {
    let recorded = localURL(.videos, path: video.video.localPath)
    if await fileExists(recorded), let recorded { return recorded }

    progress(0)
    let subscription = FileDownloader.shared.videoProgressPublisher(videoId: video.id)
      .receive(on: DispatchQueue.main)
      .sink { value in
        guard value.error == nil, value.totalBytes > 0 else { return }
        MainActor.assumeIsolated { progress(value.progress) }
      }
    defer { subscription.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      FileDownloader.shared.downloadVideo(video: video, for: message, priority: .userInitiated) {
        continuation.resume(with: $0)
      }
    }
  }

  static func ensureDocument(_ document: DocumentInfo, message: Message) async throws -> URL {
    let recorded = recordedURL(for: document)
    if await fileExists(recorded), let recorded { return recorded }
    return try await withCheckedThrowingContinuation { continuation in
      FileDownloader.shared.downloadDocument(document: document, for: message, priority: .userInitiated) {
        continuation.resume(with: $0)
      }
    }
  }

  static func open(_ url: URL) {
    if !NSWorkspace.shared.open(url) {
      ToastCenter.shared.showError("Couldn’t open this file")
    }
  }

  /// Copies the file into Downloads (reusing an identical earlier copy) and selects it in
  /// Finder, rather than exposing the app's cache folder.
  static func revealInDownloads(_ source: URL, fileName: String) {
    Task { @MainActor in
      let result = await Task.detached(priority: .userInitiated) {
        Result { try copyToDownloads(source, fileName: fileName) }
      }.value
      switch result {
        case let .success(destination):
          NSWorkspace.shared.activateFileViewerSelecting([destination])
        case let .failure(error):
          Log.shared.error("Failed to copy file to Downloads", error: error)
          ToastCenter.shared.showError("Couldn’t save to Downloads")
      }
    }
  }

  static func saveAs(_ source: URL, suggestedName: String, window: NSWindow?) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let destination = panel.url else { return }
      Task { @MainActor in
        let result = await Task.detached(priority: .userInitiated) {
          Result {
            if FileManager.default.fileExists(atPath: destination.path) {
              try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
          }
        }.value
        switch result {
          case .success:
            NSWorkspace.shared.activateFileViewerSelecting([destination])
          case let .failure(error):
            Log.shared.error("Failed to save file", error: error)
            ToastCenter.shared.showError("Couldn’t save this file")
        }
      }
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  /// Puts the file on the pasteboard, so Finder and other apps paste the file itself.
  static func copyFile(_ url: URL) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([url as NSURL])
  }

  /// Puts the image data and its file on one pasteboard item, encoding off the main thread.
  static func copyImage(_ url: URL) {
    Task { @MainActor in
      let encoded = await Task.detached(priority: .userInitiated) { () -> (Data, String, Data?)? in
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .image
        let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation
        return (data, type.identifier, tiff)
      }.value
      guard let (data, typeIdentifier, tiff) = encoded else {
        ToastCenter.shared.showError("Couldn’t copy this image")
        return
      }
      let item = NSPasteboardItem()
      item.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
      if let tiff { item.setData(tiff, forType: .tiff) }
      item.setString(url.absoluteString, forType: .fileURL)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.writeObjects([item])
      ToastCenter.shared.showSuccess("Copied image")
    }
  }

  private nonisolated static func copyToDownloads(_ source: URL, fileName: String) throws -> URL {
    guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
      throw CocoaError(.fileNoSuchFile)
    }
    let base = URL(fileURLWithPath: fileName).lastPathComponent
    let safeName = base.isEmpty || base == "." || base == ".." ? "File" : base
    let sourceSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? UInt64) ?? nil
    let file = URL(fileURLWithPath: safeName)
    let suffix = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension)"
    let stem = file.deletingPathExtension().lastPathComponent

    for index in 0 ..< 1_000 {
      let candidate = index == 0 ? safeName : "\(stem) (\(index))\(suffix)"
      let destination = downloads.appendingPathComponent(candidate)
      if FileManager.default.fileExists(atPath: destination.path) {
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? UInt64) ?? nil
        if let sourceSize, size == sourceSize,
           FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path)
        {
          return destination
        }
        continue
      }
      try FileManager.default.copyItem(at: source, to: destination)
      return destination
    }
    throw CocoaError(.fileWriteFileExists)
  }
}

// MARK: - Quick Look

/// One Quick Look panel for a resource tab, with every local item so the arrow keys move
/// through the tab like a gallery.
@MainActor
final class ChatInfoResourcePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = ChatInfoResourcePreview()

  final class Item: NSObject, QLPreviewItem {
    let id: Int64
    let url: URL
    let title: String

    init(id: Int64, url: URL, title: String) {
      self.id = id
      self.url = url
      self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
  }

  /// Supplies the on-screen view of an item, for the zoom transition.
  typealias SourceView = @MainActor (Int64) -> NSView?

  private var items: [Item] = []
  private var sourceView: SourceView?

  var isPresenting: Bool {
    guard let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil else { return false }
    return panel.isVisible && panel.dataSource === self
  }

  /// Opens `items` at `selectedID`. Clicking the item already on screen closes the panel,
  /// as the message views do.
  func present(_ items: [Item], selecting selectedID: Int64, sourceView: SourceView? = nil) {
    guard let panel = QLPreviewPanel.shared(), !items.isEmpty else { return }
    if isPresenting, (panel.currentPreviewItem as? Item)?.id == selectedID {
      panel.orderOut(nil)
      return
    }
    self.items = items
    self.sourceView = sourceView
    panel.updateController()
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.currentPreviewItemIndex = items.firstIndex { $0.id == selectedID } ?? 0
    if panel.isVisible {
      panel.orderFront(nil)
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    MainActor.assumeIsolated { items.count }
  }

  nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    MainActor.assumeIsolated { items.indices.contains(index) ? items[index] : nil }
  }

  nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
    MainActor.assumeIsolated {
      guard let item = item as? Item, let view = sourceView?(item.id), let window = view.window else { return .zero }
      return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
  }

  nonisolated func previewPanel(
    _ panel: QLPreviewPanel!,
    transitionImageFor item: (any QLPreviewItem)!,
    contentRect: UnsafeMutablePointer<NSRect>!
  ) -> Any! {
    MainActor.assumeIsolated {
      guard let item = item as? Item,
            let view = sourceView?(item.id) as? ChatInfoThumbnailLayerView,
            let image = view.displayedImage
      else { return nil }
      return NSImage(cgImage: image, size: view.bounds.size)
    }
  }

  nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    guard event.type == .keyDown, event.keyCode == 53 || event.keyCode == 49 else { return false }
    MainActor.assumeIsolated { panel.orderOut(nil) }
    return true
  }
}

// MARK: - Menus

/// A closure-backed menu item target for AppKit context menus.
final class ChatInfoMenuAction: NSObject {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  @objc func perform(_: Any?) {
    handler()
  }

  static func item(_ title: String, symbol: String, handler: @escaping () -> Void) -> NSMenuItem {
    let action = ChatInfoMenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(perform(_:)), keyEquivalent: "")
    item.target = action
    item.representedObject = action
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
  }
}

// MARK: - Shared row chrome

/// A month title above a tab's rows.
struct ChatInfoResourceSectionHeader: View {
  let title: String
  var isFirst = false

  var body: some View {
    Text(title)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, isFirst ? 4 : 16)
      .padding(.bottom, 6)
      .accessibilityAddTraits(.isHeader)
  }
}

/// Hover highlight that bleeds past the row's content edge, like a source list, so row text
/// stays aligned with the column.
struct ChatInfoResourceRowChrome: ViewModifier {
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
          .padding(.horizontal, -8)
      }
      .onHover { isHovered = $0 }
  }
}

extension View {
  func chatInfoResourceRow() -> some View {
    modifier(ChatInfoResourceRowChrome())
  }
}
