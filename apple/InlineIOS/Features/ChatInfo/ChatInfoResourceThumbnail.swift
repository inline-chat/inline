import InlineCompatUI
import InlineKit
import InlineUI
import Nuke
import SwiftUI
import UIKit

// One UIKit view per thumbnail: a neutral fill, the stripped blur while loading, the
// image decoded at the cell's pixel size, and an optional duration badge. It replaces a
// SwiftUI ZStack of a fill, a `LazyImageView` with a spinning activity indicator per cell,
// a gradient overlay and two rounded clips, all of which were rebuilt on every cell appear.

/// What a thumbnail shows. Equatable so SwiftUI can skip cells whose content didn't change.
struct ChatInfoResourceThumbnailContent: Equatable {
  var url: URL?
  /// Tried when a cached file has gone missing.
  var fallbackURL: URL?
  var strippedBytes: Data?
  /// A video's duration, drawn bottom-trailing.
  var badgeText: String?
  var accessibilityLabel: String?

  static let empty = ChatInfoResourceThumbnailContent()
}

extension ChatInfoResourceThumbnailContent {
  /// The best stored size of a photo: its file when it's on disk, else the CDN.
  init(photo: PhotoInfo?, badgeText: String? = nil, accessibilityLabel: String? = nil) {
    let size = photo?.bestPhotoSize()
    let local = size?.localPath.flatMap { $0.isEmpty ? nil : ChatInfoResourceFiles.photoURL(localPath: $0) }
    let remote = size?.cdnUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    self.init(
      url: local ?? remote,
      fallbackURL: local == nil ? nil : remote,
      strippedBytes: InlineTinyThumbnailDecoder.strippedBytes(from: photo),
      badgeText: badgeText,
      accessibilityLabel: accessibilityLabel
    )
  }
}

/// Cache folders resolved once; `FileCache.getUrl` checks the folder on disk on every call.
enum ChatInfoResourceFiles {
  private static let photos = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
  static let documents = FileHelpers.getLocalCacheDirectory(for: .documents, createIfNeeded: false)

  static func photoURL(localPath: String) -> URL {
    photos.appendingPathComponent(localPath)
  }
}

enum ChatInfoResourceImageRequest {
  /// Decodes with ImageIO straight to the target size (aspect fill, uncropped) rather
  /// than decoding the full photo and scaling it on every render.
  static func make(url: URL, pixelSize: CGSize, priority: ImageRequest.Priority) -> ImageRequest {
    ImageRequest(
      url: url,
      priority: priority,
      userInfo: [.thumbnailKey: ImageRequest.ThumbnailOptions(size: pixelSize, unit: .pixels, contentMode: .aspectFill)]
    )
  }

  /// Rounds up to a 32 px step so near-equal cell sizes share one cache entry.
  static func pixelSize(for size: CGSize, scale: CGFloat) -> CGSize {
    func bucket(_ value: CGFloat) -> CGFloat { max(32, (value * scale / 32).rounded(.up) * 32) }
    return CGSize(width: bucket(size.width), height: bucket(size.height))
  }
}

@MainActor
final class ChatInfoResourceThumbnailView: UIView {
  var onTap: ((ChatInfoResourceThumbnailView) -> Void)?
  /// Reports the pixel size requests use, so prefetching asks for the same cache entry.
  var onPixelSize: ((CGSize) -> Void)?

  let imageView = UIImageView()
  private let placeholderView = InlineTinyThumbnailBackgroundView()
  private var badge: ChatInfoResourceThumbnailBadge?
  private var content = ChatInfoResourceThumbnailContent.empty
  private var task: ImageTask?
  private var loadedKey: (url: URL, pixelSize: CGSize)?
  private var usedFallback = false

  init(cornerRadius: CGFloat) {
    super.init(frame: .zero)
    backgroundColor = .secondarySystemFill
    // Each layer rounds itself; masking the container would force an offscreen pass.
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous

    placeholderView.translatesAutoresizingMaskIntoConstraints = true
    placeholderView.layer.cornerRadius = cornerRadius
    placeholderView.layer.cornerCurve = .continuous
    addSubview(placeholderView)

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = cornerRadius
    imageView.layer.cornerCurve = .continuous
    addSubview(imageView)

    isAccessibilityElement = true
    accessibilityTraits = [.button, .image]
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(_ newContent: ChatInfoResourceThumbnailContent) {
    accessibilityLabel = newContent.accessibilityLabel
    updateBadge(newContent.badgeText)
    guard newContent != content else { return }
    let sameImage = newContent.url == content.url
    content = newContent
    guard !sameImage else { return }
    usedFallback = false
    cancel()
    loadedKey = nil
    imageView.image = nil
    setNeedsLayout()
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    placeholderView.frame = bounds
    imageView.frame = bounds
    if let badge {
      let size = badge.sizeThatFits(bounds.size)
      badge.frame = CGRect(
        x: bounds.maxX - size.width - 5,
        y: bounds.maxY - size.height - 5,
        width: size.width,
        height: size.height
      )
    }
    loadIfNeeded()
  }

  override func accessibilityActivate() -> Bool {
    guard onTap != nil else { return false }
    handleTap()
    return true
  }

  @objc private func handleTap() {
    onTap?(self)
  }

  private func loadIfNeeded() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    guard let url = usedFallback ? content.fallbackURL : content.url else {
      imageView.image = nil
      placeholderView.setStrippedBytes(content.strippedBytes)
      return
    }
    let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    let pixelSize = ChatInfoResourceImageRequest.pixelSize(for: bounds.size, scale: scale)
    onPixelSize?(pixelSize)
    if let loadedKey, loadedKey.url == url, loadedKey.pixelSize == pixelSize { return }
    loadedKey = (url, pixelSize)
    cancel()

    let request = ChatInfoResourceImageRequest.make(url: url, pixelSize: pixelSize, priority: .high)
    // Already decoded: show it in this frame, with no placeholder pass.
    if let cached = ImagePipeline.shared.cache[request] {
      imageView.image = cached.image
      placeholderView.setStrippedBytes(nil)
      return
    }

    if imageView.image == nil {
      placeholderView.setStrippedBytes(content.strippedBytes)
    }
    let started = CACurrentMediaTime()
    // Nuke calls back on the main queue.
    task = ImagePipeline.shared.loadImage(with: request) { [weak self] result in
      MainActor.assumeIsolated {
        guard let self, self.loadedKey?.url == url else { return }
        self.task = nil
        switch result {
          case let .success(response):
            // A decode that lands within a few frames shows without a fade.
            self.show(response.image, animated: CACurrentMediaTime() - started > 0.05)
          case .failure:
            guard !self.usedFallback, self.content.fallbackURL != nil else { return }
            self.usedFallback = true
            self.loadedKey = nil
            self.setNeedsLayout()
        }
      }
    }
  }

  private func show(_ image: UIImage, animated: Bool) {
    guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
      imageView.image = image
      placeholderView.setStrippedBytes(nil)
      return
    }
    UIView.transition(with: imageView, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
      self.imageView.image = image
    } completion: { [weak self] _ in
      guard let self, self.imageView.image === image else { return }
      self.placeholderView.setStrippedBytes(nil)
    }
  }

  private func updateBadge(_ text: String?) {
    guard let text else {
      badge?.isHidden = true
      return
    }
    let badge = badge ?? {
      let badge = ChatInfoResourceThumbnailBadge()
      addSubview(badge)
      self.badge = badge
      return badge
    }()
    badge.isHidden = false
    if badge.text != text {
      badge.text = text
      setNeedsLayout()
    }
  }
}

/// A duration capsule. Plain layers with a background color render without offscreen passes.
private final class ChatInfoResourceThumbnailBadge: UIView {
  private let label = UILabel()

  var text: String? {
    get { label.text }
    set { label.text = newValue }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor.black.withAlphaComponent(0.45)
    isUserInteractionEnabled = false
    label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
      for: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
      maximumPointSize: 15
    )
    label.textColor = .white
    label.adjustsFontForContentSizeCategory = true
    addSubview(label)
    compatRegisterForTraitChanges([.preferredContentSizeCategory]) { (badge: ChatInfoResourceThumbnailBadge, _) in
      badge.superview?.setNeedsLayout()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let text = label.sizeThatFits(size)
    return CGSize(width: ceil(text.width) + 10, height: ceil(text.height) + 4)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height / 2
    label.frame = bounds.insetBy(dx: 5, dy: 2)
  }

}

/// Looks up the on-screen thumbnail for a message, so the gallery can fly back into
/// whichever item it is showing instead of only the one that opened it.
@MainActor
final class ChatInfoResourceViewRegistry {
  private let views = NSMapTable<NSNumber, UIView>.strongToWeakObjects()

  func register(_ view: UIView, for id: Int64) {
    views.setObject(view, forKey: NSNumber(value: id))
  }

  func unregister(_ view: UIView, for id: Int64) {
    let key = NSNumber(value: id)
    if views.object(forKey: key) === view {
      views.removeObject(forKey: key)
    }
  }

  func view(for id: Int64) -> UIView? {
    guard let view = views.object(forKey: NSNumber(value: id)), view.window != nil else { return nil }
    return view
  }
}

/// Warms the memory cache a few rows ahead of the scroll at the size cells will ask for.
@MainActor
final class ChatInfoResourceThumbnailPrefetcher {
  private lazy var prefetcher: Nuke.ImagePrefetcher = {
    let prefetcher = Nuke.ImagePrefetcher(pipeline: .shared, destination: .memoryCache, maxConcurrentRequestCount: 3)
    prefetcher.priority = .low
    return prefetcher
  }()

  private var pixelSize: CGSize?
  private var prefetchedThrough = -1
  private let lookahead: Int

  init(lookahead: Int) {
    self.lookahead = lookahead
  }

  func update(pixelSize: CGSize) {
    guard pixelSize != self.pixelSize else { return }
    self.pixelSize = pixelSize
    prefetchedThrough = -1
  }

  /// Call as items appear; prefetches `lookahead` items past the furthest one seen.
  func itemAppeared(at index: Int, urls: (Range<Int>) -> [URL]) {
    guard let pixelSize, index + lookahead / 2 > prefetchedThrough else { return }
    let start = max(index + 1, prefetchedThrough + 1)
    let end = index + 1 + lookahead
    guard start < end else { return }
    prefetchedThrough = end - 1
    let requests = urls(start ..< end).map {
      ChatInfoResourceImageRequest.make(url: $0, pixelSize: pixelSize, priority: .low)
    }
    guard !requests.isEmpty else { return }
    prefetcher.startPrefetching(with: requests)
  }

  func stop() {
    prefetchedThrough = -1
    prefetcher.stopPrefetching()
  }
}

/// SwiftUI face of `ChatInfoResourceThumbnailView`.
struct ChatInfoResourceThumbnail: UIViewRepresentable {
  let id: Int64
  let content: ChatInfoResourceThumbnailContent
  var cornerRadius: CGFloat = 0
  var registry: ChatInfoResourceViewRegistry?
  var onPixelSize: ((CGSize) -> Void)?
  var onTap: ((ChatInfoResourceThumbnailView) -> Void)?

  func makeUIView(context: Context) -> ChatInfoResourceThumbnailView {
    ChatInfoResourceThumbnailView(cornerRadius: cornerRadius)
  }

  func updateUIView(_ view: ChatInfoResourceThumbnailView, context: Context) {
    view.onTap = onTap
    view.onPixelSize = onPixelSize
    view.isUserInteractionEnabled = onTap != nil
    view.apply(content)

    let coordinator = context.coordinator
    if coordinator.registeredID != id || coordinator.registry !== registry {
      if let previous = coordinator.registeredID {
        coordinator.registry?.unregister(view, for: previous)
      }
      registry?.register(view, for: id)
      coordinator.registeredID = id
      coordinator.registry = registry
    }
  }

  static func dismantleUIView(_ view: ChatInfoResourceThumbnailView, coordinator: Coordinator) {
    view.cancel()
    if let id = coordinator.registeredID {
      coordinator.registry?.unregister(view, for: id)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var registeredID: Int64?
    weak var registry: ChatInfoResourceViewRegistry?
  }
}
