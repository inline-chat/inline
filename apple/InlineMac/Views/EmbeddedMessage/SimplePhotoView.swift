import AppKit
import InlineKit
import Logger
import Nuke
import NukeUI

final class SimplePhotoView: NSView {
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

  private var photoInfo: PhotoInfo?
  private var widthConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var relatedMessage: Message?

  init(photoInfo: PhotoInfo, width: CGFloat, height: CGFloat, relatedMessage: Message? = nil) {
    self.photoInfo = photoInfo
    self.relatedMessage = relatedMessage
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

    addSubview(backgroundView)
    addSubview(imageView)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    imageView.layer?.addSublayer(imageLayer)
    showLoadingView()
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
          await FileCache.shared.download(photo: photoInfo, reloadMessageOnFinish: self.relatedMessage)
        }
      }
      return
    }

    ImageCacheManager.shared.image(for: url, loadSync: true) { [weak self] image in
      guard let self, let image else {
        self?.hideLoadingView()
        return
      }

      setImage(image)
      hideLoadingView()
    }
  }

  private func setImage(_ image: NSImage) {
    imageLayer.contents = image
    updateImageLayerFrame()
  }

  private func updateImageLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.frame = imageView.bounds
    CATransaction.commit()
  }

  private func showLoadingView() {
    backgroundView.alphaValue = 1.0
  }

  private func hideLoadingView() {
    backgroundView.alphaValue = 0.0
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

  func update(with photoInfo: PhotoInfo) {
    self.photoInfo = photoInfo
    updateImage()
  }
}
