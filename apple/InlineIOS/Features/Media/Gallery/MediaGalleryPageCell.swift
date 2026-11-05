import AVFoundation
import Nuke
import UIKit

/// One gallery page: a zoomable photo, or a video's poster with its player on top.
///
/// The cell is `pageGap` wider than the screen so the pager can page with a gap
/// between photos; all content sits in the leading `pageSize` area.
final class MediaGalleryPageCell: UICollectionViewCell, UIScrollViewDelegate {
  static let reuseIdentifier = "MediaGalleryPageCell"

  /// Moves and scales as one piece during the dismiss drag.
  let scrollView = UIScrollView()
  let imageView = UIImageView()
  private let playerView = MediaGalleryPlayerView()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let retryButton = UIButton(type: .system)
  private let playButton = UIButton(type: .custom)

  private(set) var item: MediaGalleryItem?
  private var imageTask: ImageTask?
  private var hasFullImage = false
  private var triedFallback = false
  private var readyObservation: NSKeyValueObservation?
  private var pageGap: CGFloat = 0
  /// A load failed and fresh links were requested; keep the spinner, not Retry.
  private(set) var isAwaitingFreshLinks = false

  var onSingleTap: (() -> Void)?
  var onPlayTap: (() -> Void)?
  /// Called when a zoom starts or ends, so the gallery can hide its chrome.
  var onZoomChange: ((Bool) -> Void)?
  /// Called when the photo can't load. Return true if fresh links were requested.
  var onLoadFailed: ((MediaGalleryItem) -> Bool)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.clipsToBounds = false

    scrollView.delegate = self
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.decelerationRate = .fast
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 3
    scrollView.bouncesZoom = true
    contentView.addSubview(scrollView)

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)
    imageView.addSubview(playerView)

    spinner.color = .secondaryLabel
    spinner.hidesWhenStopped = true
    contentView.addSubview(spinner)

    var retry = MediaGalleryChromeStyle.glassConfiguration()
    retry.title = NSLocalizedString("Retry", comment: "Gallery retry loading a photo")
    retry.image = UIImage(systemName: "arrow.clockwise")
    retry.imagePadding = 8
    retry.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
    retryButton.configuration = retry
    retryButton.isHidden = true
    retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
    contentView.addSubview(retryButton)

    let playImage = UIImage(
      systemName: "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
    )
    var play = MediaGalleryChromeStyle.glassConfiguration()
    play.image = playImage
    play.contentInsets = .zero
    playButton.configuration = play
    playButton.accessibilityLabel = NSLocalizedString("Play", comment: "Gallery play video")
    playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
    playButton.isHidden = true
    contentView.addSubview(playButton)

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)
    let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
    singleTap.require(toFail: doubleTap)
    scrollView.addGestureRecognizer(singleTap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    imageTask?.cancel()
    imageTask = nil
    item = nil
    hasFullImage = false
    triedFallback = false
    isAwaitingFreshLinks = false
    imageView.image = nil
    detachPlayer()
    scrollView.transform = .identity
    scrollView.alpha = 1
    retryButton.isHidden = true
    spinner.stopAnimating()
  }

  // MARK: - Layout

  var pageSize: CGSize {
    CGSize(width: max(0, bounds.width - pageGap), height: bounds.height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let page = CGRect(origin: .zero, size: pageSize)
    if scrollView.bounds.size != page.size || scrollView.center != CGPoint(x: page.midX, y: page.midY) {
      let transform = scrollView.transform
      scrollView.transform = .identity
      scrollView.frame = page
      scrollView.transform = transform
      layoutContent(resetZoom: true)
    }
    spinner.center = CGPoint(x: page.midX, y: page.midY)
    retryButton.sizeToFit()
    retryButton.center = CGPoint(x: page.midX, y: page.midY)
    playButton.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
    playButton.center = CGPoint(x: page.midX, y: page.midY)
  }

  /// The image's aspect: the loaded image, else the item's metadata.
  private var contentAspectSize: CGSize? {
    if let image = imageView.image, image.size.width > 0, image.size.height > 0 {
      return image.size
    }
    return item?.pixelSize
  }

  /// Where the media sits at zoom 1, in this cell's page coordinates.
  func fittedRect(in bounds: CGSize? = nil) -> CGRect {
    let container = bounds ?? pageSize
    guard let size = contentAspectSize, container.width > 0, container.height > 0 else {
      return CGRect(origin: .zero, size: container)
    }
    let scale = min(container.width / size.width, container.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: (container.width - fitted.width) / 2,
      y: (container.height - fitted.height) / 2,
      width: fitted.width,
      height: fitted.height
    )
  }

  private func layoutContent(resetZoom: Bool) {
    if resetZoom {
      scrollView.zoomScale = 1
    }
    let fitted = fittedRect(in: scrollView.bounds.size).size
    guard fitted.width > 0, fitted.height > 0 else { return }

    if scrollView.zoomScale == 1 {
      imageView.frame = CGRect(origin: .zero, size: fitted)
      scrollView.contentSize = fitted
    }
    playerView.frame = imageView.bounds

    let isVideo = item?.kind == .video
    if isVideo {
      scrollView.maximumZoomScale = 1
    } else if let image = imageView.image {
      // Allow zooming to at least 3x, and further for large photos.
      let pixelWidth = image.size.width * image.scale
      let screenScale = window?.screen.scale ?? 3
      scrollView.maximumZoomScale = max(3, pixelWidth / (fitted.width * screenScale) * 2)
    } else {
      scrollView.maximumZoomScale = 3
    }
    centerContent()
  }

  private func centerContent() {
    let bounds = scrollView.bounds.size
    let content = scrollView.contentSize
    let x = max(0, (bounds.width - content.width) / 2)
    let y = max(0, (bounds.height - content.height) / 2)
    scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
  }

  // MARK: - Configuration

  /// Shows `item`. `placeholder` covers the page until the full image arrives.
  func configure(item: MediaGalleryItem, placeholder: UIImage?, pageGap: CGFloat) {
    self.pageGap = pageGap
    if self.item == item, hasFullImage || imageTask != nil {
      return
    }
    imageTask?.cancel()
    imageTask = nil
    self.item = item
    hasFullImage = false
    triedFallback = false
    isAwaitingFreshLinks = false
    retryButton.isHidden = true
    playButton.isHidden = item.kind != .video

    let placeholderImage = placeholder
      ?? Self.cachedImage(item.thumbnailURL)
      ?? item.strippedImage
    imageView.image = placeholderImage
    setNeedsLayout()
    layoutIfNeeded()
    layoutContent(resetZoom: true)

    switch item.kind {
      case .photo:
        load(url: item.mediaURL)
      case .video:
        if placeholderImage == nil || placeholderImage === item.strippedImage {
          load(url: item.thumbnailURL)
        } else {
          hasFullImage = true
        }
    }
  }

  private static func cachedImage(_ url: URL?) -> UIImage? {
    guard let url else { return nil }
    return ImagePipeline.shared.cache.cachedImage(for: ImageRequest(url: url))?.image
  }

  private func load(url: URL?) {
    guard let url, let item else {
      spinner.stopAnimating()
      return
    }

    if let cached = Self.cachedImage(url) {
      show(cached)
      return
    }

    if imageView.image == nil {
      spinner.startAnimating()
    }
    let itemID = item.id
    imageTask = ImagePipeline.shared.loadImage(with: ImageRequest(url: url)) { [weak self] result in
      guard let self, self.item?.id == itemID else { return }
      self.imageTask = nil
      switch result {
        case let .success(response):
          self.show(response.image)
        case .failure:
          if !self.triedFallback, let fallback = item.fallbackURL, fallback != url {
            self.triedFallback = true
            self.load(url: fallback)
            return
          }
          self.loadDidFail(item)
      }
    }
  }

  /// Old messages can carry expired signed links. Ask for fresh ones once; offer Retry
  /// only when that's already been tried. A video falls back to its player.
  private func loadDidFail(_ item: MediaGalleryItem) {
    guard item.kind == .photo, !hasFullImage else {
      spinner.stopAnimating()
      return
    }
    if onLoadFailed?(item) == true {
      isAwaitingFreshLinks = true
      spinner.startAnimating()
      retryButton.isHidden = true
      return
    }
    spinner.stopAnimating()
    retryButton.isHidden = false
  }

  /// The gallery got fresh links. If this page wasn't reconfigured with them, try again.
  func freshLinksArrived() {
    guard isAwaitingFreshLinks, let item else { return }
    isAwaitingFreshLinks = false
    triedFallback = false
    load(url: item.mediaURL)
  }

  private func show(_ image: UIImage) {
    isAwaitingFreshLinks = false
    spinner.stopAnimating()
    retryButton.isHidden = true
    hasFullImage = true
    let wasZoomed = isZoomed
    imageView.image = image
    layoutContent(resetZoom: !wasZoomed)
  }

  @objc private func retryTapped() {
    guard let item else { return }
    triedFallback = false
    retryButton.isHidden = true
    load(url: item.kind == .photo ? item.mediaURL : item.thumbnailURL)
  }

  // MARK: - Video

  func attach(player: MediaGalleryVideoPlayer) {
    guard playerView.playerLayer.player !== player.player else { return }
    readyObservation?.invalidate()
    playerView.playerLayer.player = player.player
    playerView.alpha = playerView.playerLayer.isReadyForDisplay ? 1 : 0
    readyObservation = playerView.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
      let ready = layer.isReadyForDisplay
      Task { @MainActor [weak self] in
        UIView.animate(withDuration: 0.15) { self?.playerView.alpha = ready ? 1 : 0 }
      }
    }
  }

  func detachPlayer() {
    readyObservation?.invalidate()
    readyObservation = nil
    playerView.playerLayer.player = nil
    playButton.isHidden = item?.kind != .video
  }

  func setPlaying(_ playing: Bool) {
    guard item?.kind == .video else { return }
    UIView.animate(withDuration: 0.15) {
      self.playButton.alpha = playing ? 0 : 1
    } completion: { _ in
      self.playButton.isHidden = playing
    }
    if !playing { playButton.isHidden = false }
  }

  @objc private func playTapped() {
    onPlayTap?()
  }

  // MARK: - Zoom

  var isZoomed: Bool {
    scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
  }

  func resetZoom(animated: Bool) {
    guard isZoomed else { return }
    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    item?.kind == .video ? nil : imageView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerContent()
  }

  func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    onZoomChange?(true)
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    onZoomChange?(isZoomed)
  }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    guard item?.kind == .photo, imageView.image != nil else { return }
    if isZoomed {
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
      onZoomChange?(false)
      return
    }
    // Zoom so the photo fills the screen around the tapped point, at least 2x.
    let fitted = imageView.frame.size
    let bounds = scrollView.bounds.size
    let fill = max(bounds.width / max(fitted.width, 1), bounds.height / max(fitted.height, 1))
    let scale = min(scrollView.maximumZoomScale, max(2, fill))
    let point = gesture.location(in: imageView)
    let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
    let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    onZoomChange?(true)
    scrollView.zoom(to: rect, animated: true)
  }

  @objc private func handleSingleTap() {
    onSingleTap?()
  }
}
