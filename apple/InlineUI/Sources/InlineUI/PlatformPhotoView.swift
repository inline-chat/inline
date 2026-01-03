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

public enum PlatformPhotoContentMode {
  case aspectFill
  case aspectFit
}

public final class PlatformPhotoView: PlatformView {
  public var photoContentMode: PlatformPhotoContentMode = .aspectFill {
    didSet { imageView.updateContentMode(photoContentMode) }
  }

  private let imageView = ImageContainerView()
  private let placeholderView = ShimmerPlaceholderView()

  private var currentLoadKey: String?
  private var downloadRequestedPhotoId: Int64?
  private var pendingPhotoInfo: PhotoInfo?
  private var reloadMessage: Message?
  private var currentTask: DownloadTask?

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

  public func setPhoto(_ photoInfo: PhotoInfo?, reloadMessageOnFinish message: Message? = nil) {
    pendingPhotoInfo = photoInfo
    reloadMessage = message
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

    imageView.translatesAutoresizingMaskIntoConstraints = false
    placeholderView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(placeholderView)
    addSubview(imageView)

    NSLayoutConstraint.activate([
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
    showPlaceholder()
  }

  private func updateImageIfNeeded() {
    guard let photoInfo = pendingPhotoInfo else {
      clearImage()
      showPlaceholder()
      return
    }

    guard let localUrl = localUrl(for: photoInfo) else {
      clearImage()
      showPlaceholder()
      requestDownloadIfNeeded(photoInfo)
      return
    }

    let targetSize = resolveTargetSize(from: photoInfo)
    let sizeKey = "\(Int(targetSize.width))x\(Int(targetSize.height))"
    let loadKey = "\(photoInfo.id)-\(localUrl.lastPathComponent)-\(sizeKey)-\(photoContentMode)"

    if loadKey == currentLoadKey {
      return
    }

    prepareForNewLoad()
    currentLoadKey = loadKey
    loadImage(from: localUrl, targetSize: targetSize)
  }

  private func loadImage(from url: URL, targetSize: CGSize) {
    currentTask?.cancel()

    let scale = backingScaleFactor()
    let options: KingfisherOptionsInfo = [
      .processor(DownsamplingImageProcessor(size: targetSize)),
      .scaleFactor(scale),
      .loadDiskFileSynchronously,
      .cacheMemoryOnly,
    ]

    let provider = LocalFileImageDataProvider(fileURL: url)

    currentTask = KingfisherManager.shared.retrieveImage(
      with: .provider(provider),
      options: options
    ) { [weak self] result in
      guard let self else { return }
      switch result {
      case let .success(value):
        self.setImage(value.image)
        self.hidePlaceholder()
      case .failure:
        self.clearImage()
        self.showPlaceholder()
      }
    }
  }

  private func setImage(_ image: PlatformImage?) {
    imageView.setImage(image)
  }

  private func clearImage() {
    prepareForNewLoad()
    currentLoadKey = nil
  }

  private func prepareForNewLoad() {
    currentTask?.cancel()
    currentTask = nil
    imageView.setImage(nil as PlatformImage?)
    showPlaceholder()
  }

  private func showPlaceholder() {
    placeholderView.isHidden = false
  }

  private func hidePlaceholder() {
    placeholderView.isHidden = true
  }

  private func requestDownloadIfNeeded(_ photoInfo: PhotoInfo) {
    guard downloadRequestedPhotoId != photoInfo.id else { return }
    downloadRequestedPhotoId = photoInfo.id

    Task.detached { [message = reloadMessage] in
      await FileCache.shared.download(photo: photoInfo, reloadMessageOnFinish: message)
    }
  }

  private func localUrl(for photoInfo: PhotoInfo) -> URL? {
    guard let size = photoInfo.bestPhotoSize(),
          let localPath = size.localPath
    else { return nil }

    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
  }

  private func resolveTargetSize(from photoInfo: PhotoInfo) -> CGSize {
    let boundsSize = bounds.size
    if boundsSize.width > 0, boundsSize.height > 0 {
      return boundsSize
    }

    if let size = photoInfo.bestPhotoSize(),
       let width = size.width,
       let height = size.height,
       width > 0,
       height > 0
    {
      return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    return CGSize(width: 300, height: 300)
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

  func setImage(_ image: UIImage?) {
    self.image = image
  }
}
#else
private final class ImageContainerView: NSView {
  private let imageLayer = CALayer()

  convenience init() {
    self.init(frame: .zero)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(imageLayer)
    imageLayer.contentsGravity = .resizeAspectFill
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    imageLayer.frame = bounds
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    imageLayer.contentsScale = window?.backingScaleFactor ?? 2.0
  }

  func updateContentMode(_ mode: PlatformPhotoContentMode) {
    imageLayer.contentsGravity = mode == .aspectFill ? .resizeAspectFill : .resizeAspect
  }

  func setImage(_ image: NSImage?) {
    imageLayer.contents = image
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
    if window == nil {
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
