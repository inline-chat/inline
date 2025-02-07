import InlineKit
import Nuke
import NukeUI
import QuickLook
import SwiftUI
import UIKit

final class PhotoView: UIView, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  private let imageView: LazyImageView = {
    let view = LazyImageView()
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var fullMessage: FullMessage
  private let maskLayer = CAShapeLayer()
  private let cornerRadius: CGFloat = 16.0

  private var hasText: Bool {
    fullMessage.message.text?.isEmpty == false
  }

  private var hasReply: Bool {
    fullMessage.message.repliedToMessageId != nil
  }

  init(_ fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    setupImage()
    setupMask()
    setupGestures()
  }

  private var imageConstraints: [NSLayoutConstraint] = []

  private struct ImageDimensions {
    let width: CGFloat
    let height: CGFloat
  }

  let minWidth: CGFloat = 180

  private func calculateImageDimensions(width: Int, height: Int) -> ImageDimensions {
    let aspectRatio = CGFloat(width) / CGFloat(height)

    // Set maximum and minimum dimensions
    let maxWidth: CGFloat = 280
    let maxHeight: CGFloat = 400

    // Calculate dimensions maintaining aspect ratio
    var calculatedWidth = maxWidth
    var calculatedHeight = maxWidth / aspectRatio

    // If height exceeds maxHeight, recalculate width to maintain aspect ratio
    if calculatedHeight > maxHeight {
      calculatedHeight = maxHeight
      calculatedWidth = maxHeight * aspectRatio
    }

    return ImageDimensions(width: calculatedWidth, height: calculatedHeight)
  }

  private func setupImage() {
    guard let (isLocal, url) = imageUrl() else { return }
    backgroundColor = .clear
    addSubview(imageView)

    guard let file = fullMessage.file,
          let width = file.width,
          let height = file.height
    else {
      return
    }

    let dimensions = calculateImageDimensions(width: width, height: height)
    let containerWidth = max(dimensions.width, minWidth)

    imageConstraints = [
      widthAnchor.constraint(equalToConstant: containerWidth),
      heightAnchor.constraint(greaterThanOrEqualToConstant: dimensions.height),

      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),

      imageView.widthAnchor.constraint(equalToConstant: dimensions.width),
      imageView.heightAnchor.constraint(lessThanOrEqualToConstant: dimensions.height),
    ]

    let heightConstraint = heightAnchor.constraint(equalToConstant: dimensions.height)
    heightConstraint.priority = .defaultHigh
    heightConstraint.isActive = true

    NSLayoutConstraint.activate(imageConstraints)

    // Configure NukeUI's LazyImageView with proper placeholder
    imageView.placeholderImage = generateThumbnail()
    imageView.priority = .high
    imageView.processors = [.resize(width: 300)]
    imageView.backgroundColor = .clear

    // Create proper image request
    let request = ImageRequest(
      url: url,
      processors: [.resize(width: 300)],
      priority: .high
    )

    // Check cache using proper API
    if ImageCache.shared[ImageCacheKey(request: request)] == nil {
      imageView.request = request
    } else {
      // Use cached image with proper options
      imageView.request = ImageRequest(
        url: url,
        processors: [.resize(width: 300)],
        priority: .high,
        options: [.returnCacheDataDontLoad]
      )
    }

    // Handle image loading completion
    imageView.onCompletion = { [weak self] result in
      guard let self else { return }
      if case let .success(response) = result {
        // Save to local storage if needed
        if var file = fullMessage.file {
          Task {
            let pathString = response.image.save(file: file)
            file.localPath = pathString
            try? await AppDatabase.shared.dbWriter.write { db in
              try file.save(db)
            }
            self.triggerMessageReload()
          }
        }
      }
    }
  }

  private func generateThumbnail() -> UIImage? {
    guard let file = fullMessage.file,
          let width = file.width,
          let height = file.height,
          width > 0, height > 0
    else {
      return nil
    }

    // Match exact calculated dimensions from setupImage()
    let dimensions = calculateImageDimensions(width: width, height: height)
    let size = CGSize(width: dimensions.width, height: dimensions.height)

    UIGraphicsBeginImageContextWithOptions(size, false, 0)
    defer { UIGraphicsEndImageContext() }

    // Solid background matching chat bubbles
    UIColor.systemGray5.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))

    return UIGraphicsGetImageFromCurrentImageContext()
  }

  private func triggerMessageReload() {
    Task { @MainActor in
      await MessagesPublisher.shared
        .messageUpdated(message: fullMessage.message, peer: fullMessage.message.peerId)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateMask()
  }

  private func setupMask() {
    maskLayer.fillColor = UIColor.black.cgColor
    layer.mask = maskLayer
  }

  private func updateMask() {
    let path = UIBezierPath()
    let width = bounds.width
    let height = bounds.height

    // Determine corner rounding based on conditions
    let shouldRoundTopCorners = hasText && !hasReply
    let shouldRoundBottomCorners = hasReply && !hasText
    let shouldRoundAllCorners = !hasText && !hasReply

    // Create rounded rectangle path
    let roundingCorners: UIRectCorner = if shouldRoundAllCorners {
      .allCorners
    } else if shouldRoundTopCorners {
      [.topLeft, .topRight]
    } else if shouldRoundBottomCorners {
      [.bottomLeft, .bottomRight]
    } else {
      []
    }

    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let bezierPath = UIBezierPath(
      roundedRect: bounds,
      byRoundingCorners: roundingCorners,
      cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
    )

    maskLayer.path = bezierPath.cgPath
  }

  private func setupGestures() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
  }

  private func imageUrl() -> (isLocal: Bool, url: URL)? {
    guard let file = fullMessage.file else { return nil }

    if let localFile = file.getLocalURL() {
      return (isLocal: true, url: localFile)
    } else if let tempUrl = file.temporaryUrl,
              let url = URL(string: tempUrl)
    {
      return (isLocal: false, url: url)
    } else {
      return nil
    }
  }

  @objc private func handleTap() {
    guard let (isLocal, url) = imageUrl() else { return }

    let previewController = QLPreviewController()
    previewController.dataSource = self
    previewController.delegate = self
    previewController.title = "Photo"

    previewController.modalPresentationStyle = .fullScreen

    if let viewController = findViewController() {
      viewController.present(previewController, animated: true)
    }
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }

  override var canBecomeFirstResponder: Bool {
    true
  }

  // MARK: - QLPreviewControllerDelegate

  func previewControllerDidDismiss(_ controller: QLPreviewController) {}

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    guard imageUrl() != nil else {
      return 0 // Prevent trying to show preview for non-existent URL
    }
    return 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    guard let (_, url) = imageUrl() else {
      // Return a safe default instead of crashing
      assertionFailure("Missing image URL for preview")
      return URL(fileURLWithPath: "") as QLPreviewItem
    }
    return url as QLPreviewItem
  }
}
