import Combine
import Foundation
import InlineKit
import Logger
import InlineUI
import UIKit

/// One page in the media gallery.
struct MediaGalleryItem: Hashable {
  enum Kind: Hashable {
    case photo
    case video
  }

  /// Unique within one gallery. Chat items use the message id, which also orders them.
  let id: Int64
  let kind: Kind
  /// The full-resolution photo, or the playable video.
  let mediaURL: URL?
  /// Tried when `mediaURL` is a local file that's missing.
  let fallbackURL: URL?
  /// A small image for the thumbnail strip and the page placeholder (a video's poster frame).
  let thumbnailURL: URL?
  /// Pixel size, used to lay out the page before the image arrives.
  let pixelSize: CGSize?
  let strippedThumbnail: Data?
  let duration: Int?
  let message: Message?

  static func photo(url: URL, id: Int64 = 0) -> MediaGalleryItem {
    MediaGalleryItem(
      id: id, kind: .photo, mediaURL: url, fallbackURL: nil, thumbnailURL: nil, pixelSize: nil,
      strippedThumbnail: nil, duration: nil, message: nil
    )
  }

  static func video(url: URL, id: Int64 = 0) -> MediaGalleryItem {
    MediaGalleryItem(
      id: id, kind: .video, mediaURL: url, fallbackURL: nil, thumbnailURL: nil, pixelSize: nil,
      strippedThumbnail: nil, duration: nil, message: nil
    )
  }

  init(
    id: Int64,
    kind: Kind,
    mediaURL: URL?,
    fallbackURL: URL?,
    thumbnailURL: URL?,
    pixelSize: CGSize?,
    strippedThumbnail: Data?,
    duration: Int?,
    message: Message?
  ) {
    self.id = id
    self.kind = kind
    self.mediaURL = mediaURL
    self.fallbackURL = fallbackURL
    self.thumbnailURL = thumbnailURL
    self.pixelSize = pixelSize
    self.strippedThumbnail = strippedThumbnail
    self.duration = duration
    self.message = message
  }

  /// A chat message's photo or video, or nil for stickers and other media.
  init?(message: Message, photo: PhotoInfo?, video: VideoInfo?) {
    guard message.isSticker != true else { return nil }

    if let photo {
      let best = photo.bestPhotoSize()
      let urls = MediaGalleryURLs.photo(photo)
      guard urls.primary != nil else { return nil }
      self.init(
        id: message.messageId,
        kind: .photo,
        mediaURL: urls.primary,
        fallbackURL: urls.fallback,
        thumbnailURL: MediaGalleryURLs.smallPhoto(photo),
        pixelSize: MediaGalleryURLs.size(width: best?.width, height: best?.height),
        strippedThumbnail: InlineTinyThumbnailDecoder.strippedBytes(from: photo),
        duration: nil,
        message: message
      )
      return
    }

    if let video {
      let urls = MediaGalleryURLs.video(video)
      guard urls.primary != nil else { return nil }
      self.init(
        id: message.messageId,
        kind: .video,
        mediaURL: urls.primary,
        fallbackURL: urls.fallback,
        thumbnailURL: video.thumbnail.flatMap { MediaGalleryURLs.photo($0).primary },
        pixelSize: MediaGalleryURLs.size(width: video.video.width, height: video.video.height),
        strippedThumbnail: InlineTinyThumbnailDecoder.strippedBytes(from: video.thumbnail),
        duration: video.video.duration,
        message: message
      )
      return
    }

    return nil
  }

  /// The id the chat list uses for this message's cell.
  var messageStableId: Int64? {
    guard let message else { return nil }
    return message.globalId ?? message.messageId
  }

  /// True when the page would load from an expired remote link.
  /// A local file comes first, so only a remote primary link counts.
  var hasExpiredRemoteURL: Bool {
    guard let mediaURL, !mediaURL.isFileURL else { return false }
    return MediaGalleryURLs.isExpired(mediaURL) || MediaGalleryURLs.isExpired(thumbnailURL)
  }

  var strippedImage: UIImage? {
    guard let strippedThumbnail,
          let data = InlineTinyThumbnailDecoder.decodeJPEGData(from: strippedThumbnail)
    else { return nil }
    return UIImage(data: data)
  }
}

enum MediaGalleryURLs {
  /// A local file first (no disk check, so this stays cheap), with the CDN as fallback.
  static func photo(_ info: PhotoInfo) -> (primary: URL?, fallback: URL?) {
    let best = info.bestPhotoSize()
    let cdn = best?.cdnUrl.flatMap(URL.init(string:))
    if let localPath = info.localPhotoSizeCandidates().first?.localPath {
      return (FileCache.getUrl(for: .photos, localPath: localPath), cdn)
    }
    return (cdn, nil)
  }

  static func video(_ info: VideoInfo) -> (primary: URL?, fallback: URL?) {
    let cdn = info.video.cdnUrl.flatMap(URL.init(string:))
    if let localPath = info.video.localPath, !localPath.isEmpty {
      return (FileCache.getUrl(for: .videos, localPath: localPath), cdn)
    }
    return (cdn, nil)
  }

  /// The smallest regular size with a source, for strip thumbnails.
  static func smallPhoto(_ info: PhotoInfo) -> URL? {
    let candidates = info.sizes.filter { $0.type != "s" && ($0.localPath != nil || $0.cdnUrl != nil) }
    let smallest = candidates.min { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }
    if let localPath = smallest?.localPath, !localPath.isEmpty {
      return FileCache.getUrl(for: .photos, localPath: localPath)
    }
    return smallest?.cdnUrl.flatMap(URL.init(string:)) ?? photo(info).primary
  }

  static func size(width: Int?, height: Int?) -> CGSize? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    return CGSize(width: width, height: height)
  }

  private static let amzDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()

  /// Media links are signed and expire after a week. Reads the expiry from either
  /// format the server signs: the media proxy's `exp`, or R2's `X-Amz-Date` plus `X-Amz-Expires`.
  static func isExpired(_ url: URL?, margin: TimeInterval = 5 * 60) -> Bool {
    guard let url, !url.isFileURL,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return false }
    func value(_ name: String) -> String? {
      items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    let deadline = Date().addingTimeInterval(margin)
    if let exp = value("exp").flatMap(TimeInterval.init) {
      return Date(timeIntervalSince1970: exp) < deadline
    }
    if let signed = value("X-Amz-Date").flatMap(amzDateFormatter.date(from:)),
       let lifetime = value("X-Amz-Expires").flatMap(TimeInterval.init)
    {
      return signed.addingTimeInterval(lifetime) < deadline
    }
    return false
  }
}

/// Feeds the gallery its pages, oldest first.
@MainActor
protocol MediaGallerySource: AnyObject {
  var items: [MediaGalleryItem] { get }
  /// True when no older pages remain to load.
  var isComplete: Bool { get }
  var onChange: (() -> Void)? { get set }
  func start()
  func stop()
  /// Called as the visible page changes, so older pages load before the user reaches them.
  func pageDidChange(to index: Int)
  /// Drops a page, for example after its message is deleted.
  func remove(id: Int64)
  /// Asks the server for fresh media links after a page fails to load.
  /// Returns true while a refresh for `id` is pending; false once one has been tried.
  func refreshLinks(id: Int64) -> Bool
  /// Called with the ids whose refresh finished, so waiting pages can try again.
  var onLinksRefreshed: ((Set<Int64>) -> Void)? { get set }
}

/// A fixed list, for single photos and attachments.
@MainActor
final class StaticMediaGallerySource: MediaGallerySource {
  private(set) var items: [MediaGalleryItem]
  let isComplete = true
  var onChange: (() -> Void)?

  init(items: [MediaGalleryItem]) {
    self.items = items
  }

  func start() {}
  func stop() {}
  func pageDidChange(to index: Int) {}

  func remove(id: Int64) {
    items.removeAll { $0.id == id }
    onChange?()
  }

  var onLinksRefreshed: ((Set<Int64>) -> Void)?

  func refreshLinks(id: Int64) -> Bool {
    false
  }
}

/// Every photo and video in a chat, paged from the local cache and the server.
///
/// The tapped message is shown at once. Newer media arrives first because the window
/// starts at the latest page; older pages load until the tapped message is reached and
/// again whenever the user nears the oldest loaded page.
@MainActor
final class ChatMediaGallerySource: MediaGallerySource {
  private let viewModel: ChatMediaViewModel
  private let peer: Peer
  private let anchor: MediaGalleryItem
  private var refreshingIds = Set<Int64>()
  private var refreshedIds = Set<Int64>()
  private var cancellables = Set<AnyCancellable>()
  private var removedIds = Set<Int64>()
  private var anchorLoaded = false
  private var isLoadingMore = false
  private var currentIndex = 0

  private(set) var items: [MediaGalleryItem]
  var onChange: (() -> Void)?
  var onLinksRefreshed: ((Set<Int64>) -> Void)?

  /// How close to the oldest loaded page the user gets before the next page loads.
  private let prefetchDistance = 10

  init(chatId: Int64, peer: Peer, anchor: MediaGalleryItem, db: AppDatabase = .shared) {
    viewModel = ChatMediaViewModel(db: db, chatId: chatId, peer: peer, excludeStickerMedia: true)
    self.peer = peer
    self.anchor = anchor
    items = [anchor]
  }

  var isComplete: Bool {
    anchorLoaded && !viewModel.hasMore
  }

  func start() {
    viewModel.$rows
      .sink { [weak self] rows in self?.rebuild(rows) }
      .store(in: &cancellables)
    viewModel.$loadState
      .removeDuplicates()
      .sink { [weak self] _ in
        // `@Published` emits before the value changes; read state on the next turn.
        // The gallery re-reads `isComplete` for its counter.
        DispatchQueue.main.async {
          self?.onChange?()
          self?.loadMoreIfNeeded()
        }
      }
      .store(in: &cancellables)
    Task { await viewModel.loadInitial() }
  }

  func stop() {
    cancellables.removeAll()
    viewModel.deactivate()
  }

  func pageDidChange(to index: Int) {
    currentIndex = index
    loadMoreIfNeeded()
    refreshExpiredLinks(around: index)
  }

  func refreshLinks(id: Int64) -> Bool {
    if refreshingIds.contains(id) { return true }
    guard items.contains(where: { $0.id == id && $0.message != nil }) else { return false }
    return requestRefresh([id])
  }

  /// Refreshes expired links near the current page before the user reaches them.
  private func refreshExpiredLinks(around index: Int) {
    guard !items.isEmpty else { return }
    let lower = max(0, index - 4)
    let upper = min(items.count - 1, index + 4)
    guard lower <= upper else { return }
    let ids = items[lower ... upper].filter { $0.message != nil && $0.hasExpiredRemoteURL }.map(\.id)
    requestRefresh(ids)
  }

  /// Re-fetches messages so the database, and then this gallery, get freshly signed links.
  /// Each message is refreshed at most once per gallery.
  @discardableResult
  private func requestRefresh(_ ids: [Int64]) -> Bool {
    let pending = Array(ids.filter { $0 > 0 && !refreshingIds.contains($0) && !refreshedIds.contains($0) }.prefix(100))
    guard !pending.isEmpty else { return false }
    refreshingIds.formUnion(pending)
    let peer = peer
    Task { [weak self] in
      do {
        _ = try await Api.realtime.send(.getMessages(peer: peer, messageIds: pending))
      } catch {
        Log.shared.warning("Gallery failed to refresh media links: \(error.localizedDescription)")
      }
      guard let self else { return }
      let done = Set(pending)
      refreshingIds.subtract(done)
      refreshedIds.formUnion(done)
      // The database observation delivers the new rows on its next main-queue turn.
      try? await Task.sleep(for: .milliseconds(300))
      onLinksRefreshed?(done)
    }
    return true
  }

  func remove(id: Int64) {
    removedIds.insert(id)
    rebuild(viewModel.rows)
  }

  private func rebuild(_ rows: [MediaMessage]) {
    var byId: [Int64: MediaGalleryItem] = [:]
    for row in rows {
      guard let item = MediaGalleryItem(message: row.message, photo: row.photo, video: row.video) else { continue }
      byId[item.id] = item
    }
    anchorLoaded = byId[anchor.id] != nil || rows.contains { $0.message.messageId < anchor.id }
    if byId[anchor.id] == nil {
      byId[anchor.id] = anchor
    }
    for id in removedIds {
      byId[id] = nil
    }

    let next = byId.values.sorted { $0.id < $1.id }
    let changed = next != items
    items = next
    if changed {
      onChange?()
    }
    DispatchQueue.main.async { [weak self] in self?.loadMoreIfNeeded() }
  }

  private func loadMoreIfNeeded() {
    guard !isLoadingMore, viewModel.hasMore, viewModel.loadState != .failed, viewModel.loadState != .loading
    else { return }
    let nearOldest = currentIndex < prefetchDistance
    guard !anchorLoaded || nearOldest else { return }

    isLoadingMore = true
    Task { [weak self] in
      await self?.viewModel.loadMore()
      self?.isLoadingMore = false
      self?.loadMoreIfNeeded()
    }
  }
}
