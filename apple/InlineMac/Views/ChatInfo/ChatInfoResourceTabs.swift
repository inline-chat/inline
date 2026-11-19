import AppKit
import Combine
import InlineKit
import InlineUI
import Logger
import SwiftUI
import UniformTypeIdentifiers

// Media, files, voice and links tabs of chat info, and the states that own their view models.
//
// Each list is one lazy stack placed as a section's content under the pinned tab bar; it
// never owns the scroll view. Rows group by month, render from the view model's rows on the
// first frame, and request the next page a few rows before the end.

@MainActor
final class ChatInfoMediaState: ObservableObject {
  @Published private(set) var mediaViewModel: ChatMediaViewModel?
  private let db: AppDatabase
  private let peer: Peer
  private var currentChatId: Int64 = 0

  init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0, chatId != currentChatId else { return }
    currentChatId = chatId
    mediaViewModel?.deactivate()
    mediaViewModel = ChatMediaViewModel(db: db, chatId: chatId, peer: peer, excludeStickerMedia: true)
  }
}

@MainActor
final class ChatInfoDocumentsState: ObservableObject {
  @Published private(set) var documentsViewModel: ChatDocumentsViewModel?

  private let db: AppDatabase
  private let peer: Peer
  private var currentChatId: Int64 = 0

  init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0 else { return }
    guard chatId != currentChatId else { return }
    currentChatId = chatId
    documentsViewModel?.deactivate()
    documentsViewModel = ChatDocumentsViewModel(db: db, chatId: chatId, peer: peer)
  }
}

@MainActor
final class ChatInfoLinksState: ObservableObject {
  @Published private(set) var linksViewModel: ChatLinksViewModel?

  private let db: AppDatabase
  private let peer: Peer
  private var currentChatId: Int64 = 0

  init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0 else { return }
    guard chatId != currentChatId else { return }
    currentChatId = chatId
    linksViewModel?.deactivate()
    linksViewModel = ChatLinksViewModel(db: db, chatId: chatId, peer: peer)
  }
}

@MainActor
final class ChatInfoVoiceMemosState: ObservableObject {
  @Published private(set) var voiceMemosViewModel: ChatVoiceMemosViewModel?

  private let db: AppDatabase
  private let peer: Peer
  private var currentChatId: Int64 = 0

  init(db: AppDatabase, peer: Peer) {
    self.db = db
    self.peer = peer
  }

  func updateChatId(_ chatId: Int64) {
    guard chatId > 0 else { return }
    guard chatId != currentChatId else { return }
    currentChatId = chatId
    voiceMemosViewModel?.deactivate()
    voiceMemosViewModel = ChatVoiceMemosViewModel(db: db, chatId: chatId, peer: peer)
  }
}

// MARK: - Media

/// Photos and videos in month blocks of square thumbnails, 4 across in the 640pt column.
///
/// Rows are lazy: only rows near the viewport exist, each a fixed-height row of layer-backed
/// cells. The next page is requested a few rows before the end, not per cell.
struct ChatInfoMediaList: View {
  @ObservedObject var mediaViewModel: ChatMediaViewModel
  let onShowInChat: (Message) -> Void

  @State private var width = ChatInfoMediaGridMetrics.defaultWidth
  @State private var controller = ChatInfoMediaGridController()

  var body: some View {
    let media = mediaViewModel.mediaMessages
    let columns = ChatInfoMediaGridMetrics.columns(for: width)
    let side = ChatInfoMediaGridMetrics.side(for: width, columns: columns)
    let blocks = ChatInfoMediaBlocks(media: media, columns: columns)
    let _ = controller.update(mediaMessages: media, onShowInChat: onShowInChat)

    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(blocks.sections) { block in
        ChatInfoResourceSectionHeader(
          title: ChatInfoResourceFormat.monthTitle(block.section.monthStart),
          isFirst: block.id == blocks.sections.first?.id
        )
        ForEach(0 ..< block.rowCount, id: \.self) { row in
          ChatInfoMediaGridRow(
            models: block.models(row: row, columns: columns),
            columns: columns,
            side: side,
            controller: controller
          )
          .padding(.bottom, row == block.rowCount - 1 ? 0 : ChatInfoMediaGridMetrics.spacing)
          .onAppear {
            if block.firstRow + row >= blocks.rowCount - ChatInfoMediaGridMetrics.prefetchRows {
              prefetch()
            }
          }
        }
      }
      ChatInfoResourceFooter(
        state: mediaViewModel.loadState,
        isEmpty: media.isEmpty,
        emptyMessage: String(localized: "No photos or videos yet"),
        systemImage: "photo.on.rectangle",
        itemCount: media.count,
        loadMore: mediaViewModel.loadMore,
        retry: mediaViewModel.retry
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width.rounded()
    } action: { newWidth in
      if newWidth > 0 { width = newWidth }
    }
    .task(id: ObjectIdentifier(mediaViewModel)) { await mediaViewModel.loadInitial() }
    .onDisappear { mediaViewModel.deactivate() }
  }

  private func prefetch() {
    guard mediaViewModel.loadState == .idle, mediaViewModel.hasMore else { return }
    // Unstructured, so a row leaving the screen doesn't cancel the page.
    Task { await mediaViewModel.loadMore() }
  }
}

/// Month sections cut into grid rows, with each section's first global row index.
private struct ChatInfoMediaBlocks {
  struct Block: Identifiable {
    let section: ChatInfoResourceSection<MediaMessage>
    let firstRow: Int
    let rowCount: Int
    var id: Int { section.id }

    func models(row: Int, columns: Int) -> [ChatInfoMediaCellModel] {
      let items = section.items
      let start = row * columns
      let end = min(start + columns, items.count)
      guard start < end else { return [] }
      return (start ..< end).map { index in
        ChatInfoMediaCellModel(
          media: items[index],
          corners: .forItem(index, count: items.count, columns: columns)
        )
      }
    }
  }

  let sections: [Block]
  let rowCount: Int

  init(media: [MediaMessage], columns: Int) {
    var blocks: [Block] = []
    var rows = 0
    for section in ChatInfoResourceSections.byMonth(media, date: { $0.message.date }) {
      let count = (section.items.count + columns - 1) / columns
      blocks.append(Block(section: section, firstRow: rows, rowCount: count))
      rows += count
    }
    sections = blocks
    rowCount = rows
  }
}

// MARK: - Files

/// Files as compact rows: icon or thumbnail, name, and "size · date".
struct ChatInfoFilesList: View {
  @ObservedObject var documentsViewModel: ChatDocumentsViewModel
  let onShowInChat: (Message) -> Void

  @State private var controller = ChatInfoFilesController()

  var body: some View {
    let documents = documentsViewModel.documentMessages
    let sections = ChatInfoResourceSections.byMonth(documents) { $0.message.date }
    let prefetchID = chatInfoPrefetchID(documents.map(\.id))
    let _ = controller.update(documents: documents, onShowInChat: onShowInChat)

    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(sections) { section in
        ChatInfoResourceSectionHeader(
          title: ChatInfoResourceFormat.monthTitle(section.monthStart),
          isFirst: section.id == sections.first?.id
        )
        ForEach(section.items) { item in
          ChatInfoFileRow(item: item, controller: controller)
            .onAppear {
              if item.id == prefetchID { prefetch() }
            }
        }
      }
      ChatInfoResourceFooter(
        state: documentsViewModel.loadState,
        isEmpty: documents.isEmpty,
        emptyMessage: String(localized: "No files yet"),
        systemImage: "doc",
        itemCount: documents.count,
        loadMore: documentsViewModel.loadMore,
        retry: documentsViewModel.retry
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: ObjectIdentifier(documentsViewModel)) { await documentsViewModel.loadInitial() }
    .onDisappear { documentsViewModel.deactivate() }
  }

  private func prefetch() {
    guard documentsViewModel.loadState == .idle, documentsViewModel.hasMore else { return }
    Task { await documentsViewModel.loadMore() }
  }
}

/// The row that requests the next page: 15 rows before the end of what's loaded.
private func chatInfoPrefetchID(_ ids: [Int64]) -> Int64? {
  let threshold = 15
  guard ids.count > threshold else { return nil }
  return ids[ids.count - threshold]
}

/// Downloads, previews and playback for one files list.
@MainActor
@Observable
final class ChatInfoFilesController {
  @ObservationIgnored private(set) var documents: [DocumentMessage] = []
  @ObservationIgnored var onShowInChat: (Message) -> Void = { _ in }
  @ObservationIgnored private var subscriptions: [Int64: AnyCancellable] = [:]

  /// Download progress by document ID.
  private(set) var transfers: [Int64: Double] = [:]
  /// Files this list downloaded whose rows don't carry the local path yet.
  private(set) var downloaded: [Int64: URL] = [:]

  func update(documents: [DocumentMessage], onShowInChat: @escaping (Message) -> Void) {
    self.documents = documents
    self.onShowInChat = onShowInChat
  }

  func localURL(_ item: DocumentMessage) -> URL? {
    ChatInfoResourceFiles.recordedURL(for: item.document) ?? downloaded[item.document.id]
  }

  func isPlayableAudio(_ item: DocumentMessage) -> Bool {
    AudioDocumentSupport.isPlayableAudio(document: item.document)
  }

  /// Picks up a download another view started, so the row shows its progress.
  func attachIfDownloading(_ item: DocumentMessage) {
    let id = item.document.id
    guard transfers[id] == nil, FileDownloader.shared.isDocumentDownloadActive(documentId: id) else { return }
    transfers[id] = FileDownloader.shared.currentDocumentProgress(documentId: id)?.progress ?? 0
    observeProgress(id)
  }

  /// A click previews a local file, plays local audio, downloads a remote one, and cancels
  /// a download in progress.
  func activate(_ item: DocumentMessage) {
    let id = item.document.id
    if transfers[id] != nil {
      cancelDownload(item)
      return
    }
    guard localURL(item) != nil else {
      download(item)
      return
    }
    Task { @MainActor in
      let url: URL
      do {
        url = try await ChatInfoResourceFiles.ensureDocument(item.document, message: item.message)
      } catch {
        download(item)
        return
      }
      if isPlayableAudio(item) {
        toggleAudio(item, url: url)
      } else {
        preview(item, url: url)
      }
    }
  }

  func quickLook(_ item: DocumentMessage) {
    Task { @MainActor in
      guard let url = try? await ChatInfoResourceFiles.ensureDocument(item.document, message: item.message) else {
        return
      }
      preview(item, url: url)
    }
  }

  func download(_ item: DocumentMessage) {
    let id = item.document.id
    guard transfers[id] == nil else { return }
    transfers[id] = 0
    observeProgress(id)
    FileDownloader.shared.downloadDocument(document: item.document, for: item.message, priority: .userInitiated) {
      [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        self.finishTransfer(id)
        switch result {
          case let .success(url):
            self.downloaded[id] = url
          case let .failure(error):
            if !FileDownloader.isCancellation(error) {
              Log.shared.error("Failed to download file from chat info", error: error)
              ToastCenter.shared.showError("Couldn’t download this file")
            }
        }
      }
    }
  }

  func cancelDownload(_ item: DocumentMessage) {
    FileDownloader.shared.cancelDocumentDownload(documentId: item.document.id)
    finishTransfer(item.document.id)
  }

  func open(_ item: DocumentMessage) {
    withLocalFile(item) { url in ChatInfoResourceFiles.open(url) }
  }

  func showInFinder(_ item: DocumentMessage) {
    withLocalFile(item) { url in
      ChatInfoResourceFiles.revealInDownloads(url, fileName: item.displayFileName)
    }
  }

  func copy(_ item: DocumentMessage) {
    withLocalFile(item) { url in ChatInfoResourceFiles.copyFile(url) }
  }

  func saveAs(_ item: DocumentMessage) {
    withLocalFile(item) { url in
      ChatInfoResourceFiles.saveAs(url, suggestedName: item.displayFileName, window: NSApp.keyWindow)
    }
  }

  // MARK: Private

  private func withLocalFile(_ item: DocumentMessage, _ body: @escaping @MainActor (URL) -> Void) {
    Task { @MainActor in
      guard let url = try? await ChatInfoResourceFiles.ensureDocument(item.document, message: item.message) else {
        ToastCenter.shared.showError("Couldn’t open this file")
        return
      }
      body(url)
    }
  }

  private func observeProgress(_ id: Int64) {
    guard subscriptions[id] == nil else { return }
    subscriptions[id] = FileDownloader.shared.documentProgressPublisher(documentId: id)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] progress in
        MainActor.assumeIsolated {
          guard let self, self.transfers[id] != nil else { return }
          if progress.error != nil || progress.isComplete {
            self.finishTransfer(id)
          } else {
            self.transfers[id] = progress.progress
          }
        }
      }
  }

  private func finishTransfer(_ id: Int64) {
    transfers[id] = nil
    subscriptions[id]?.cancel()
    subscriptions[id] = nil
  }

  private func toggleAudio(_ item: DocumentMessage, url: URL) {
    do {
      try SharedAudioPlayer.shared.toggleAudioDocumentPlayback(
        for: item.message,
        document: item.document,
        fileURLOverride: url
      )
    } catch {
      Log.shared.error("Failed to play audio file from chat info", error: error)
      ToastCenter.shared.showError("Couldn’t play this file")
    }
  }

  /// Opens Quick Look on every local file of the list, at this one.
  private func preview(_ item: DocumentMessage, url: URL) {
    let directories = ChatInfoResourceFiles.Directories()
    var items: [ChatInfoResourcePreview.Item] = []
    for row in documents {
      let rowURL = row.id == item.id
        ? url : directories.recordedURL(for: row.document) ?? downloaded[row.document.id]
      guard let rowURL else { continue }
      items.append(ChatInfoResourcePreview.Item(id: row.id, url: rowURL, title: row.displayFileName))
    }
    if !items.contains(where: { $0.id == item.id }) {
      items = [ChatInfoResourcePreview.Item(id: item.id, url: url, title: item.displayFileName)]
    }
    ChatInfoResourcePreview.shared.present(items, selecting: item.id)
  }
}

private struct ChatInfoFileRow: View {
  let item: DocumentMessage
  let controller: ChatInfoFilesController

  @State private var isOnScreen = true

  private static let iconSide: CGFloat = 40

  var body: some View {
    let documentID = item.document.id
    let progress = controller.transfers[documentID]
    let isLocal = controller.localURL(item) != nil

    HStack(spacing: 12) {
      icon(isLocal: isLocal)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.displayFileName)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(subtitle(progress: progress))
          .font(.system(size: 12))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      status(progress: progress, isLocal: isLocal)
    }
    .chatInfoResourceRow()
    .onTapGesture { controller.activate(item) }
    .contextMenu { menu(progress: progress, isLocal: isLocal) }
    .onAppear {
      isOnScreen = true
      controller.attachIfDownloading(item)
    }
    .onDisappear { isOnScreen = false }
    .help(item.displayFileName)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { controller.activate(item) }
    .accessibilityAction(named: Text("Show in Chat")) { controller.onShowInChat(item.message) }
  }

  @ViewBuilder
  private func icon(isLocal: Bool) -> some View {
    let thumbnail = item.document.thumbnail?.hasDisplayablePreview == true
      ? ChatInfoThumbnailSource(item.document.thumbnail) : nil
    ZStack {
      if let thumbnail {
        ChatInfoResourceThumbnail(
          source: thumbnail,
          side: Self.iconSide,
          message: item.message,
          isActive: isOnScreen
        )
      } else {
        Image(nsImage: ChatInfoFileTypeIcons.icon(fileName: item.document.document.fileName, mimeType: item.mimeType))
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      }
      if isLocal, controller.isPlayableAudio(item) {
        ChatInfoAudioDocumentBadge(item: item)
      }
    }
    .frame(width: Self.iconSide, height: Self.iconSide)
  }

  @ViewBuilder
  private func status(progress: Double?, isLocal: Bool) -> some View {
    if let progress {
      ProgressView(value: max(progress, 0.02))
        .progressViewStyle(.circular)
        .controlSize(.small)
        .help(String(localized: "Cancel Download"))
    } else if !isLocal {
      Image(systemName: "arrow.down.circle")
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .help(String(localized: "Download"))
    }
  }

  private func subtitle(progress: Double?) -> String {
    let size = item.document.document.size
    if let progress, let size, size > 0 {
      let received = ChatInfoResourceFormat.fileSize(Int(Double(size) * progress)) ?? "0 KB"
      let total = ChatInfoResourceFormat.fileSize(size) ?? ""
      return String(localized: "\(received) of \(total)")
    }
    let date = ChatInfoResourceFormat.rowDate(item.message.date)
    guard let formattedSize = ChatInfoResourceFormat.fileSize(size) else { return date }
    return "\(formattedSize) · \(date)"
  }

  @ViewBuilder
  private func menu(progress: Double?, isLocal: Bool) -> some View {
    if progress != nil {
      Button("Cancel Download") { controller.cancelDownload(item) }
    } else if isLocal {
      Button("Quick Look") { controller.quickLook(item) }
      Button("Open") { controller.open(item) }
      Button("Show in Finder") { controller.showInFinder(item) }
      Divider()
      Button("Copy") { controller.copy(item) }
      Button("Save As…") { controller.saveAs(item) }
      if let url = controller.localURL(item) {
        ShareLink(item: url)
      }
    } else {
      Button("Download") { controller.download(item) }
    }
    Divider()
    Button("Show in Chat") { controller.onShowInChat(item.message) }
  }
}

/// Play or pause over a local audio file's icon. Reads only the playing item and state, so
/// playback progress doesn't redraw the list.
private struct ChatInfoAudioDocumentBadge: View {
  let item: DocumentMessage

  var body: some View {
    let center = AudioPlaybackCenter.shared
    let isPlaying = center.item == AudioDocumentSupport.playbackItem(for: item.message, document: item.document)
      && (center.isPlaying || center.isStarting)
    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 22, height: 22)
      .background(Circle().fill(Color.black.opacity(0.55)))
      .accessibilityLabel(isPlaying ? String(localized: "Pause") : String(localized: "Play"))
  }
}

@MainActor
enum ChatInfoFileTypeIcons {
  private static var cache: [String: NSImage] = [:]

  /// The Finder icon for the file's type, cached per extension.
  static func icon(fileName: String?, mimeType: String?) -> NSImage {
    let pathExtension = fileName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
    let key = pathExtension.isEmpty ? "mime:\(mimeType ?? "")" : pathExtension
    if let cached = cache[key] { return cached }
    let type = UTType(filenameExtension: pathExtension)
      ?? mimeType.flatMap { UTType(mimeType: $0) }
      ?? .data
    let image = NSWorkspace.shared.icon(for: type)
    cache[key] = image
    return image
  }
}

// MARK: - Links

/// Links as compact rows: preview thumbnail or a letter tile, title, and host.
struct ChatInfoLinksList: View {
  @ObservedObject var linksViewModel: ChatLinksViewModel
  let onShowInChat: (Message) -> Void

  var body: some View {
    let links = linksViewModel.linkMessages
    let sections = ChatInfoResourceSections.byMonth(links) { $0.message.date }
    let prefetchID = chatInfoPrefetchID(links.map(\.id))

    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(sections) { section in
        ChatInfoResourceSectionHeader(
          title: ChatInfoResourceFormat.monthTitle(section.monthStart),
          isFirst: section.id == sections.first?.id
        )
        ForEach(section.items) { link in
          ChatInfoLinkRow(link: link, onShowInChat: onShowInChat)
            .onAppear {
              if link.id == prefetchID { prefetch() }
            }
        }
      }
      ChatInfoResourceFooter(
        state: linksViewModel.loadState,
        isEmpty: links.isEmpty,
        emptyMessage: String(localized: "No links yet"),
        systemImage: "link",
        itemCount: links.count,
        loadMore: linksViewModel.loadMore,
        retry: linksViewModel.retry
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: ObjectIdentifier(linksViewModel)) { await linksViewModel.loadInitial() }
    .onDisappear { linksViewModel.deactivate() }
  }

  private func prefetch() {
    guard linksViewModel.loadState == .idle, linksViewModel.hasMore else { return }
    Task { await linksViewModel.loadMore() }
  }
}

/// What a link row shows, derived once per row.
private struct ChatInfoLinkPresentation {
  private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  let url: URL?
  let title: String
  let detail: String?
  let host: String?
  let thumbnail: ChatInfoThumbnailSource?

  init(_ link: LinkMessage) {
    let preview = link.urlPreview
    let url = Self.webURL(preview?.url) ?? Self.firstURL(in: link.message.text)
    self.url = url
    host = url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }

    let previewTitle = Self.nonEmpty(preview?.title) ?? Self.nonEmpty(preview?.siteName)
    let text = Self.nonEmpty(link.message.text)
    title = previewTitle ?? host ?? text ?? String(localized: "Link")
    detail = Self.nonEmpty(preview?.description) ?? (previewTitle == nil ? nil : text.flatMap { text in
      text == url?.absoluteString ? nil : text
    })
    thumbnail = link.photoInfo?.hasDisplayablePreview == true ? ChatInfoThumbnailSource(link.photoInfo) : nil
  }

  var displayURL: String {
    guard let url else { return host ?? "" }
    let string = url.absoluteString
    for prefix in ["https://www.", "http://www.", "https://", "http://"] where string.hasPrefix(prefix) {
      return String(string.dropFirst(prefix.count))
    }
    return string
  }

  var letter: String {
    (host ?? title).first.map { String($0).uppercased() } ?? "#"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  private static func webURL(_ raw: String?) -> URL? {
    guard let raw = nonEmpty(raw) else { return nil }
    for candidate in [raw, "https://\(raw)"] {
      if let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
         url.host?.isEmpty == false
      {
        return url
      }
    }
    return nil
  }

  private static func firstURL(in text: String?) -> URL? {
    guard let text, !text.isEmpty, let detector else { return nil }
    var found: URL?
    detector.enumerateMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) { match, _, stop in
      guard let url = match?.url, let parsed = webURL(url.absoluteString) else { return }
      found = parsed
      stop.pointee = true
    }
    return found
  }
}

private struct ChatInfoLinkRow: View {
  let link: LinkMessage
  let onShowInChat: (Message) -> Void

  @Environment(\.openURL) private var openURL
  @State private var isOnScreen = true

  private static let thumbnailSide: CGFloat = 40

  var body: some View {
    let presentation = ChatInfoLinkPresentation(link)

    HStack(alignment: .center, spacing: 12) {
      thumbnail(presentation)
      VStack(alignment: .leading, spacing: 1) {
        Text(presentation.title)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        if let detail = presentation.detail {
          Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if !presentation.displayURL.isEmpty {
          Text(presentation.displayURL)
            .font(.system(size: 12))
            .foregroundStyle(.tint)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .chatInfoResourceRow()
    .onTapGesture {
      if let url = presentation.url { openURL(url) }
    }
    .contextMenu {
      if let url = presentation.url {
        Button("Open Link") { openURL(url) }
        Button("Copy Link") { Self.copy(url) }
        ShareLink(item: url)
        Divider()
      }
      Button("Show in Chat") { onShowInChat(link.message) }
    }
    .onAppear { isOnScreen = true }
    .onDisappear { isOnScreen = false }
    .help(presentation.url?.absoluteString ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isLink)
    .accessibilityAction(named: Text("Show in Chat")) { onShowInChat(link.message) }
  }

  @ViewBuilder
  private func thumbnail(_ presentation: ChatInfoLinkPresentation) -> some View {
    if let source = presentation.thumbnail {
      ChatInfoResourceThumbnail(source: source, side: Self.thumbnailSide, message: link.message, isActive: isOnScreen)
        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
    } else {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.accentColor.opacity(0.14))
        .overlay {
          Text(presentation.letter)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.tint)
        }
        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
        .accessibilityHidden(true)
    }
  }

  private static func copy(_ url: URL) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(url.absoluteString, forType: .URL)
    pasteboard.setString(url.absoluteString, forType: .string)
  }
}

// MARK: - Voice

/// Voice messages as compact rows. Only the playing row shows a live waveform; the other
/// rows read just the playing item, so playback ticks redraw one row, not the list.
struct ChatInfoVoiceMemosList: View {
  @ObservedObject var voiceMemosViewModel: ChatVoiceMemosViewModel
  let accentColor: Color
  let onShowInChat: (Message) -> Void

  @StateObject private var loading = ChatInfoVoiceLoadingMonitor()

  var body: some View {
    let memos = voiceMemosViewModel.voiceMemoMessages
    let sections = ChatInfoResourceSections.byMonth(memos) { $0.message.date }
    let prefetchID = chatInfoPrefetchID(memos.map(\.id))
    let senders = ChatInfoVoiceSenders(memos)

    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(sections) { section in
        ChatInfoResourceSectionHeader(
          title: ChatInfoResourceFormat.monthTitle(section.monthStart),
          isFirst: section.id == sections.first?.id
        )
        ForEach(section.items) { memo in
          ChatInfoVoiceRow(
            memo: memo,
            sender: senders.name(for: memo.message),
            accentColor: accentColor,
            isLoading: loading.item?.chatId == memo.message.chatId && loading.item?.messageId == memo.id,
            onShowInChat: onShowInChat
          )
          .onAppear {
            if memo.id == prefetchID { prefetch() }
          }
        }
      }
      ChatInfoResourceFooter(
        state: voiceMemosViewModel.loadState,
        isEmpty: memos.isEmpty,
        emptyMessage: String(localized: "No voice messages yet"),
        systemImage: "waveform",
        itemCount: memos.count,
        loadMore: voiceMemosViewModel.loadMore,
        retry: voiceMemosViewModel.retry
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: ObjectIdentifier(voiceMemosViewModel)) { await voiceMemosViewModel.loadInitial() }
    .onDisappear { voiceMemosViewModel.deactivate() }
  }

  private func prefetch() {
    guard voiceMemosViewModel.loadState == .idle, voiceMemosViewModel.hasMore else { return }
    Task { await voiceMemosViewModel.loadMore() }
  }
}

/// The voice message being fetched for playback, published only when it changes, not on
/// every progress tick.
@MainActor
final class ChatInfoVoiceLoadingMonitor: ObservableObject {
  @Published private(set) var item: AudioPlaybackItem?
  private var subscription: AnyCancellable?

  init() {
    subscription = SharedAudioPlayer.shared.$loadingVoice
      .map { $0?.item }
      .removeDuplicates()
      .sink { [weak self] item in self?.item = item }
  }
}

/// Sender names for voice rows, read in one batch from the object cache.
@MainActor
private struct ChatInfoVoiceSenders {
  private let names: [Int64: String]

  init(_ memos: [VoiceMemoMessage]) {
    let ids = Set(memos.lazy.filter { $0.message.out != true && $0.message.fromId > 0 }.map(\.message.fromId))
    guard !ids.isEmpty else {
      names = [:]
      return
    }
    let snapshot = ObjectCache.shared.get(ids.map { .user($0) })
    var names: [Int64: String] = [:]
    for id in ids {
      if let user = snapshot.user(id) { names[id] = user.user.displayName }
    }
    self.names = names
  }

  func name(for message: Message) -> String {
    if message.out == true { return String(localized: "You") }
    return names[message.fromId] ?? String(localized: "Voice message")
  }
}

private struct ChatInfoVoiceRow: View {
  let memo: VoiceMemoMessage
  let sender: String
  let accentColor: Color
  let isLoading: Bool
  let onShowInChat: (Message) -> Void

  var body: some View {
    let center = AudioPlaybackCenter.shared
    let isCurrent = isCurrentItem(center.item)
    let isPlaying = isCurrent && (center.isPlaying || center.isStarting)

    HStack(spacing: 12) {
      playButton(isPlaying: isPlaying)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(sender)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(ChatInfoResourceFormat.rowDate(memo.message.date))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if isCurrent {
          ChatInfoVoiceProgress(memo: memo, accentColor: accentColor)
        } else {
          Text(ChatInfoResourceFormat.duration(Int(memo.voice.duration)))
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
    }
    .chatInfoResourceRow()
    .contextMenu {
      Button(isPlaying ? "Pause" : "Play") { togglePlayback() }
      Divider()
      Button("Show in Chat") { onShowInChat(memo.message) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { togglePlayback() }
    .accessibilityAction(named: Text("Show in Chat")) { onShowInChat(memo.message) }
  }

  private var accessibilityLabel: String {
    let duration = ChatInfoResourceFormat.duration(Int(memo.voice.duration))
    let date = ChatInfoResourceFormat.rowDate(memo.message.date)
    return String(localized: "Voice message from \(sender), \(duration), \(date)")
  }

  private func isCurrentItem(_ item: AudioPlaybackItem?) -> Bool {
    guard let item else { return false }
    return item.kind == .voice && item.chatId == memo.message.chatId && item.messageId == memo.message.messageId
      && item.mediaId == memo.voice.voiceID
  }

  private func playButton(isPlaying: Bool) -> some View {
    Button(action: togglePlayback) {
      ZStack {
        Circle()
          .fill(accentColor.opacity(0.14))
        if isLoading {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accentColor)
            .contentTransition(.symbolEffect(.replace))
        }
      }
      .frame(width: 34, height: 34)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(isLoading ? String(localized: "Cancel") : isPlaying ? String(localized: "Pause") : String(localized: "Play"))
  }

  private func togglePlayback() {
    if isLoading {
      SharedAudioPlayer.shared.cancelVoiceSelection(mediaID: memo.voice.voiceID)
      return
    }
    // Plays a local file, or downloads then plays; on the playing memo it pauses or resumes.
    SharedAudioPlayer.shared.requestVoicePlayback(for: memo.message)
  }
}

/// The playing memo's waveform and time, the only part of the list that follows playback.
private struct ChatInfoVoiceProgress: View {
  let memo: VoiceMemoMessage
  let accentColor: Color

  var body: some View {
    let center = AudioPlaybackCenter.shared
    let duration = center.duration > 0 ? center.duration : TimeInterval(memo.voice.duration)
    let progress = duration > 0 ? min(max(center.currentTime / duration, 0), 1) : 0
    let message = memo.message

    HStack(spacing: 8) {
      AudioWaveformView(
        waveform: memo.voice.waveform,
        progress: progress,
        foreground: accentColor,
        background: Color.secondary.opacity(0.35),
        targetBarCount: 56,
        barWidth: 2,
        barSpacing: 2,
        minBarHeight: 2,
        onSeek: { value in SharedAudioPlayer.shared.seekVoice(to: value, for: message) }
      )
      .frame(maxWidth: 260)
      .frame(height: 14)
      Text(
        "\(ChatInfoResourceFormat.duration(Int(center.currentTime.rounded()))) / \(ChatInfoResourceFormat.duration(Int(duration.rounded())))"
      )
      .font(.system(size: 12))
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .fixedSize()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#if DEBUG
#Preview("Media grid corners") {
  let columns = 4
  VStack(alignment: .leading, spacing: 2) {
    ForEach(0 ..< 2, id: \.self) { row in
      HStack(spacing: 2) {
        ForEach(0 ..< (row == 0 ? 4 : 2), id: \.self) { column in
          let corners = ChatInfoGridCorners.forItem(row * columns + column, count: 6, columns: columns)
          UnevenRoundedRectangle(
            topLeadingRadius: corners.contains(.topLeading) ? 10 : 0,
            bottomLeadingRadius: corners.contains(.bottomLeading) ? 10 : 0,
            bottomTrailingRadius: corners.contains(.bottomTrailing) ? 10 : 0,
            topTrailingRadius: corners.contains(.topTrailing) ? 10 : 0
          )
          .fill(.quaternary)
          .frame(width: 80, height: 80)
        }
      }
    }
  }
  .padding()
}
#endif
