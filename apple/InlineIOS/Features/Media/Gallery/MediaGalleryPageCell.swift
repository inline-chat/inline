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
  private var fullResolutionTask: ImageTask?
  /// The page shows its final image for zoom 1: a photo decoded at page size, or a video's poster.
  private var hasFullImage = false
  /// The photo was swapped for its full-resolution decode, for zooming.
  private var isFullResolution = false
  /// The link the displayed photo loaded from, which the full-resolution decode reuses.
  private var loadedURL: URL?
  private var displayScale: CGFloat = 3
  private var triedFallback = false
  private var readyObservation: NSKeyValueObservation?
  private var pageGap: CGFloat = 0
  /// A load failed and fresh links were requested; keep the spinner, not Retry.
  private(set) var isAwaitingFreshLinks = false

  var onSingleTap: (() -> Void)?
  var onPlayTap: (() -> Void)?
  /// The video failed; the gallery starts a fresh player.
  var onVideoRetry: (() -> Void)?
  /// A double tap on a long video's side. Returns true when it skipped, else the tap zooms.
  var onSkip: ((_ seconds: Double) -> Bool)?
  /// Press and hold on a playing video. Returns true when it sped up.
  var onHoldSpeedUp: ((_ holding: Bool) -> Bool)?

  /// What the page shows over a video.
  struct VideoState: Equatable {
    var isPlaying = false
    var isBuffering = false
    var isFailed = false
    var isAtEnd = false
  }

  private var videoState = VideoState()
  private let bufferingView = MediaGalleryChromeStyle.glassPanel(cornerRadius: 32)
  private let bufferingSpinner = UIActivityIndicatorView(style: .medium)
  private let feedbackView = MediaGalleryToastView()
  private var feedbackHideWork: DispatchWorkItem?
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

    bufferingView.translatesAutoresizingMaskIntoConstraints = true
    bufferingView.isUserInteractionEnabled = false
    bufferingView.isHidden = true
    bufferingSpinner.color = .label
    bufferingSpinner.startAnimating()
    bufferingView.contentView.addSubview(bufferingSpinner)
    contentView.addSubview(bufferingView)
    feedbackView.alpha = 0
    contentView.addSubview(feedbackView)

    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
    hold.minimumPressDuration = 0.3
    scrollView.addGestureRecognizer(hold)

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
    fullResolutionTask?.cancel()
    fullResolutionTask = nil
    isFullResolution = false
    loadedURL = nil
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
    videoState = VideoState()
    bufferingView.isHidden = true
    playButton.alpha = 1
    feedbackView.alpha = 0
    setRetryTitle(forVideo: false)
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
    bufferingView.frame = playButton.frame
    bufferingSpinner.center = CGPoint(x: 32, y: 32)
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

    // Zoom to at least 3x, and further for large photos. The page shows a decode sized to the
    // screen, so the original's pixel size decides how far zooming stays sharp.
    let pixelWidth = item?.pixelSize?.width
      ?? imageView.image.map { $0.size.width * $0.scale }
      ?? 0
    scrollView.maximumZoomScale = max(3, pixelWidth / (fitted.width * displayScale) * 2)
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
  func configure(item: MediaGalleryItem, placeholder: UIImage?, pageGap: CGFloat, displayScale: CGFloat) {
    self.pageGap = pageGap
    self.displayScale = displayScale
    updateAccessibility(item)
    if self.item == item, hasFullImage || imageTask != nil {
      return
    }
    // The same media with new details (its download landed, a fresh link, an edited caption)
    // keeps the image on screen instead of dropping back to the thumbnail.
    if let current = self.item, current.id == item.id, current.kind == item.kind, hasFullImage {
      self.item = item
      return
    }
    imageTask?.cancel()
    imageTask = nil
    fullResolutionTask?.cancel()
    fullResolutionTask = nil
    isFullResolution = false
    loadedURL = nil
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

  private func updateAccessibility(_ item: MediaGalleryItem) {
    isAccessibilityElement = true
    accessibilityTraits = item.kind == .video ? [.image, .startsMediaSession] : .image
    var parts = [item.kind == .video ? NSLocalizedString("Video", comment: "Gallery page") : NSLocalizedString(
      "Photo",
      comment: "Gallery page"
    )]
    if let message = item.message {
      parts.append(MediaGalleryViewController.dateText(message.date))
      if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        parts.append(text)
      }
    }
    accessibilityLabel = parts.joined(separator: ", ")
  }

  private static func cachedImage(_ url: URL?) -> UIImage? {
    guard let url else { return nil }
    return cachedImage(ImageRequest(url: url))
  }

  private static func cachedImage(_ request: ImageRequest) -> UIImage? {
    ImagePipeline.shared.cache.cachedImage(for: request, caches: .memory)?.image
  }

  /// A photo decodes at the size it fills the page; a video's poster loads as is.
  private func request(for url: URL, item: MediaGalleryItem) -> ImageRequest {
    guard item.kind == .photo else { return ImageRequest(url: url) }
    return MediaGalleryImageRequests.display(url: url, item: item, pageSize: pageSize, scale: displayScale)
  }

  private func load(url: URL?) {
    guard let url, let item else {
      spinner.stopAnimating()
      return
    }

    let request = request(for: url, item: item)
    if let cached = Self.cachedImage(request) {
      loadedURL = url
      show(cached)
      return
    }

    if imageView.image == nil {
      spinner.startAnimating()
    }
    let itemID = item.id
    imageTask = ImagePipeline.shared.loadImage(with: request) { [weak self] result in
      guard let self, self.item?.id == itemID else { return }
      self.imageTask = nil
      switch result {
        case let .success(response):
          self.loadedURL = url
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

  /// Swaps the page-sized decode for the original once the user zooms, so detail stays sharp.
  /// The original isn't kept in the memory cache, so it's freed with the page.
  func loadFullResolutionIfNeeded() {
    guard let item, item.kind == .photo, hasFullImage, !isFullResolution, fullResolutionTask == nil,
          let url = loadedURL
    else { return }
    let displayed = MediaGalleryImageRequests.maxPixelSize(item: item, pageSize: pageSize, scale: displayScale)
    guard MediaGalleryImageRequests.needsFullResolution(item: item, displayedPixelSize: displayed) else { return }
    let itemID = item.id
    fullResolutionTask = ImagePipeline.shared.loadImage(with: MediaGalleryImageRequests.full(url: url)) { [weak self] result in
      guard let self, self.item?.id == itemID else { return }
      self.fullResolutionTask = nil
      guard case let .success(response) = result else { return }
      self.isFullResolution = true
      // Same aspect, so the zoomed frame stays put; only the pixels get sharper.
      UIView.transition(with: self.imageView, duration: 0.15, options: .transitionCrossDissolve) {
        self.imageView.image = response.image
      }
    }
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

  private func setRetryTitle(forVideo: Bool) {
    retryButton.configuration?.title = forVideo
      ? NSLocalizedString("Couldn't Play · Retry", comment: "Gallery retry a video that failed to play")
      : NSLocalizedString("Retry", comment: "Gallery retry loading a photo")
    setNeedsLayout()
  }

  @objc private func retryTapped() {
    guard let item else { return }
    if item.kind == .video, videoState.isFailed {
      retryButton.isHidden = true
      onVideoRetry?()
      return
    }
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

  /// What the page shows now: the video's current frame once it has played, else the image.
  func displayedImage() -> UIImage? {
    guard playerView.playerLayer.player != nil, playerView.playerLayer.isReadyForDisplay, playerView.alpha > 0,
          let time = playerView.playerLayer.player?.currentTime().seconds, time.isFinite, time > 0.05,
          imageView.bounds.width > 0, imageView.bounds.height > 0
    else { return imageView.image }
    let renderer = UIGraphicsImageRenderer(bounds: imageView.bounds)
    let frame = renderer.image { _ in
      imageView.drawHierarchy(in: imageView.bounds, afterScreenUpdates: false)
    }
    return frame
  }

  func detachPlayer() {
    readyObservation?.invalidate()
    readyObservation = nil
    playerView.playerLayer.player = nil
    setVideoState(VideoState())
    playButton.alpha = 1
    playButton.isHidden = item?.kind != .video
  }

  /// Play when paused, replay at the end, a spinner while buffering, Retry after a failure.
  func setVideoState(_ state: VideoState) {
    guard item?.kind == .video, state != videoState else { return }
    let ended = state.isAtEnd != videoState.isAtEnd
    videoState = state
    let showsPlay = !state.isPlaying && !state.isFailed && !state.isBuffering
    if ended || playButton.configuration?.image == nil {
      playButton.configuration?.image = UIImage(
        systemName: state.isAtEnd ? "arrow.counterclockwise" : "play.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
      )
      playButton.accessibilityLabel = state.isAtEnd ? "Replay" : "Play"
    }
    if showsPlay { playButton.isHidden = false }
    UIView.animate(withDuration: 0.15) {
      self.playButton.alpha = showsPlay ? 1 : 0
    } completion: { _ in
      self.playButton.isHidden = !(!self.videoState.isPlaying && !self.videoState.isFailed && !self.videoState.isBuffering)
    }
    bufferingView.isHidden = !state.isBuffering
    setRetryTitle(forVideo: state.isFailed)
    retryButton.isHidden = !state.isFailed
  }

  /// A short glass label on the side that was tapped, such as "15 s" for a skip.
  func showFeedback(_ text: String, systemImage: String, leading: Bool?) {
    feedbackView.update(text: text, systemImage: systemImage)
    let size = feedbackView.systemLayoutSizeFitting(
      CGSize(width: 200, height: 40),
      withHorizontalFittingPriority: .fittingSizeLevel,
      verticalFittingPriority: .required
    )
    let page = CGRect(origin: .zero, size: pageSize)
    let x: CGFloat = switch leading {
      case .some(true): page.width * 0.2
      case .some(false): page.width * 0.8
      case .none: page.midX
    }
    let y = leading == nil ? page.minY + max(safeAreaInsets.top, 20) + 70 : page.midY
    feedbackView.frame = CGRect(x: x - size.width / 2, y: y - 20, width: size.width, height: 40)
    feedbackHideWork?.cancel()
    UIView.animate(withDuration: 0.15) { self.feedbackView.alpha = 1 }
    let work = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.25) { self?.feedbackView.alpha = 0 }
    }
    feedbackHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (leading == nil ? 60 : 0.7), execute: work)
  }

  func hideFeedback() {
    feedbackHideWork?.cancel()
    UIView.animate(withDuration: 0.2) { self.feedbackView.alpha = 0 }
  }

  @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
    guard item?.kind == .video else { return }
    switch gesture.state {
      case .began:
        if onHoldSpeedUp?(true) == true {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          showFeedback("2×", systemImage: "forward.fill", leading: nil)
        }
      case .ended, .cancelled, .failed:
        if onHoldSpeedUp?(false) == true {
          hideFeedback()
        }
      default:
        break
    }
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
    // A video zooms with its poster; the player is a subview of the image view.
    imageView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerContent()
  }

  func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
    loadFullResolutionIfNeeded()
    onZoomChange?(true)
  }

  func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
    onZoomChange?(isZoomed)
  }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    guard let item, imageView.image != nil else { return }
    // A long video skips 15 s from a double tap on its sides, like Telegram: back on the leading
    // third, forward elsewhere. Zoomed in, a double tap zooms back out instead.
    if item.kind == .video, !isZoomed {
      let x = gesture.location(in: self).x / max(pageSize.width, 1)
      let back = effectiveUserInterfaceLayoutDirection == .rightToLeft ? x > 0.65 : x < 0.35
      let seconds: Double = back ? -15 : 15
      if onSkip?(seconds) == true {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showFeedback("15 s", systemImage: back ? "gobackward.15" : "goforward.15", leading: back)
        return
      }
    }
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
    loadFullResolutionIfNeeded()
    onZoomChange?(true)
    scrollView.zoom(to: rect, animated: true)
  }

  @objc private func handleSingleTap() {
    onSingleTap?()
  }
}

/// Image requests for gallery pages. A page decodes its photo at the size it fills the screen,
/// not at full resolution (a 12 MP photo is about 48 MB decoded; fitted to a phone, about 5 MB),
/// and prefetching uses the same requests so neighbors come from the cache.
enum MediaGalleryImageRequests {
  static func display(url: URL, item: MediaGalleryItem, pageSize: CGSize, scale: CGFloat) -> ImageRequest {
    let pixels = maxPixelSize(item: item, pageSize: pageSize, scale: scale)
    return ImageRequest(
      url: url,
      userInfo: [.thumbnailKey: ImageRequest.ThumbnailOptions(maxPixelSize: Float(pixels))]
    )
  }

  /// The original, for zooming. Not written to the memory cache, so it doesn't outlive its page.
  static func full(url: URL) -> ImageRequest {
    ImageRequest(url: url, options: [.disableMemoryCacheWrites])
  }

  /// The longest side, in pixels, of the photo fitted to the page.
  static func maxPixelSize(item: MediaGalleryItem, pageSize: CGSize, scale: CGFloat) -> CGFloat {
    var longest = max(pageSize.width, pageSize.height)
    if let size = item.pixelSize, size.width > 0, size.height > 0, pageSize.width > 0, pageSize.height > 0 {
      let fit = min(pageSize.width / size.width, pageSize.height / size.height)
      longest = max(size.width, size.height) * fit
    }
    // Rounded up so small layout differences share a cache entry.
    return max(256, (longest * max(scale, 1) / 128).rounded(.up) * 128)
  }

  /// True when the original has noticeably more pixels than the page-sized decode.
  static func needsFullResolution(item: MediaGalleryItem, displayedPixelSize: CGFloat) -> Bool {
    guard let size = item.pixelSize else { return true }
    return max(size.width, size.height) > displayedPixelSize * 1.2
  }
}
