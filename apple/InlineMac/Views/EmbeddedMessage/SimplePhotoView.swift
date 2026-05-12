import AppKit
import InlineKit
import InlineUI
import Logger
import Nuke
import NukeUI

final class SimplePhotoView: NSView {
  private static let imageFadeDuration: TimeInterval = 0.22

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

  init(
    photoInfo: PhotoInfo,
    width: CGFloat,
    height: CGFloat,
    relatedMessage: Message? = nil,
    overlaySymbol: String? = nil
  ) {
    self.photoInfo = photoInfo
    self.relatedMessage = relatedMessage
    self.overlaySymbol = overlaySymbol
    super.init(frame: .zero)
    setupView()
    setSize(width: width, height: height)
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
    translatesAutoresizingMaskIntoConstraints = false

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
    ])

    imageView.layer?.addSublayer(imageLayer)
    updateTinyThumbnailBackground()
    showLoadingView()
    updateOverlayImage()
  }

  private func setSize(width: CGFloat, height: CGFloat) {
    widthConstraint?.isActive = false
    heightConstraint?.isActive = false

    widthConstraint = widthAnchor.constraint(equalToConstant: width)
    heightConstraint = heightAnchor.constraint(equalToConstant: height)

    widthConstraint?.isActive = true
    heightConstraint?.isActive = true
  }

  private func updateImage() {
    guard let url = imageLocalUrl() else {
      if let photoInfo {
        Task.detached { [weak self] in
          guard let self else { return }
          await FileCache.shared.download(photo: photoInfo, reloadMessageOnFinish: relatedMessage)
        }
      }
      return
    }

    let isMemoryCached = ImageCacheManager.shared.cachedImage(cacheKey: url.absoluteString) != nil
    ImageCacheManager.shared.image(for: url, loadSync: true) { [weak self] image in
      guard let self, let image else {
        self?.hideLoadingView()
        return
      }

      if !isMemoryCached, shouldFadeImageIn {
        animateImageTransition(to: image)
      } else {
        setImage(image)
        hideLoadingView()
      }
    }
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
    InlineTinyThumbnailDecoder.strippedBytes(from: photoInfo) == nil
  }

  override func layout() {
    super.layout()
    updateImageLayerFrame()
  }

  private func imageLocalUrl() -> URL? {
    guard let photoSize = photoInfo?.bestPhotoSize() else { return nil }

    if let localPath = photoSize.localPath {
      let url = FileCache.getUrl(for: .photos, localPath: localPath)
      return url
    }

    return nil
  }

  func update(with photoInfo: PhotoInfo, overlaySymbol: String? = nil) {
    self.photoInfo = photoInfo
    self.overlaySymbol = overlaySymbol
    updateTinyThumbnailBackground()
    updateOverlayImage()
    updateImage()
  }
}
