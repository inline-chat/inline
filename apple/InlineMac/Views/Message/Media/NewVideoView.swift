import AppKit
import Combine
import GRDB
import InlineKit
import Logger
#if canImport(QuickLookUI)
import QuickLookUI
#elseif canImport(QuickLook)
import QuickLook
#endif
import UniformTypeIdentifiers

// MARK: - Overlay support

private final class VideoOverlayViewModel: ObservableObject {
  enum Icon {
    case none
    case play
    case download
    case spinner
  }

  struct State: Equatable {
    var icon: Icon
    var showsPlaceholder: Bool
  }

  @Published private(set) var state: State

  init(initialState: State = .init(icon: .none, showsPlaceholder: true)) {
    state = initialState
  }

  func update(
    hasThumbnail: Bool,
    isVideoDownloaded: Bool,
    isDownloading: Bool,
    isUploading: Bool
  ) {
    // Spinner shows for active transfer (download or upload). Otherwise play if local, else download.
    let icon: Icon
    if isUploading || isDownloading {
      icon = .spinner
    } else if isVideoDownloaded {
      icon = .play
    } else {
      icon = .download
    }

    let newState = State(icon: icon, showsPlaceholder: !hasThumbnail)
    if newState != state {
      state = newState
    }
  }
}

private final class VideoOverlayView: NSView {
  private final class RingSpinnerView: NSView {
    private let ringLayer = CAShapeLayer()
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      translatesAutoresizingMaskIntoConstraints = false
      layer?.addSublayer(ringLayer)
      ringLayer.strokeColor = NSColor.white.cgColor
      ringLayer.fillColor = NSColor.clear.cgColor
      ringLayer.lineWidth = 2
      ringLayer.lineCap = .round
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
      super.layout()
      let inset: CGFloat = 2
      let rect = bounds.insetBy(dx: inset, dy: inset)
      ringLayer.frame = bounds
      ringLayer.path = NSBezierPath(
        roundedRect: rect,
        xRadius: rect.width / 2,
        yRadius: rect.height / 2
      ).cgPath
      ringLayer.strokeStart = 0.05
      ringLayer.strokeEnd = 0.85
    }

    func startAnimating() {
      guard !isAnimating else { return }
      isAnimating = true
      let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
      rotation.fromValue = 0
      rotation.toValue = 2 * Double.pi
      rotation.duration = 0.65
      rotation.repeatCount = .infinity
      ringLayer.add(rotation, forKey: "rotate")
      isHidden = false
    }

    func stopAnimating() {
      if isAnimating {
        isAnimating = false
        ringLayer.removeAnimation(forKey: "rotate")
      }
      isHidden = true
    }
  }

  fileprivate let cancelButton: NSButton = {
    let button = NSButton()
    button.bezelStyle = .shadowlessSquare
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")?
      .withSymbolConfiguration(config)
    button.contentTintColor = .white
    button.setButtonType(.momentaryChange)
    button.focusRingType = .none
    return button
  }()

  private let onCancel: () -> Void
  private let backgroundCircle: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = 24
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let playIcon: NSImageView = {
    let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
    let image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?
      .withSymbolConfiguration(config)
    let iv = NSImageView(image: image ?? NSImage())
    iv.contentTintColor = .white
    iv.translatesAutoresizingMaskIntoConstraints = false
    return iv
  }()

  private let downloadIcon: NSImageView = {
    let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
    let image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Download")?
      .withSymbolConfiguration(config)
    let iv = NSImageView(image: image ?? NSImage())
    iv.contentTintColor = .white
    iv.translatesAutoresizingMaskIntoConstraints = false
    return iv
  }()

  private let spinner = RingSpinnerView()

  private var cancellable: AnyCancellable?

  init(viewModel: VideoOverlayViewModel, onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundCircle)
    addSubview(playIcon)
    addSubview(downloadIcon)
    addSubview(spinner)
    addSubview(cancelButton)
    spinner.isHidden = true
    cancelButton.target = self
    cancelButton.action = #selector(handleCancel)

    NSLayoutConstraint.activate([
      backgroundCircle.centerXAnchor.constraint(equalTo: centerXAnchor),
      backgroundCircle.centerYAnchor.constraint(equalTo: centerYAnchor),
      backgroundCircle.widthAnchor.constraint(equalToConstant: 48),
      backgroundCircle.heightAnchor.constraint(equalToConstant: 48),

      playIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
      playIcon.centerYAnchor.constraint(equalTo: centerYAnchor),

      downloadIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
      downloadIcon.centerYAnchor.constraint(equalTo: centerYAnchor),

      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 44),
      spinner.heightAnchor.constraint(equalToConstant: 44),

      cancelButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      cancelButton.widthAnchor.constraint(equalToConstant: 24),
      cancelButton.heightAnchor.constraint(equalToConstant: 24),
    ])

    cancellable = viewModel.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.apply(state: state)
      }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func apply(state: VideoOverlayViewModel.State) {
    switch state.icon {
    case .none:
      playIcon.isHidden = true
      downloadIcon.isHidden = true
      spinner.stopAnimating()
    case .play:
      playIcon.isHidden = false
      downloadIcon.isHidden = true
      spinner.stopAnimating()
    case .download:
      playIcon.isHidden = true
      downloadIcon.isHidden = false
      spinner.stopAnimating()
    case .spinner:
      playIcon.isHidden = true
      downloadIcon.isHidden = true
      spinner.startAnimating()
    }

    spinner.isHidden = state.icon != .spinner
    cancelButton.isHidden = state.icon != .spinner
    backgroundCircle.isHidden = state.icon == .none
  }

  @objc private func handleCancel() {
    onCancel()
  }
}

final class NewVideoView: NSView {
  private let imageView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer?.backgroundColor = NSColor.clear.cgColor
    return view
  }()

  private let imageLayer: CALayer = {
    let layer = CALayer()
    layer.contentsGravity = .resizeAspectFill
    return layer
  }()

  private let backgroundView: BasicView = {
    let view = BasicView()
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.backgroundColor = .black.withAlphaComponent(0.1)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let overlayViewModel = VideoOverlayViewModel()
  private lazy var overlayView = VideoOverlayView(viewModel: overlayViewModel, onCancel: { [weak self] in
    self?.cancelActiveTransfer()
  })

  private var currentImage: NSImage?
  private var currentImageKey: String?
  private var isThumbnailLoading = false
  private var fullMessage: FullMessage
  private var isScrolling = false
  private var haveAddedImageView = false
  private let maskLayer = CAShapeLayer()
  private var topLeftRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  private var topRightRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  private var bottomLeftRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  private var bottomRightRadius: CGFloat = Theme.messageBubbleCornerRadius - 1
  private var isDownloading = false
  private var isShowingPreview = false
  private var progressCancellable: AnyCancellable?
  private var uploadProgressCancellable: AnyCancellable?
  private var boundUploadVideoLocalId: Int64?
  private var uploadProgressEvent: UploadProgressEvent?
  private var suppressNextClick = false
  private enum ActiveTransfer {
    case uploading(videoLocalId: Int64, transactionId: String?, randomId: Int64?)
    case downloading(videoId: Int64)
  }

  private var activeTransfer: ActiveTransfer?

  private let durationBadgeBackground: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
    view.layer?.cornerRadius = 10
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let durationBadge: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    label.isBordered = false
    label.isEditable = false
    label.isSelectable = false
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byClipping
    return label
  }()

  init(_ fullMessage: FullMessage, scrollState: MessageListScrollState) {
    self.fullMessage = fullMessage
    isScrolling = scrollState.isScrolling
    super.init(frame: .zero)
    updateCornerRadii()
    setupView()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Public

  func update(with fullMessage: FullMessage) {
    let prev = self.fullMessage
    self.fullMessage = fullMessage
    updateCornerRadii()
    updateMasks()

    if
      prev.videoInfo?.id == fullMessage.videoInfo?.id,
      prev.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
      == fullMessage.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
    {
      // Even if the thumbnail is unchanged, refresh overlay to reflect download/upload state changes.
      refreshDownloadFlags()
      updateOverlay()
      updateTopLeftBadge()
      return
    }

    refreshDownloadFlags()
    updateImage()
    updateTopLeftBadge()
    updateOverlay()
  }

  func setIsScrolling(_ isScrolling: Bool) {
    self.isScrolling = isScrolling
  }

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.drawsAsynchronously = true
    layer?.shouldRasterize = true
    layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(backgroundView)
    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    addSubview(overlayView)
    NSLayoutConstraint.activate([
      overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    addSubview(durationBadgeBackground)
    addSubview(durationBadge)
    NSLayoutConstraint.activate([
      durationBadgeBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      durationBadgeBackground.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      durationBadgeBackground.heightAnchor.constraint(equalToConstant: 20),

      durationBadge.leadingAnchor.constraint(equalTo: durationBadgeBackground.leadingAnchor, constant: 6),
      durationBadge.trailingAnchor.constraint(equalTo: durationBadgeBackground.trailingAnchor, constant: -6),
      durationBadge.centerYAnchor.constraint(equalTo: durationBadgeBackground.centerYAnchor),
    ])
    durationBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    durationBadge.setContentHuggingPriority(.required, for: .horizontal)

    updateImage()
    setupMasks()
    setupClickGesture()
    updateTopLeftBadge()
    updateOverlay()
  }

  private func addImageViewIfNeeded() {
    guard !haveAddedImageView else { return }
    haveAddedImageView = true
    addSubview(imageView, positioned: .below, relativeTo: overlayView)
    imageView.layer?.addSublayer(imageLayer)

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - Image loading

  private func updateImage() {
    guard let thumb = fullMessage.videoInfo?.thumbnail,
          let size = thumb.bestPhotoSize()
    else {
      isThumbnailLoading = false
      updateOverlay()
      return
    }

    let videoId = fullMessage.videoInfo?.video.id ?? thumb.id
    let cacheKey = "video-thumb-\(videoId)"
    let url: URL? =
      (size.localPath.flatMap { FileCache.getUrl(for: .photos, localPath: $0) }) ??
      (size.cdnUrl.flatMap { URL(string: $0) })

    // Fast path: memory cache hit with stable key (avoids spinner/flicker)
    if let cached = ImageCacheManager.shared.cachedImage(cacheKey: cacheKey) {
      addImageViewIfNeeded()
      setImage(cached, key: cacheKey)
      updateOverlay()
      return
    }

    // If we only have a CDN URL, kick off a background download so FileCache writes a localPath for future views.
    // NOTE: Unlike NewPhotoView, this path still relies on the incoming thumbnail data; investigate why
    // thumbnail localPath isn’t always persisted/used the same way as photos.
    if size.localPath == nil, let thumbnail = fullMessage.videoInfo?.thumbnail {
      Task.detached { [message = fullMessage.message] in
        await FileCache.shared.download(photo: thumbnail, reloadMessageOnFinish: message)
      }
    }

    guard let url else {
      // Kick off download so next refresh can use local path
      isThumbnailLoading = true
      updateOverlay()
      Task.detached { [thumb, message = fullMessage.message] in
        await FileCache.shared.download(photo: thumb, reloadMessageOnFinish: message)
      }
      return
    }

    // Avoid reload/flicker if we already set this image for this key
    if currentImageKey == cacheKey {
      isThumbnailLoading = false
      updateOverlay()
      return
    }

    let loadSync = true // prefer sync cache hit to avoid spinner flicker
    isThumbnailLoading = false

    ImageCacheManager.shared.image(for: url, loadSync: loadSync, cacheKey: cacheKey) { [weak self] image in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isThumbnailLoading = false
        self.updateOverlay()
        guard let image else { return }

        self.addImageViewIfNeeded()
        if loadSync {
          self.setImage(image, key: cacheKey)
          self.updateOverlay()
        } else {
          self.animateImageTransition(to: image, key: cacheKey)
        }
      }
    }
  }

  private func setImage(_ image: NSImage, key: String?) {
    currentImage = image
    currentImageKey = key
    imageLayer.contents = image
    updateImageLayerFrame()
  }

  private func animateImageTransition(to image: NSImage, key: String?) {
    // Avoid re-animating if we already have this image set
    if currentImageKey == key { return }

    if currentImage == nil {
      imageView.alphaValue = 0.0
      setImage(image, key: key)
      needsLayout = true
      layoutSubtreeIfNeeded()

      // Mark thumbnail loading as finished before animation to avoid spinner flash
      isThumbnailLoading = false
      DispatchQueue.main.async {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.22
          context.allowsImplicitAnimation = true
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          self.imageView.animator().alphaValue = 1.0
        } completionHandler: {
          self.updateOverlay()
        }
      }
    } else {
      // When replacing an existing image, avoid fade to prevent flicker.
      setImage(image, key: key)
      isThumbnailLoading = false
      updateOverlay()
    }
  }

  fileprivate func imageLocalUrl() -> URL? {
 

    guard let size = fullMessage.videoInfo?.thumbnail?.bestPhotoSize(),
          let localPath = size.localPath
    else { return nil }

    return FileCache.getUrl(for: .photos, localPath: localPath)
  }

  fileprivate func videoLocalUrl() -> URL? {
    if let localPath = fullMessage.videoInfo?.video.localPath {
      return FileCache.getUrl(for: .videos, localPath: localPath)
    }

    // Fallback to latest DB value (in case download finished while this view was off-screen)
    guard let videoId = fullMessage.videoInfo?.video.id else { return nil }
    if let latestLocalPath = try? AppDatabase.shared.reader.read({ db in
      try Video.filter(Video.Columns.id == videoId).fetchOne(db)?.localPath
    }) {
      return FileCache.getUrl(for: .videos, localPath: latestLocalPath)
    }

    return nil
  }


  fileprivate func hasLocalVideoFile() -> Bool {
    guard let local = videoLocalUrl() else { return false }
    return FileManager.default.fileExists(atPath: local.path)
  }

  private func videoCdnUrl() -> URL? {
    guard let urlString = fullMessage.videoInfo?.video.cdnUrl else { return nil }
    return URL(string: urlString)
  }

  // MARK: - Helpers

  private func setupMasks() {
    wantsLayer = true
    layer?.mask = maskLayer
    updateMasks()
  }

  private func updateMasks() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    maskLayer.frame = bounds
    maskLayer.path = createRoundedRectPath(for: bounds)
  }

  private func updateCornerRadii() {
    let hasText = fullMessage.message.text?.isEmpty == false
    let hasTopHeader = fullMessage.message.repliedToMessageId != nil
      || fullMessage.message.forwardFromUserId != nil
    let bubbleRadius = Theme.messageBubbleCornerRadius - 1
    let topRadius = hasTopHeader ? 0 : bubbleRadius

    topLeftRadius = topRadius
    topRightRadius = topRadius

    if hasText {
      bottomLeftRadius = 0.0
      bottomRightRadius = 0.0
    } else {
      bottomLeftRadius = bubbleRadius
      bottomRightRadius = bubbleRadius
    }
  }

  private func createRoundedRectPath(for rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let width = rect.width
    let height = rect.height

    if width <= 0 || height <= 0 {
      return path
    }

    // AppKit coordinate system: origin is bottom-left.
    path.move(to: CGPoint(x: bottomLeftRadius, y: 0))
    path.addLine(to: CGPoint(x: width - bottomRightRadius, y: 0))
    path.addArc(
      center: CGPoint(x: width - bottomRightRadius, y: bottomRightRadius),
      radius: bottomRightRadius,
      startAngle: CGFloat(3 * Double.pi / 2),
      endAngle: 0,
      clockwise: false
    )
    path.addLine(to: CGPoint(x: width, y: height - topRightRadius))
    path.addArc(
      center: CGPoint(x: width - topRightRadius, y: height - topRightRadius),
      radius: topRightRadius,
      startAngle: 0,
      endAngle: CGFloat(Double.pi / 2),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: topLeftRadius, y: height))
    path.addArc(
      center: CGPoint(x: topLeftRadius, y: height - topLeftRadius),
      radius: topLeftRadius,
      startAngle: CGFloat(Double.pi / 2),
      endAngle: CGFloat(Double.pi),
      clockwise: false
    )
    path.addLine(to: CGPoint(x: 0, y: bottomLeftRadius))
    path.addArc(
      center: CGPoint(x: bottomLeftRadius, y: bottomLeftRadius),
      radius: bottomLeftRadius,
      startAngle: CGFloat(Double.pi),
      endAngle: CGFloat(3 * Double.pi / 2),
      clockwise: false
    )

    path.closeSubpath()
    return path
  }

  private func updateImageLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = imageView.bounds
    CATransaction.commit()
  }

  private func updateTopLeftBadge() {
    if fullMessage.message.status == .sending,
       let event = uploadProgressEvent {
      durationBadge.isHidden = false
      durationBadgeBackground.isHidden = false

      switch event.phase {
      case .processing:
        durationBadge.stringValue = "Processing..."
      case .uploading:
        if event.totalBytes > 0, event.bytesSent > 0, event.fraction < 0.999 {
          let uploaded = FileHelpers.formatFileSize(UInt64(event.bytesSent))
          let total = FileHelpers.formatFileSize(UInt64(event.totalBytes))
          durationBadge.stringValue = "\(uploaded) / \(total)"
        } else {
          durationBadge.stringValue = "Uploading..."
        }
      case .completed:
        showDurationBadge()
      case .failed:
        durationBadge.stringValue = "Upload failed"
      case .cancelled:
        durationBadge.stringValue = "Upload cancelled"
      }
      return
    }

    showDurationBadge()
  }

  private func showDurationBadge() {
    guard let durationSeconds = fullMessage.videoInfo?.video.duration, durationSeconds > 0 else {
      durationBadge.isHidden = true
      durationBadgeBackground.isHidden = true
      durationBadge.stringValue = ""
      return
    }

    durationBadge.isHidden = false
    durationBadgeBackground.isHidden = false
    durationBadge.stringValue = formatDuration(seconds: durationSeconds)
  }

  private func formatDuration(seconds: Int) -> String {
    let mins = seconds / 60
    let secs = seconds % 60
    if mins >= 60 {
      let hours = mins / 60
      let remMins = mins % 60
      return String(format: "%d:%02d:%02d", hours, remMins, secs)
    } else {
      return String(format: "%d:%02d", mins, secs)
    }
  }

  private func updateOverlay() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in self?.updateOverlay() }
      return
    }

    let shouldHideOverlay = isShowingPreview
    if overlayView.isHidden != shouldHideOverlay {
      overlayView.isHidden = shouldHideOverlay
    }
    guard !shouldHideOverlay else { return }

    let hasThumb = currentImage != nil
    let isVideoDownloaded = hasLocalVideoFile()

    if isVideoDownloaded {
      // Prevent any new download attempts once we have the file locally.
      isDownloading = false
      progressCancellable?.cancel()
      progressCancellable = nil
    }

    let isUploading = fullMessage.message.status == .sending && fullMessage.videoInfo?.video.cdnUrl == nil
    if isUploading, let videoLocalId = fullMessage.videoInfo?.video.id {
      bindUploadProgressIfNeeded(videoLocalId: videoLocalId)
    } else {
      clearUploadProgressBinding()
      uploadProgressEvent = nil
    }
    let globalDownloadActive = fullMessage.videoInfo
      .map { FileDownloader.shared.isVideoDownloadActive(videoId: $0.id) } ?? false

    // Only show a download spinner when we actually need the file and a transfer is in flight.
    let downloading = (!isVideoDownloaded) && (isDownloading || globalDownloadActive)

    overlayViewModel.update(
      hasThumbnail: hasThumb,
      isVideoDownloaded: isVideoDownloaded,
      isDownloading: downloading,
      isUploading: isUploading
    )

    backgroundView.isHidden = hasThumb ? true : false

    if overlayViewModel.state.icon == .spinner {
      if isUploading, let videoLocalId = fullMessage.videoInfo?.video.id {
        activeTransfer = .uploading(
          videoLocalId: videoLocalId,
          transactionId: fullMessage.message.transactionId,
          randomId: fullMessage.message.randomId
        )
      } else if downloading, let videoId = fullMessage.videoInfo?.id {
        activeTransfer = .downloading(videoId: videoId)
      } else {
        activeTransfer = nil
      }
    } else {
      activeTransfer = nil
    }

    updateTopLeftBadge()
  }

  private func refreshDownloadFlags() {
    // Clear stale downloading state if the file is already present locally.
    if let local = videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
      isDownloading = false
    }
  }

  private func bindUploadProgressIfNeeded(videoLocalId: Int64) {
    guard boundUploadVideoLocalId != videoLocalId else { return }

    uploadProgressCancellable?.cancel()
    boundUploadVideoLocalId = videoLocalId
    uploadProgressCancellable = FileUploader
      .videoUploadProgressPublisher(videoLocalId: videoLocalId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] event in
        guard let self else { return }
        uploadProgressEvent = event
        updateTopLeftBadge()

        if event.phase == .completed || event.phase == .failed || event.phase == .cancelled {
          clearUploadProgressBinding()
        }
      }
  }

  private func clearUploadProgressBinding() {
    uploadProgressCancellable?.cancel()
    uploadProgressCancellable = nil
    boundUploadVideoLocalId = nil
  }

  // MARK: - Click / Preview

  private func setupClickGesture() {
    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    click.delegate = self
    addGestureRecognizer(click)
  }

  @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
    gesture.state == .ended ? handleClickAction() : ()
  }

  private func handleClickAction() {
    if suppressNextClick {
      suppressNextClick = false
      return
    }

    // If the file already exists locally, open immediately.
    if let local = videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
      openQuickLook()
      return
    }

    // Otherwise kick off a download/upload but don't auto-open when it finishes.
    ensureVideoAvailable { result in
      if case let .failure(error) = result {
        Log.shared.error("Failed to fetch video for preview", error: error)
      }
    }
  }

  private func openQuickLook() {
    guard let panel = QLPreviewPanel.shared() else { return }

    if let local = videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
      if panel.isVisible {
        panel.orderOut(nil)
        isShowingPreview = false
      } else {
        window?.makeFirstResponder(self)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        isShowingPreview = true
      }
      updateOverlay()
      return
    }

    // If we don't yet have the file, try to fetch it first
    handleClickAction()
  }

  @objc func openQuickLook(_: Any? = nil) {
    handleClickAction()
  }

  override func layout() {
    super.layout()
    updateMasks()
    updateImageLayerFrame()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateMasks()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? 2.0
    imageLayer.contentsScale = scale
    layer?.rasterizationScale = scale
  }

  // MARK: - First Responder / QuickLook hooks

  override var acceptsFirstResponder: Bool {
    true
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      QLPreviewPanel.shared()?.updateController()
    }
    return became
  }

  deinit {
    progressCancellable?.cancel()
    uploadProgressCancellable?.cancel()
  }

  private func cancelActiveTransfer() {
    guard let activeTransfer else { return }
    suppressNextClick = true

    switch activeTransfer {
    case let .downloading(videoId):
      FileDownloader.shared.cancelVideoDownload(videoId: videoId)
      isDownloading = false
      progressCancellable?.cancel()
      progressCancellable = nil
      updateOverlay()

    case let .uploading(videoLocalId, transactionId, randomId):
      Task { await FileUploader.shared.cancelVideoUpload(videoLocalId: videoLocalId) }

      if let transactionId, !transactionId.isEmpty {
        Transactions.shared.cancel(transactionId: transactionId)
      } else if let randomId {
        Task {
          Api.realtime.cancelTransaction(where: {
            guard $0.transaction.method == .sendMessage else { return false }
            guard case let .sendMessage(input) = $0.transaction.input else { return false }
            return input.randomID == randomId
          })
        }
      }

      // Delete the local message row to mirror cancel behavior elsewhere.
      Task(priority: .userInitiated) {
        let message = fullMessage.message
        let chatId = message.chatId
        let messageId = message.messageId
        let peerId = message.peerId

        do {
          try await AppDatabase.shared.dbWriter.write { db in
            try Message
              .filter(Column("chatId") == chatId)
              .filter(Column("messageId") == messageId)
              .deleteAll(db)
          }

          MessagesPublisher.shared
            .messagesDeleted(messageIds: [messageId], peer: peerId)
        } catch {
          Log.shared.error("Failed to delete local message row for cancel", error: error)
        }
      }

      isDownloading = false
      progressCancellable?.cancel()
      progressCancellable = nil
      clearUploadProgressBinding()
      uploadProgressEvent = nil
      updateOverlay()
    }
  }
}

// MARK: - QLPreviewPanel

extension NewVideoView {
  override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
    true
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    isShowingPreview = true
    updateOverlay()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
    isShowingPreview = false
    updateOverlay()
  }
}

// MARK: - QLPreviewPanelDataSource

extension NewVideoView: QLPreviewPanelDataSource {
  func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int { 1 }

  func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> QLPreviewItem! {
    self
  }
}

// MARK: - QLPreviewPanelDelegate

extension NewVideoView: QLPreviewPanelDelegate {
  func previewPanel(_: QLPreviewPanel!, sourceFrameOnScreenFor _: QLPreviewItem!) -> NSRect {
    window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
  }

  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    if event.type == .keyDown, event.keyCode == 53 { // Escape
      panel.close()
      return true
    }
    return false
  }
}

// MARK: - Gesture Delegate

extension NewVideoView: NSGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
    // Prevent the main click recognizer from firing when the cancel button is clicked.
    let locationInSelf = convert(event.locationInWindow, from: nil)
    let locationInOverlay = overlayView.convert(locationInSelf, from: self)
    if overlayView.hitTest(locationInOverlay) === overlayView.cancelButton {
      return false
    }
    return true
  }
}

// MARK: - QLPreviewItem

extension NewVideoView: QLPreviewItem {
  var previewItemURL: URL! {
    videoLocalUrl() ?? videoCdnUrl()
  }

  var previewItemTitle: String! {
    "Video"
  }
}

// MARK: - Save Support

extension NewVideoView {
  func ensureVideoAvailable(completion: @escaping (Result<URL, Error>) -> Void) {
    if let local = videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
      completion(.success(local))
      return
    }

    guard let videoInfo = fullMessage.videoInfo else {
      let error = NSError(domain: "NewVideoView", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing video info"])
      completion(.failure(error))
      return
    }
    guard videoInfo.video.cdnUrl != nil else {
      let error = NSError(
        domain: "NewVideoView",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Video not available"]
      )
      completion(.failure(error))
      return
    }

    // If a download is already running globally, observe it instead of starting another one.
    if FileDownloader.shared.isVideoDownloadActive(videoId: videoInfo.id) {
      // Re-check the disk before subscribing to avoid flicker if the file just arrived.
      if let local = videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
        completion(.success(local))
        return
      }

      isDownloading = true
      updateOverlay()
      progressCancellable = FileDownloader.shared.videoProgressPublisher(videoId: videoInfo.id)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] progress in
          guard let self else { return }

          // Bail out early if the file landed while we were listening.
          if let local = self.videoLocalUrl(), FileManager.default.fileExists(atPath: local.path) {
            self.progressCancellable = nil
            self.isDownloading = false
            self.updateOverlay()
            completion(.success(local))
            return
          }

          if let error = progress.error {
            self.progressCancellable = nil
            self.isDownloading = false
            self.updateOverlay()
            completion(.failure(error))
            return
          }

          if progress.isComplete, let local = self.videoLocalUrl() {
            self.progressCancellable = nil
            self.isDownloading = false
            self.updateOverlay()
            completion(.success(local))
          }
        }
      return
    }

    isDownloading = true
    updateOverlay()
    FileDownloader.shared.downloadVideo(video: videoInfo, for: fullMessage.message) { [weak self] result in
      // Capture any local file presence before hopping to main to avoid type resolution issues.
      let localUrl = self?.videoLocalUrl()
      let localExists = localUrl.flatMap { FileManager.default.fileExists(atPath: $0.path) } ?? false

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }

        // If the file appeared locally while the download callback queued, prefer it to avoid double triggers.
        if localExists, let local = localUrl {
          self.isDownloading = false
          self.updateOverlay()
          completion(.success(local))
          return
        }

        self.isDownloading = false
        self.updateOverlay()
        completion(result)
      }
    }
  }

  @objc func saveVideo() {
    guard let videoInfo = fullMessage.videoInfo else { return }
    guard let window else { return }

    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [UTType.mpeg4Movie, UTType.movie].compactMap(\.self)
    let defaultName = fullMessage.file?.fileName ?? "video_\(fullMessage.videoInfo?.id ?? fullMessage.message.id).mp4"
    savePanel.nameFieldStringValue = defaultName
    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

    savePanel.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .OK, let destinationURL = savePanel.url else { return }

      if let local = self.videoLocalUrl() {
        self.copyVideo(from: local, to: destinationURL)
        return
      }

      let alert = NSAlert()
      alert.messageText = "Download video to save?"
      alert.informativeText = "The video needs to download before it can be saved."
      alert.addButton(withTitle: "Download")
      alert.addButton(withTitle: "Cancel")

      alert.beginSheetModal(for: window) { [weak self] modalResponse in
        guard let self else { return }
        guard modalResponse == .alertFirstButtonReturn else { return }

        self.ensureVideoAvailable { [weak self] result in
          guard let self else { return }
          switch result {
          case let .success(localUrl):
            self.copyVideo(from: localUrl, to: destinationURL)
          case let .failure(error):
            Log.shared.error("Failed to download video for saving", error: error)
            Task { @MainActor in
              ToastCenter.shared.showError("Failed to download video")
            }
          }
        }
      }
    }
  }

  private func copyVideo(from source: URL, to destinationURL: URL) {
    do {
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
      }

      try FileManager.default.copyItem(at: source, to: destinationURL)
      Task { @MainActor in
        ToastCenter.shared.showSuccess("Video saved")
      }
      NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    } catch {
      Log.shared.error("Failed to save video", error: error)
      Task { @MainActor in
        ToastCenter.shared.showError("Failed to save video")
      }
    }
  }
}
