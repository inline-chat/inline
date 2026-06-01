import Foundation
import InlineKit
import Kingfisher

#if os(iOS)
import UIKit
public typealias PlatformView = UIView
typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformView = NSView
typealias PlatformImage = NSImage
#endif

private let platformPhotoFadeDuration: TimeInterval = 0.22
private let platformPhotoResizeLoadDelay: TimeInterval = 0.12

struct PlatformPhotoLoadPolicy {
  static let resizeBucket: CGFloat = 16
  static let upscaleTolerance: CGFloat = 1.08
  static let maxAspectFillExpansion: CGFloat = 3

  static func canReuseLoadedImage(
    loadedSize: CGSize,
    loadedScale: CGFloat,
    targetSize: CGSize,
    targetScale: CGFloat
  ) -> Bool {
    guard abs(loadedScale - targetScale) < 0.01 else { return false }

    return canReuseLoadedImage(loadedSize: loadedSize, targetSize: targetSize)
  }

  static func canReuseLoadedImage(loadedSize: CGSize, targetSize: CGSize) -> Bool {
    guard loadedSize.width > 0, loadedSize.height > 0 else { return false }

    return targetSize.width <= loadedSize.width * upscaleTolerance
      && targetSize.height <= loadedSize.height * upscaleTolerance
  }

  static func bucketedTargetSize(_ size: CGSize) -> CGSize {
    CGSize(
      width: max(resizeBucket, ceil(size.width / resizeBucket) * resizeBucket),
      height: max(resizeBucket, ceil(size.height / resizeBucket) * resizeBucket)
    )
  }

  static func imageRequestSize(
    displaySize: CGSize,
    sourceSize: CGSize?,
    contentMode: PlatformPhotoContentMode
  ) -> CGSize {
    let displaySize = bucketedTargetSize(displaySize)
    guard contentMode == .aspectFill,
          let sourceSize,
          sourceSize.width > 0,
          sourceSize.height > 0,
          displaySize.width > 0,
          displaySize.height > 0
    else {
      return displaySize
    }

    let sourceAspect = sourceSize.width / sourceSize.height
    let displayAspect = displaySize.width / displaySize.height
    let requestSize: CGSize
    if sourceAspect > displayAspect {
      requestSize = CGSize(
        width: displaySize.height * sourceAspect,
        height: displaySize.height
      )
    } else {
      requestSize = CGSize(
        width: displaySize.width,
        height: displaySize.width / sourceAspect
      )
    }

    let maxDimension = max(displaySize.width, displaySize.height) * maxAspectFillExpansion
    return bucketedTargetSize(CGSize(
      width: min(requestSize.width, maxDimension),
      height: min(requestSize.height, maxDimension)
    ))
  }

  static func needsBestPhotoDownload(_ photoInfo: PhotoInfo) -> Bool {
    guard let size = photoInfo.bestPhotoSize() else { return false }
    let hasLocalFile = size.localPath?.isEmpty == false
    guard !hasLocalFile,
          let cdnUrl = size.cdnUrl,
          !cdnUrl.isEmpty
    else { return false }

    return true
  }

  static func localPhotoSizeCandidates(from photoInfo: PhotoInfo) -> [PhotoSize] {
    var candidates: [PhotoSize] = []
    if let bestSize = photoInfo.bestPhotoSize(), bestSize.localPath?.isEmpty == false {
      candidates.append(bestSize)
    }

    let fallbackSizes = photoInfo.sizes
      .filter { $0.type != "s" && $0.localPath?.isEmpty == false }
      .sorted { lhs, rhs in
        let lhsArea = max((lhs.width ?? 0) * (lhs.height ?? 0), 0)
        let rhsArea = max((rhs.width ?? 0) * (rhs.height ?? 0), 0)
        if lhsArea != rhsArea {
          return lhsArea > rhsArea
        }

        return (lhs.size ?? 0) > (rhs.size ?? 0)
      }

    for size in fallbackSizes {
      let localPath = size.localPath ?? ""
      let alreadyAdded = candidates.contains { $0.localPath == localPath }
      if !alreadyAdded {
        candidates.append(size)
      }
    }

    return candidates
  }

  static func bestLocalPhotoSize(from photoInfo: PhotoInfo) -> PhotoSize? {
    localPhotoSizeCandidates(from: photoInfo).first
  }

  static func aspectFillSourceRect(imageSize: CGSize, displaySize: CGSize) -> CGRect {
    guard imageSize.width > 0,
          imageSize.height > 0,
          displaySize.width > 0,
          displaySize.height > 0
    else {
      return .zero
    }

    let displayAspect = displaySize.width / displaySize.height
    let imageAspect = imageSize.width / imageSize.height
    if imageAspect > displayAspect {
      let sourceWidth = imageSize.height * displayAspect
      return CGRect(
        x: (imageSize.width - sourceWidth) / 2,
        y: 0,
        width: sourceWidth,
        height: imageSize.height
      )
    }

    let sourceHeight = imageSize.width / displayAspect
    return CGRect(
      x: 0,
      y: (imageSize.height - sourceHeight) / 2,
      width: imageSize.width,
      height: sourceHeight
    )
  }

  static func aspectFitDestinationRect(imageSize: CGSize, displaySize: CGSize) -> CGRect {
    guard imageSize.width > 0,
          imageSize.height > 0,
          displaySize.width > 0,
          displaySize.height > 0
    else {
      return .zero
    }

    let scale = min(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: (displaySize.width - size.width) / 2,
      y: (displaySize.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }
}

public enum PlatformPhotoContentMode {
  case aspectFill
  case aspectFit
}

public final class PlatformPhotoView: PlatformView {
  #if os(iOS)
  public var displayedImage: UIImage? { imageView.displayedImage }
  #else
  public var displayedImage: NSImage? { imageView.displayedImage }
  #endif

  public var photoContentMode: PlatformPhotoContentMode = .aspectFill {
    didSet {
      guard oldValue != photoContentMode else { return }
      imageView.updateContentMode(photoContentMode)
      updateImageIfNeeded()
    }
  }

  public var showsLoadingPlaceholder: Bool = true {
    didSet {
      if showsLoadingPlaceholder {
        if !imageView.hasImage {
          showPlaceholder()
        }
      } else {
        hidePlaceholder()
      }
    }
  }

  public var showsTinyThumbnailBackground = false {
    didSet {
      updateTinyThumbnailBackground()
    }
  }

  private let tinyThumbnailBackgroundView = InlineTinyThumbnailBackgroundView()
  private let imageView = ImageContainerView()
  private let placeholderView = ShimmerPlaceholderView()

  private var currentLoadKey: String?
  private var currentLoadedSize: CGSize = .zero
  private var currentLoadedScale: CGFloat = 0
  private var currentLocalUrl: URL?
  private var currentPhotoId: Int64?
  private var currentLoadingKey: String?
  private var currentLoadingGeneration = 0
  private var currentLoadingSize: CGSize = .zero
  private var currentLoadingScale: CGFloat = 0
  private var currentLoadingUrl: URL?
  private var downloadRequestedPhotoId: Int64?
  private var pendingPhotoInfo: PhotoInfo?
  private var reloadMessage: Message?
  private var currentTask: DownloadTask?
  private var pendingLoadWorkItem: DispatchWorkItem?
  private var loadGeneration = 0

  public convenience init() {
    self.init(frame: .zero)
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    cancelPendingLoad()
    cancelCurrentTask()
  }

  public func setPhoto(_ photoInfo: PhotoInfo?, reloadMessageOnFinish message: Message? = nil) {
    let nextPhotoId = photoInfo?.id
    if nextPhotoId != currentPhotoId {
      resetImageState()
      downloadRequestedPhotoId = nil
    }

    currentPhotoId = nextPhotoId
    pendingPhotoInfo = photoInfo
    reloadMessage = message
    updateTinyThumbnailBackground()
    updateImageIfNeeded()
  }

  #if os(iOS)
  public override func layoutSubviews() {
    super.layoutSubviews()
    updateImageIfNeeded()
  }
  #else
  public override func layout() {
    super.layout()
    updateImageIfNeeded()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      cancelPendingLoad()
      cancelCurrentTask()
      currentLoadKey = nil
      return
    }

    updateImageIfNeeded()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateImageIfNeeded()
  }
  #endif

  private func setupView() {
    #if os(macOS)
    wantsLayer = true
    #endif
    #if os(iOS)
    layer.masksToBounds = true
    #else
    layer?.masksToBounds = true
    #endif
    translatesAutoresizingMaskIntoConstraints = false

    tinyThumbnailBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    imageView.translatesAutoresizingMaskIntoConstraints = false
    placeholderView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(tinyThumbnailBackgroundView)
    addSubview(placeholderView)
    addSubview(imageView)

    NSLayoutConstraint.activate([
      tinyThumbnailBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tinyThumbnailBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tinyThumbnailBackgroundView.topAnchor.constraint(equalTo: topAnchor),
      tinyThumbnailBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      placeholderView.leadingAnchor.constraint(equalTo: leadingAnchor),
      placeholderView.trailingAnchor.constraint(equalTo: trailingAnchor),
      placeholderView.topAnchor.constraint(equalTo: topAnchor),
      placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    imageView.updateContentMode(photoContentMode)
    updateTinyThumbnailBackground()
    showPlaceholder()
  }

  private func updateTinyThumbnailBackground() {
    tinyThumbnailBackgroundView.setPhoto(showsTinyThumbnailBackground ? pendingPhotoInfo : nil)
  }

  private func updateImageIfNeeded() {
    guard let photoInfo = pendingPhotoInfo else {
      clearImage()
      showPlaceholder()
      return
    }

    if shouldDownloadBestPhoto(photoInfo) {
      requestDownloadIfNeeded(photoInfo)
    }

    guard let localUrl = localDisplayUrl(for: photoInfo) else {
      if !imageView.hasImage {
        showPlaceholder()
      }
      requestDownloadIfNeeded(photoInfo)
      return
    }

    guard let targetSize = resolveTargetSize(from: photoInfo) else {
      if !imageView.hasImage {
        showPlaceholder()
      }
      return
    }

    let scale = backingScaleFactor()
    let sizeKey = "\(Int(targetSize.width))x\(Int(targetSize.height))"
    let scaleKey = Int((scale * 100).rounded())
    let loadKey = "\(photoInfo.id)-\(localUrl.path)-\(sizeKey)-\(scaleKey)-\(photoContentMode)"

    if loadKey == currentLoadKey {
      if imageView.hasImage {
        hidePlaceholder()
      } else {
        showPlaceholder()
      }
      return
    }

    if canReuseCurrentImage(from: localUrl, targetSize: targetSize, scale: scale) {
      cancelPendingLoad()
      cancelCurrentTask()
      currentLoadKey = loadKey
      hidePlaceholder()
      return
    }

    if canUseInFlightLoad(from: localUrl, targetSize: targetSize, scale: scale) {
      if imageView.hasImage {
        hidePlaceholder()
      }
      return
    }

    if canKeepInitialInFlightLoad(from: localUrl, scale: scale) {
      showPlaceholder()
      return
    }

    if !imageView.hasImage {
      showPlaceholder()
    }

    scheduleImageLoad(
      from: localUrl,
      targetSize: targetSize,
      scale: scale,
      loadKey: loadKey,
      deferred: imageView.hasImage
    )
  }

  private func canReuseCurrentImage(from url: URL, targetSize: CGSize, scale: CGFloat) -> Bool {
    guard imageView.hasImage,
          currentLocalUrl == url
    else { return false }

    return PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: currentLoadedSize,
      loadedScale: currentLoadedScale,
      targetSize: targetSize,
      targetScale: scale
    )
  }

  private func canUseInFlightLoad(from url: URL, targetSize: CGSize, scale: CGFloat) -> Bool {
    guard currentLoadingKey != nil,
          currentLoadingUrl == url
    else { return false }

    return PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: currentLoadingSize,
      loadedScale: currentLoadingScale,
      targetSize: targetSize,
      targetScale: scale
    )
  }

  private func canKeepInitialInFlightLoad(from url: URL, scale: CGFloat) -> Bool {
    guard !imageView.hasImage,
          currentLoadingKey != nil,
          currentLoadingUrl == url,
          abs(currentLoadingScale - scale) < 0.01
    else { return false }

    return true
  }

  private func scheduleImageLoad(
    from url: URL,
    targetSize: CGSize,
    scale: CGFloat,
    loadKey: String,
    deferred: Bool
  ) {
    cancelPendingLoad()
    if !deferred {
      cancelCurrentTask()
    }

    currentLoadKey = loadKey
    let generation = nextLoadGeneration()

    guard deferred else {
      loadImage(from: url, targetSize: targetSize, scale: scale, loadKey: loadKey, generation: generation)
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
            self.currentLoadKey == loadKey,
            self.loadGeneration == generation
      else { return }

      self.pendingLoadWorkItem = nil
      self.cancelCurrentTask()
      self.loadImage(from: url, targetSize: targetSize, scale: scale, loadKey: loadKey, generation: generation)
    }
    pendingLoadWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + platformPhotoResizeLoadDelay, execute: workItem)
  }

  private func loadImage(
    from url: URL,
    targetSize: CGSize,
    scale: CGFloat,
    loadKey: String,
    generation: Int
  ) {
    currentLoadingKey = loadKey
    currentLoadingGeneration = generation
    currentLoadingUrl = url
    currentLoadingSize = targetSize
    currentLoadingScale = scale

    let options: KingfisherOptionsInfo = [
      .processor(DownsamplingImageProcessor(size: targetSize)),
      .scaleFactor(scale),
      .loadDiskFileSynchronously,
      .cacheMemoryOnly,
    ]

    let provider = LocalFileImageDataProvider(fileURL: url)

    let task = KingfisherManager.shared.retrieveImage(
      with: .provider(provider),
      options: options
    ) { [weak self] result in
      guard let self else { return }
      guard self.currentLoadingKey == loadKey,
            self.currentLoadingGeneration == generation
      else { return }

      self.clearLoadingState()

      guard self.currentLoadKey == loadKey,
            self.loadGeneration == generation
      else { return }

      switch result {
      case let .success(value):
        self.currentLocalUrl = url
        self.currentLoadedSize = value.image.size
        self.currentLoadedScale = scale
        self.setImage(value.image, loadedFromMemory: value.cacheType == .memory)
        self.hidePlaceholder()
        self.updateImageIfNeeded()
      case .failure:
        self.currentLoadKey = nil
        if !self.imageView.hasImage {
          self.showPlaceholder()
        }
      }
    }

    if currentLoadingKey == loadKey, currentLoadingGeneration == generation {
      currentTask = task
    } else {
      task?.cancel()
    }
  }

  private func setImage(_ image: PlatformImage?, loadedFromMemory: Bool = false) {
    let shouldFade = image != nil
      && !tinyThumbnailBackgroundView.isHidden
      && !loadedFromMemory
      && !imageView.hasImage

    imageView.setImage(image, animated: shouldFade)
  }

  private func clearImage() {
    if hasActiveImageState {
      resetImageState()
    }
    showPlaceholder()
  }

  private var hasActiveImageState: Bool {
    imageView.hasImage
      || currentLoadKey != nil
      || currentLoadedSize != .zero
      || currentLoadedScale != 0
      || currentLocalUrl != nil
      || currentLoadingKey != nil
      || currentLoadingUrl != nil
      || currentLoadingSize != .zero
      || currentLoadingScale != 0
      || currentTask != nil
      || pendingLoadWorkItem != nil
  }

  private func nextLoadGeneration() -> Int {
    loadGeneration += 1
    return loadGeneration
  }

  private func resetImageState() {
    cancelPendingLoad()
    cancelCurrentTask()
    currentLoadKey = nil
    currentLoadedSize = .zero
    currentLoadedScale = 0
    currentLocalUrl = nil
    imageView.setImage(nil as PlatformImage?)
  }

  private func cancelPendingLoad() {
    pendingLoadWorkItem?.cancel()
    pendingLoadWorkItem = nil
    _ = nextLoadGeneration()
  }

  private func cancelCurrentTask() {
    currentTask?.cancel()
    clearLoadingState()
  }

  private func clearLoadingState() {
    currentTask = nil
    currentLoadingKey = nil
    currentLoadingGeneration = 0
    currentLoadingUrl = nil
    currentLoadingSize = .zero
    currentLoadingScale = 0
  }

  private func showPlaceholder() {
    let shouldHide = !showsLoadingPlaceholder
    if placeholderView.isHidden != shouldHide {
      placeholderView.isHidden = shouldHide
    }
  }

  private func hidePlaceholder() {
    if !placeholderView.isHidden {
      placeholderView.isHidden = true
    }
  }

  private func requestDownloadIfNeeded(_ photoInfo: PhotoInfo) {
    guard let cdnUrl = photoInfo.bestPhotoSize()?.cdnUrl, !cdnUrl.isEmpty else { return }
    guard downloadRequestedPhotoId != photoInfo.id else { return }
    downloadRequestedPhotoId = photoInfo.id

    Task.detached { [message = reloadMessage] in
      await FileCache.shared.download(photo: photoInfo, reloadMessageOnFinish: message)
    }
  }

  private func shouldDownloadBestPhoto(_ photoInfo: PhotoInfo) -> Bool {
    guard let size = photoInfo.bestPhotoSize(),
          let cdnUrl = size.cdnUrl,
          !cdnUrl.isEmpty
    else { return false }

    return localUrl(for: size) == nil
  }

  private func localDisplayUrl(for photoInfo: PhotoInfo) -> URL? {
    for size in PlatformPhotoLoadPolicy.localPhotoSizeCandidates(from: photoInfo) {
      if let url = localUrl(for: size) {
        return url
      }
    }

    return nil
  }

  private func localUrl(for size: PhotoSize?) -> URL? {
    guard let localPath = size?.localPath, !localPath.isEmpty
    else { return nil }

    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  private func resolveTargetSize(from photoInfo: PhotoInfo) -> CGSize? {
    let boundsSize = bounds.size
    guard boundsSize.width > 0, boundsSize.height > 0 else { return nil }

    return PlatformPhotoLoadPolicy.imageRequestSize(
      displaySize: boundsSize,
      sourceSize: sourceSize(from: photoInfo),
      contentMode: photoContentMode
    )
  }

  private func sourceSize(from photoInfo: PhotoInfo) -> CGSize? {
    guard let size = photoInfo.bestPhotoSize(),
          let width = size.width,
          let height = size.height,
          width > 0,
          height > 0
    else {
      return nil
    }

    return CGSize(width: CGFloat(width), height: CGFloat(height))
  }

  private func backingScaleFactor() -> CGFloat {
    #if os(iOS)
    return UIScreen.main.scale
    #else
    return window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    #endif
  }
}

// MARK: - Image Container

#if os(iOS)
private final class ImageContainerView: UIImageView {
  convenience init() {
    self.init(frame: .zero)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    contentMode = .scaleAspectFill
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateContentMode(_ mode: PlatformPhotoContentMode) {
    contentMode = mode == .aspectFill ? .scaleAspectFill : .scaleAspectFit
  }

  var hasImage: Bool {
    image != nil
  }

  var displayedImage: UIImage? {
    image
  }

  func setImage(_ image: UIImage?, animated: Bool = false) {
    let shouldAnimate = animated && image != nil && self.image == nil
    alpha = shouldAnimate ? 0 : 1
    self.image = image

    guard shouldAnimate else { return }

    UIView.animate(
      withDuration: platformPhotoFadeDuration,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.alpha = 1
    }
  }
}
#else
private final class ImageContainerView: NSView {
  private var image: NSImage?
  private var mode: PlatformPhotoContentMode = .aspectFill

  convenience init() {
    self.init(frame: .zero)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }

  func updateContentMode(_ mode: PlatformPhotoContentMode) {
    guard self.mode != mode else { return }
    self.mode = mode
    needsDisplay = true
  }

  var hasImage: Bool {
    image != nil
  }

  var displayedImage: NSImage? {
    image
  }

  func setImage(_ image: NSImage?, animated: Bool = false) {
    let shouldAnimate = animated && image != nil && self.image == nil
    self.image = image

    alphaValue = shouldAnimate ? 0 : 1
    needsDisplay = true

    guard shouldAnimate else { return }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = platformPhotoFadeDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      self.animator().alphaValue = 1
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let image,
          image.size.width > 0,
          image.size.height > 0,
          bounds.width > 0,
          bounds.height > 0
    else { return }

    image.draw(
      in: destinationRect(for: image.size),
      from: sourceRect(for: image.size),
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
  }

  private func sourceRect(for imageSize: NSSize) -> NSRect {
    guard mode == .aspectFill else {
      return NSRect(origin: .zero, size: imageSize)
    }

    return PlatformPhotoLoadPolicy.aspectFillSourceRect(
      imageSize: imageSize,
      displaySize: bounds.size
    )
  }

  private func destinationRect(for imageSize: NSSize) -> NSRect {
    guard mode == .aspectFit else { return bounds }

    return PlatformPhotoLoadPolicy.aspectFitDestinationRect(
      imageSize: imageSize,
      displaySize: bounds.size
    )
  }
}
#endif

// MARK: - Shimmer Placeholder

private final class ShimmerPlaceholderView: PlatformView {
  private let gradientLayer = CAGradientLayer()
  private var isAnimating = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHidden: Bool {
    didSet {
      updateAnimationState()
    }
  }

  #if os(iOS)
  override func layoutSubviews() {
    super.layoutSubviews()
    gradientLayer.frame = bounds
  }
  #else
  override func layout() {
    super.layout()
    gradientLayer.frame = bounds
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateAnimationState()
  }
  #endif

  #if os(iOS)
  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimationState()
  }
  #endif

  private func setupView() {
    #if os(macOS)
    wantsLayer = true
    #endif
    #if os(iOS)
    layer.masksToBounds = true
    layer.backgroundColor = PlatformColor.clear.cgColor
    #else
    layer?.masksToBounds = true
    layer?.backgroundColor = PlatformColor.clear.cgColor
    #endif

    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.2)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.8)
    gradientLayer.locations = [0.0, 0.5, 1.0]
    gradientLayer.colors = [
      PlatformColor.white.withAlphaComponent(0.0).cgColor,
      PlatformColor.white.withAlphaComponent(0.25).cgColor,
      PlatformColor.white.withAlphaComponent(0.0).cgColor,
    ]

    #if os(iOS)
    layer.addSublayer(gradientLayer)
    #else
    layer?.addSublayer(gradientLayer)
    #endif
    updateAnimationState()
  }

  private func updateAnimationState() {
    if window == nil || isHidden {
      stopAnimation()
    } else {
      startAnimationIfNeeded()
    }
  }

  private func startAnimationIfNeeded() {
    guard !isAnimating else { return }
    isAnimating = true

    let animation = CABasicAnimation(keyPath: "locations")
    animation.fromValue = [-1.0, -0.5, 0.0]
    animation.toValue = [1.0, 1.5, 2.0]
    animation.duration = 2.4
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    gradientLayer.add(animation, forKey: "shimmer")
  }

  private func stopAnimation() {
    isAnimating = false
    gradientLayer.removeAnimation(forKey: "shimmer")
  }
}

#if os(iOS)
private typealias PlatformColor = UIColor
#else
private typealias PlatformColor = NSColor
#endif
