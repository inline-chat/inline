import AppKit
import InlineKit
import InlineUI
import Logger
import Nuke
import NukeUI

final class SimplePhotoView: NSView {
  enum SizingMode: Equatable {
    case constraints
    case manualFrames
  }

  private static let imageFadeDuration: TimeInterval = 0.22
  private static let log = Log.scoped("SimplePhotoView")

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
    view.backgroundColor = .gray.withAlphaComponent(0.05)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let tinyThumbnailBackgroundView: InlineTinyThumbnailBackgroundView = {
    let view = InlineTinyThumbnailBackgroundView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let overlayImageView: NSImageView = {
    let iv = NSImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.contentTintColor = .white
    iv.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
    iv.isHidden = true
    return iv
  }()

  private var photoInfo: PhotoInfo?
  private var widthConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var relatedMessage: Message?
  private var overlaySymbol: String?
  private let sizingMode: SizingMode
  private var imageLoadGeneration = 0
  private var imageDecodeGeneration = 0
  private var imageResolutionTask: Task<Void, Never>?
  private var failedImageURLs = Set<URL>()
  private var downloadAttemptSource: PhotoDownloadSourceKey?

  /// The existing decoded image, for native preview transitions. No second cache.
  var displayedImage: NSImage? { imageLayer.contents as? NSImage }

  init(
    photoInfo: PhotoInfo,
    width: CGFloat,
    height: CGFloat,
    relatedMessage: Message? = nil,
    overlaySymbol: String? = nil,
    sizingMode: SizingMode = .constraints
  ) {
    self.photoInfo = photoInfo
    self.relatedMessage = relatedMessage
    self.overlaySymbol = overlaySymbol
    self.sizingMode = sizingMode
    super.init(frame: .zero)
    setupView()
    switch sizingMode {
    case .constraints:
      updateSize(width: width, height: height)
    case .manualFrames:
      applyManualLayoutFrame(CGRect(x: 0, y: 0, width: width, height: height))
    }
    updateImage()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = 4.0
    layer?.masksToBounds = true
    translatesAutoresizingMaskIntoConstraints = sizingMode == .constraints ? false : true

    addSubview(tinyThumbnailBackgroundView)
    addSubview(backgroundView)
    addSubview(imageView)
    addSubview(overlayImageView)

    NSLayoutConstraint.activate([
      tinyThumbnailBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tinyThumbnailBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tinyThumbnailBackgroundView.topAnchor.constraint(equalTo: topAnchor),
      tinyThumbnailBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

      overlayImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      overlayImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      overlayImageView.widthAnchor.constraint(equalToConstant: 24),
      overlayImageView.heightAnchor.constraint(equalToConstant: 24),
    ])
    tinyThumbnailBackgroundView.onVisibilityChange = { [weak self] isVisible in
      guard let self, imageLayer.contents == nil else { return }
      backgroundView.isHidden = isVisible
    }

    imageView.layer?.addSublayer(imageLayer)
    updateTinyThumbnailBackground()
    showLoadingView()
    updateOverlayImage()
  }

  func updateSize(width: CGFloat, height: CGFloat) {
    guard sizingMode == .constraints else {
      assertionFailure("Use applyManualLayoutFrame(_:) for a manually sized SimplePhotoView")
      return
    }
    if let widthConstraint, let heightConstraint {
      if widthConstraint.constant != width { widthConstraint.constant = width }
      if heightConstraint.constant != height { heightConstraint.constant = height }
      return
    }
    widthConstraint = widthAnchor.constraint(equalToConstant: width)
    heightConstraint = heightAnchor.constraint(equalToConstant: height)
    widthConstraint?.isActive = true
    heightConstraint?.isActive = true
  }

  func applyManualLayoutFrame(_ frame: CGRect) {
    guard sizingMode == .manualFrames else {
      assertionFailure("Manual frames require SimplePhotoView.SizingMode.manualFrames")
      return
    }
    precondition(
      frame.minX.isFinite && frame.minY.isFinite
        && frame.width.isFinite && frame.height.isFinite
        && frame.width >= 0 && frame.height >= 0,
      "SimplePhotoView received invalid manual geometry"
    )
    if self.frame != frame {
      self.frame = frame
    }
    needsLayout = true
    layoutSubtreeIfNeeded()
    debugAssertUnambiguousLayout()
  }

  private func updateImage() {
    guard let photoInfo else {
      Self.log.warning("Photo view has no photo metadata")
      return
    }
    let localCandidate = FileCache.cachedLocalURLCandidates(photo: photoInfo)
      .first(where: { !failedImageURLs.contains($0) })
    let bestLocalAvailable = FileCache.cachedLocalURL(photo: photoInfo)
      .map { !failedImageURLs.contains($0) } ?? false
    if imageResolutionTask != nil, downloadAttemptSource == photoInfo.downloadSourceKey(), !bestLocalAvailable {
      if let localCandidate { loadImage(from: localCandidate, generation: imageLoadGeneration) }
      return
    }
    imageLoadGeneration += 1
    let generation = imageLoadGeneration
    imageResolutionTask?.cancel()
    if imageResolutionTask != nil {
      downloadAttemptSource = nil
      imageResolutionTask = nil
    }
    if let url = localCandidate {
      loadImage(from: url, generation: generation)
    }
    // A local thumbnail remains visible while the full remote representation
    // is resolved. It must not prevent the best-size upgrade.
    if bestLocalAvailable { return }
    guard let source = photoInfo.downloadSourceKey(), downloadAttemptSource != source else { return }
    downloadAttemptSource = source
    let relatedMessage = relatedMessage
    imageResolutionTask = Task { [weak self] in
      defer {
        if self?.imageLoadGeneration == generation { self?.imageResolutionTask = nil }
      }
      if let cachedURL = await FileCache.shared.cachedLocalURL(photo: photoInfo),
         self?.failedImageURLs.contains(cachedURL) == false
      {
        guard !Task.isCancelled else { return }
        self?.loadImage(from: cachedURL, generation: generation)
        return
      }
      let repaired = await FileCache.shared.downloadAndWait(photo: photoInfo, reloadMessageOnFinish: relatedMessage)
      guard !Task.isCancelled, self?.imageLoadGeneration == generation,
            self?.photoInfo?.downloadSourceKey() == source else { return }
      if let repaired {
        self?.failedImageURLs.remove(repaired)
      }
      let candidates = await FileCache.shared.cachedLocalURLCandidates(photo: photoInfo)
      guard let localURL = repaired ?? candidates.first(where: { self?.failedImageURLs.contains($0) == false })
      else {
        Self.log.warning("Photo cache did not produce a local file for photo \(photoInfo.id)")
        return
      }
      self?.loadImage(from: localURL, generation: generation)
    }
  }

  private func loadImage(from url: URL, generation: Int) {
    guard imageLoadGeneration == generation else { return }
    imageDecodeGeneration += 1
    let decodeGeneration = imageDecodeGeneration
    let targetSize = preferredImageTargetSize()
    let scale = backingScale
    let isMemoryCached = ImageCacheManager.shared.cachedImage(
      for: url,
      targetSize: targetSize,
      scale: scale
    ) != nil

    ImageCacheManager.shared.image(
      for: url,
      loadSync: false,
      targetSize: targetSize,
      scale: scale
    ) { [weak self] image in
      guard let self else { return }
      guard self.imageLoadGeneration == generation, self.imageDecodeGeneration == decodeGeneration else { return }
      guard let image else {
        self.failedImageURLs.insert(url)
        Self.log.warning("Image decode failed for photo \(self.photoInfo?.id ?? 0)")
        self.showLoadingView()
        self.updateImage()
        return
      }

      self.failedImageURLs.remove(url)

      if !isMemoryCached, shouldFadeImageIn {
        animateImageTransition(to: image)
      } else {
        setImage(image)
        hideLoadingView()
      }
    }
  }

  private var backingScale: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
  }

  private func preferredImageTargetSize() -> CGSize {
    if bounds.width > 0, bounds.height > 0 {
      return bounds.size
    }

    if let width = widthConstraint?.constant,
       let height = heightConstraint?.constant,
       width > 0,
       height > 0
    {
      return CGSize(width: width, height: height)
    }

    return CGSize(width: 96, height: 96)
  }

  private func updateTinyThumbnailBackground() {
    tinyThumbnailBackgroundView.setPhoto(photoInfo)

    if imageLayer.contents == nil {
      backgroundView.isHidden = !shouldShowFlatPlaceholder()
    }
  }

  private func setImage(_ image: NSImage) {
    imageLayer.contents = image
    updateImageLayerFrame()
  }

  private var shouldFadeImageIn: Bool {
    imageLayer.contents == nil && !tinyThumbnailBackgroundView.isHidden
  }

  private func animateImageTransition(to image: NSImage) {
    imageView.alphaValue = 0
    setImage(image)
    needsLayout = true
    layoutSubtreeIfNeeded()

    DispatchQueue.main.async {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.imageFadeDuration
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.imageView.animator().alphaValue = 1
      } completionHandler: {
        self.hideLoadingView()
      }
    }
  }

  private func updateImageLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = imageView.bounds
    CATransaction.commit()
  }

  private func updateOverlayImage() {
    if let overlaySymbol {
      overlayImageView.image = NSImage(
        systemSymbolName: overlaySymbol,
        accessibilityDescription: "Overlay"
      )
      overlayImageView.isHidden = false
      overlayImageView.layer?.shadowColor = NSColor.black.cgColor
      overlayImageView.layer?.shadowOpacity = 0.35
      overlayImageView.layer?.shadowRadius = 6
      overlayImageView.layer?.shadowOffset = .zero
    } else {
      overlayImageView.isHidden = true
    }
  }

  private func showLoadingView() {
    backgroundView.isHidden = !shouldShowFlatPlaceholder()
  }

  private func hideLoadingView() {
    backgroundView.isHidden = true
  }

  private func shouldShowFlatPlaceholder() -> Bool {
    !tinyThumbnailBackgroundView.isShowingThumbnail
  }

  override func layout() {
    super.layout()
    updateImageLayerFrame()
  }

  private func debugAssertUnambiguousLayout() {
    #if DEBUG
    assert(!hasAmbiguousLayout, "SimplePhotoView manual root layout is ambiguous")
    for view in subviews {
      assert(!view.hasAmbiguousLayout, "SimplePhotoView descendant layout is ambiguous: \(type(of: view))")
    }
    #endif
  }

  func update(with photoInfo: PhotoInfo, overlaySymbol: String? = nil) {
    if self.photoInfo != photoInfo {
      failedImageURLs.removeAll(keepingCapacity: true)
    }
    self.photoInfo = photoInfo
    self.overlaySymbol = overlaySymbol
    updateTinyThumbnailBackground()
    updateOverlayImage()
    updateImage()
  }

  deinit {
    imageResolutionTask?.cancel()
  }
}
