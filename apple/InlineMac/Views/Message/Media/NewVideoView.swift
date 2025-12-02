import AppKit
import InlineKit
import Logger
#if canImport(QuickLookUI)
import QuickLookUI
#elseif canImport(QuickLook)
import QuickLook
#endif

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
    view.backgroundColor = .gray.withAlphaComponent(0.08)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let playBadge: NSImageView = {
    let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
    let image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")?
      .withSymbolConfiguration(config)
    let iv = NSImageView(image: image ?? NSImage())
    iv.contentTintColor = .white.withAlphaComponent(0.9)
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.wantsLayer = true
    iv.layer?.shadowColor = NSColor.black.cgColor
    iv.layer?.shadowOpacity = 0.35
    iv.layer?.shadowRadius = 6
    iv.layer?.shadowOffset = .zero
    return iv
  }()

  private let spinner: NSProgressIndicator = {
    let indicator = NSProgressIndicator()
    indicator.style = .spinning
    indicator.controlSize = .small
    indicator.translatesAutoresizingMaskIntoConstraints = false
    indicator.isDisplayedWhenStopped = false
    return indicator
  }()

  private var currentImage: NSImage?
  private var fullMessage: FullMessage
  private var isScrolling = false
  private var haveAddedImageView = false
  private let maskLayer = CAShapeLayer()
  private var isDownloading = false
  private var isShowingPreview = false
  private var activityState: ActivityState = .idle {
    didSet { updateActivityUI() }
  }

  private enum ActivityState {
    case idle
    case loadingThumb
    case downloadingVideo

    var isBusy: Bool {
      switch self {
        case .idle:
          false
        case .loadingThumb, .downloadingVideo:
          true
      }
    }
  }

  private let durationBadge: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
    label.isBordered = false
    label.wantsLayer = true
    label.layer?.cornerRadius = 6
    label.layer?.masksToBounds = true
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byClipping
    return label
  }()

  init(_ fullMessage: FullMessage, scrollState: MessageListScrollState) {
    self.fullMessage = fullMessage
    isScrolling = scrollState.isScrolling
    super.init(frame: .zero)
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

    if
      prev.videoInfo?.id == fullMessage.videoInfo?.id,
      prev.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
      == fullMessage.videoInfo?.thumbnail?.bestPhotoSize()?.localPath
    {
      return
    }

    updateImage()
    updateDurationLabel()
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

    addSubview(playBadge)
    NSLayoutConstraint.activate([
      playBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
      playBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    addSubview(durationBadge)
    NSLayoutConstraint.activate([
      durationBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      durationBadge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      durationBadge.heightAnchor.constraint(equalToConstant: 20),
    ])
    durationBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    durationBadge.setContentHuggingPriority(.required, for: .horizontal)

    updateImage()
    setupMasks()
    setupClickGesture()
    updateDurationLabel()
    updateActivityUI()
  }

  private func addImageViewIfNeeded() {
    guard !haveAddedImageView else { return }
    haveAddedImageView = true
    addSubview(imageView, positioned: .below, relativeTo: playBadge)
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
    if let url = imageLocalUrl() {
      activityState = .loadingThumb
      let loadSync = !isScrolling
      ImageCacheManager.shared.image(for: url, loadSync: loadSync) { [weak self] image in
        guard let self, let image else {
          self?.hideLoadingView()
          return
        }

        self.addImageViewIfNeeded()
        if loadSync {
          self.setImage(image)
          self.hideLoadingView()
        } else {
          self.animateImageTransition(to: image)
        }
      }
    } else {
      // Trigger thumbnail download if needed
      if let thumb = fullMessage.videoInfo?.thumbnail {
        Task.detached { [weak self] in
          guard let self else { return }
          activityState = .loadingThumb
          await FileCache.shared.download(photo: thumb, reloadMessageOnFinish: fullMessage.message)
        }
      }
      showLoadingView()
    }
  }

  private func setImage(_ image: NSImage) {
    currentImage = image
    imageLayer.contents = image
    updateImageLayerFrame()
  }

  private func animateImageTransition(to image: NSImage) {
    imageView.alphaValue = 0.0
    setImage(image)
    needsLayout = true
    layoutSubtreeIfNeeded()

    DispatchQueue.main.async {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.imageView.animator().alphaValue = 1.0
      } completionHandler: {
        self.hideLoadingView()
      }
    }
  }

  private func imageLocalUrl() -> URL? {
    guard let size = fullMessage.videoInfo?.thumbnail?.bestPhotoSize(),
          let localPath = size.localPath
    else { return nil }

    return FileCache.getUrl(for: .photos, localPath: localPath)
  }

  private func videoLocalUrl() -> URL? {
    guard let localPath = fullMessage.videoInfo?.video.localPath else { return nil }
    return FileCache.getUrl(for: .videos, localPath: localPath)
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
    let radius = Theme.messageBubbleCornerRadius - 1
    let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    maskLayer.path = path.cgPath
    maskLayer.frame = bounds
  }

  private func updateImageLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = imageView.bounds
    CATransaction.commit()
  }

  private func showLoadingView() {
    activityState = .loadingThumb
  }

  private func hideLoadingView() {
    activityState = .idle
  }

  private func updateDurationLabel() {
    guard let durationSeconds = fullMessage.videoInfo?.video.duration, durationSeconds > 0 else {
      durationBadge.isHidden = true
      return
    }

    durationBadge.isHidden = false
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

  private func updateActivityUI() {
    if activityState.isBusy {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
    playBadge.isHidden = activityState.isBusy || isShowingPreview
    backgroundView.alphaValue = activityState.isBusy ? 1.0 : 0.0
  }

  // MARK: - Click / Preview

  private func setupClickGesture() {
    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    addGestureRecognizer(click)
  }

  @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
    gesture.state == .ended ? handleClickAction() : ()
  }

  private func handleClickAction() {
    if let _ = videoLocalUrl() {
      openQuickLook()
      return
    }

    // no local file; try to download then preview
    downloadVideoThenPreview()
  }

  private func downloadVideoThenPreview() {
    guard let videoInfo = fullMessage.videoInfo, !isDownloading else { return }
    guard videoInfo.video.cdnUrl != nil else {
      Log.shared.warning("Video has no CDN URL, cannot download for preview")
      return
    }

    isDownloading = true
    activityState = .downloadingVideo

    FileDownloader.shared.downloadVideo(video: videoInfo, for: fullMessage.message) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isDownloading = false
        self.activityState = .idle

        switch result {
          case .success:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
              self.openQuickLook()
            }
          case let .failure(error):
            Log.shared.error("Failed to download video for preview", error: error)
        }
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
      updateActivityUI()
      return
    }

    // If we don't yet have the file, try to fetch it first
    downloadVideoThenPreview()
  }

  @objc func openQuickLook(_ sender: Any? = nil) {
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
}

// MARK: - QLPreviewPanel

extension NewVideoView {
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    true
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    isShowingPreview = true
    updateActivityUI()
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
    isShowingPreview = false
    updateActivityUI()
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
  func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor _: QLPreviewItem!) -> NSRect {
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

// MARK: - QLPreviewItem

extension NewVideoView: QLPreviewItem {
  var previewItemURL: URL! {
    videoLocalUrl() ?? videoCdnUrl()
  }

  var previewItemTitle: String! {
    "Video"
  }
}
